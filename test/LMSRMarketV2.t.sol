// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LMSRMarket } from "../src/LMSRMarket.sol";

contract MockUSDCv2 {
    string public name = "Mock USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LMSRMarketV2Test is Test {
    MockUSDCv2 usdc;
    LMSRMarket market;

    address owner = address(this);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant B = 1_000_000_000; // 1000 USDC liquidity parameter
    uint256 deadline;

    function setUp() public {
        usdc = new MockUSDCv2();
        deadline = block.timestamp + 7 days;
        market = new LMSRMarket(address(usdc), "test-market", deadline, B, owner);

        // Fund the market subsidy
        uint256 cost = market.getCostStable(0, 0);
        usdc.mint(owner, cost);
        usdc.approve(address(market), cost);
        market.fund();

        // Give traders USDC
        usdc.mint(alice, 10_000_000_000); // 10k USDC
        usdc.mint(bob, 10_000_000_000);
        vm.prank(alice);
        usdc.approve(address(market), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(market), type(uint256).max);
    }

    // ── Prices ────────────────────────────────────────────────────────────────

    function testInitialPriceIsFifty() public view {
        uint256 p = market.getYesPrice();
        assertApproxEqAbs(p, 500_000, 100); // ~0.50
        assertEq(market.getNoPrice(), 1_000_000 - p);
    }

    function testPriceMovesAfterBuy() public {
        vm.prank(alice);
        market.buyYes(500_000_000); // 500 USDC into YES
        assertGt(market.getYesPrice(), 500_000);
        assertLt(market.getYesPrice(), 1_000_000);
    }

    // ── Slippage protection ───────────────────────────────────────────────────

    function testBuyYesSlippageReverts() public {
        uint256 quoted = market.calcBuyYesShares(100_000_000);
        vm.prank(alice);
        vm.expectRevert(bytes("Slippage: insufficient shares out"));
        market.buyYes(100_000_000, quoted + 1);
    }

    function testBuyYesSlippagePasses() public {
        uint256 quoted = market.calcBuyYesShares(100_000_000);
        vm.prank(alice);
        market.buyYes(100_000_000, quoted);
        assertEq(market.yesShares(alice), quoted);
    }

    function testSellSlippageReverts() public {
        vm.prank(alice);
        market.buyYes(100_000_000);
        uint256 shares = market.yesShares(alice);
        uint256 quoted = market.calcSellYesUsdc(shares);
        vm.prank(alice);
        vm.expectRevert(bytes("Slippage: insufficient USDC out"));
        market.sellYes(shares, quoted + 1);
    }

    function testBackwardCompatibleEntrypoints() public {
        vm.prank(alice);
        market.buyYes(50_000_000); // legacy single-arg signature still works
        uint256 shares = market.yesShares(alice);
        assertGt(shares, 0);
        vm.prank(alice);
        market.sellYes(shares);
        assertEq(market.yesShares(alice), 0);
    }

    // ── Trading closes at deadline ────────────────────────────────────────────

    function testSellBlockedAfterDeadline() public {
        vm.prank(alice);
        market.buyYes(100_000_000);
        vm.warp(deadline + 1);
        uint256 shares = market.yesShares(alice);
        vm.prank(alice);
        vm.expectRevert(bytes("Market closed"));
        market.sellYes(shares);
    }

    function testBuyBlockedAfterDeadline() public {
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("Market closed"));
        market.buyYes(100_000_000);
    }

    // ── Emergency exit ────────────────────────────────────────────────────────

    function testEmergencyRedeemBeforeDelayReverts() public {
        vm.prank(alice);
        market.buyYes(100_000_000);
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("Emergency delay not reached"));
        market.emergencyRedeem();
    }

    function testEmergencyRedeemProRata() public {
        vm.prank(alice);
        market.buyYes(100_000_000); // 100 USDC YES
        vm.prank(bob);
        market.buyNo(300_000_000); // 300 USDC NO

        vm.warp(deadline + 30 days + 1);

        uint256 pool = usdc.balanceOf(address(market));
        uint256 total = market.yesOutstanding() + market.noOutstanding();

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.emergencyRedeem();
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBefore;
        assertEq(alicePayout, (pool * market.yesShares(alice)) / total);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        market.emergencyRedeem();
        uint256 bobPayout = usdc.balanceOf(bob) - bobBefore;
        assertEq(bobPayout, (pool * market.noShares(bob)) / total);

        // Double redeem blocked
        vm.prank(alice);
        vm.expectRevert(bytes("Already redeemed"));
        market.emergencyRedeem();
    }

    function testEmergencyRedeemBlockedWhenResolved() public {
        vm.prank(alice);
        market.buyYes(100_000_000);
        vm.warp(deadline + 1);
        market.resolve(true);
        vm.warp(deadline + 30 days + 1);
        vm.prank(alice);
        vm.expectRevert(bytes("Market resolved"));
        market.emergencyRedeem();
    }

    // ── Misc ──────────────────────────────────────────────────────────────────

    function testConstructorRejectsPastDeadline() public {
        vm.warp(1_000_000);
        vm.expectRevert(bytes("Deadline in past"));
        new LMSRMarket(address(usdc), "bad", block.timestamp - 1, B, owner);
    }

    function testClaimAfterResolve() public {
        vm.prank(alice);
        market.buyYes(100_000_000);
        uint256 shares = market.yesShares(alice);
        vm.warp(deadline + 1);
        market.resolve(true);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        assertEq(usdc.balanceOf(alice) - before, shares);
    }
}
