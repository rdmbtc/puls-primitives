// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LMSRMarketFactory } from "../src/LMSRMarketFactory.sol";
import { LMSRMarket } from "../src/LMSRMarket.sol";
import { PulsMarket } from "../src/PulsMarket.sol";

contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        balanceOf[msg.sender] = 1_000_000 * 10**6; // 1 million USDC
        totalSupply = 1_000_000 * 10**6;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract MarketSecurityTest is Test {
    MockUSDC public usdc;
    LMSRMarketFactory public factory;
    address public owner;
    address public user1;
    address public user2;
    address public user3;

    function setUp() public {
        owner = address(this);
        user1 = address(0x111);
        user2 = address(0x222);
        user3 = address(0x333);

        usdc = new MockUSDC();
        factory = new LMSRMarketFactory(address(usdc));

        // Mint USDC to users
        usdc.mint(user1, 10_000 * 10**6);
        usdc.mint(user2, 10_000 * 10**6);
        usdc.mint(user3, 10_000 * 10**6);
    }

    // ── LMSR Security Tests ───────────────────────────────────────────────────

    function testLmsrSafeWithdrawAndClaim() public {
        string memory slug = "lmsr-test";
        uint256 deadline = block.timestamp + 3600;
        uint256 b = 10 * 10**6; // 10 USDC

        // Seeding cost
        uint256 initialCost = 6931471;
        usdc.approve(address(factory), initialCost);

        // Deploy market
        address marketAddr = factory.createMarket(slug, deadline, b);
        LMSRMarket market = LMSRMarket(marketAddr);

        // User1 buys YES
        vm.startPrank(user1);
        usdc.approve(marketAddr, type(uint256).max);
        uint256 buyAmount = 10 * 10**6; // 10 USDC
        uint256 sharesBought = market.calcBuyYesShares(buyAmount);
        assertTrue(sharesBought > 0);
        market.buyYes(buyAmount);
        vm.stopPrank();

        // User2 buys NO
        vm.startPrank(user2);
        usdc.approve(marketAddr, type(uint256).max);
        market.buyNo(buyAmount);
        vm.stopPrank();

        // Move to deadline and resolve YES
        vm.warp(deadline);
        market.resolve(true);

        // Verify owner withdrawal is capped to leave enough USDC for winners
        uint256 outstandingWinners = market.yesOutstanding();
        uint256 contractBal = usdc.balanceOf(marketAddr);
        
        // Owner tries to withdraw
        uint256 ownerBalBefore = usdc.balanceOf(owner);
        market.ownerWithdraw();
        uint256 ownerBalAfter = usdc.balanceOf(owner);

        // Verify remaining contract balance is exactly equal to outstanding winner shares
        uint256 contractBalAfter = usdc.balanceOf(marketAddr);
        assertEq(contractBalAfter, outstandingWinners);
        assertEq(ownerBalAfter - ownerBalBefore, contractBal - outstandingWinners);

        // Verify user1 (winner) can successfully claim
        uint256 user1BalBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        market.claim();
        uint256 user1BalAfter = usdc.balanceOf(user1);

        assertEq(user1BalAfter - user1BalBefore, sharesBought);
        assertEq(usdc.balanceOf(marketAddr), outstandingWinners - sharesBought);
    }

    function testLmsrMultiWinnerClaim() public {
        string memory slug = "lmsr-multi-test";
        uint256 deadline = block.timestamp + 3600;
        uint256 b = 10 * 10**6; // 10 USDC

        // Seeding cost
        uint256 initialCost = 6931471;
        usdc.approve(address(factory), initialCost);

        // Deploy market
        address marketAddr = factory.createMarket(slug, deadline, b);
        LMSRMarket market = LMSRMarket(marketAddr);

        // User1 buys YES
        vm.startPrank(user1);
        usdc.approve(marketAddr, type(uint256).max);
        uint256 buyAmount1 = 10 * 10**6;
        uint256 user1Shares = market.calcBuyYesShares(buyAmount1);
        market.buyYes(buyAmount1);
        vm.stopPrank();

        // User3 buys YES
        vm.startPrank(user3);
        usdc.approve(marketAddr, type(uint256).max);
        uint256 buyAmount3 = 5 * 10**6;
        uint256 user3Shares = market.calcBuyYesShares(buyAmount3);
        market.buyYes(buyAmount3);
        vm.stopPrank();

        // User2 buys NO
        vm.startPrank(user2);
        usdc.approve(marketAddr, type(uint256).max);
        market.buyNo(10 * 10**6);
        vm.stopPrank();

        // Move to deadline and resolve YES
        vm.warp(deadline);
        market.resolve(true);

        // Owner withdraws surplus
        market.ownerWithdraw();

        // Verify both user1 and user3 can claim their respective winnings
        uint256 user1BalBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        market.claim();
        uint256 user1BalAfter = usdc.balanceOf(user1);
        assertEq(user1BalAfter - user1BalBefore, user1Shares);

        uint256 user3BalBefore = usdc.balanceOf(user3);
        vm.prank(user3);
        market.claim();
        uint256 user3BalAfter = usdc.balanceOf(user3);
        assertEq(user3BalAfter - user3BalBefore, user3Shares);

        // Total claimed should match
        assertEq(market.totalClaimed(), user1Shares + user3Shares);
    }

    function testLmsrFundGating() public {
        LMSRMarket market = new LMSRMarket(address(usdc), "gating-test", block.timestamp + 3600, 10 * 10**6, owner);

        vm.startPrank(user1);
        vm.expectRevert("Not owner or factory");
        market.fund();
        vm.stopPrank();
    }

    function testLmsrLargeBuy() public {
        LMSRMarket market = new LMSRMarket(address(usdc), "math-test", block.timestamp + 3600, 10 * 10**6, owner);
        
        // Verify that a large buy works correctly and does not overflow
        uint256 shares = market.calcBuyYesShares(10_000 * 10**6);
        assertTrue(shares > 0);
    }

    function testLmsrGatedActions() public {
        string memory slug = "lmsr-gated-test";
        uint256 deadline = block.timestamp + 3600;
        uint256 b = 10 * 10**6; // 10 USDC

        // Seeding cost
        uint256 initialCost = 6931471;
        usdc.approve(address(factory), initialCost);

        // Deploy market
        address marketAddr = factory.createMarket(slug, deadline, b);
        LMSRMarket market = LMSRMarket(marketAddr);

        // User1 buys YES
        vm.startPrank(user1);
        usdc.approve(marketAddr, type(uint256).max);
        uint256 buyAmount = 10 * 10**6;
        market.buyYes(buyAmount);
        vm.stopPrank();

        // 1. Claim should revert when not resolved
        vm.prank(user1);
        vm.expectRevert("Not resolved");
        market.claim();

        // Move to deadline and resolve YES
        vm.warp(deadline);
        market.resolve(true);

        // 2. Sell should revert when resolved
        vm.startPrank(user1);
        vm.expectRevert("Market resolved");
        market.sellYes(1 * 10**6);
        vm.stopPrank();

        // 3. User2 (no winning shares) claim should revert
        vm.prank(user2);
        vm.expectRevert("No winning shares");
        market.claim();

        // 4. User1 (winner) claims successfully
        vm.prank(user1);
        market.claim();

        // 5. Double claim should revert
        vm.prank(user1);
        vm.expectRevert("Already claimed");
        market.claim();
    }

    // ── CPMM (PulsMarket) Security Tests ──────────────────────────────────────

    function testPulsSafeWithdrawAndClaim() public {
        uint256 initialLiquidity = 10 * 10**6; // 10 USDC
        
        // Pre-compute contract address and approve
        address predictedAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        usdc.approve(predictedAddress, initialLiquidity);
        
        // Deploy PulsMarket
        PulsMarket market = new PulsMarket(
            address(usdc),
            "will btc hit 100k?",
            block.timestamp + 3600,
            initialLiquidity
        );
        address marketAddr = address(market);

        // User1 buys YES
        vm.startPrank(user1);
        usdc.approve(marketAddr, type(uint256).max);
        uint256 buyAmount = 15 * 10**6; // 15 USDC
        market.buyYes(buyAmount);
        uint256 yesShares = market.yesShares(user1);
        assertTrue(yesShares > 0);
        vm.stopPrank();

        // User2 buys NO
        vm.startPrank(user2);
        usdc.approve(marketAddr, type(uint256).max);
        market.buyNo(10 * 10**6);
        vm.stopPrank();

        // Warp to deadline and resolve YES
        vm.warp(block.timestamp + 3600);
        market.resolve(true);

        uint256 outstandingWinners = market.yesOutstanding();
        uint256 contractBal = usdc.balanceOf(marketAddr);

        // Owner withdraws
        uint256 ownerBalBefore = usdc.balanceOf(owner);
        market.ownerWithdraw();
        uint256 ownerBalAfter = usdc.balanceOf(owner);

        // Verify remaining contract balance is exactly equal to outstanding winner shares
        uint256 contractBalAfter = usdc.balanceOf(marketAddr);
        assertEq(contractBalAfter, outstandingWinners);
        assertEq(ownerBalAfter - ownerBalBefore, contractBal - outstandingWinners);

        // Verify user1 (winner) can successfully claim
        uint256 user1BalBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        market.claim();
        uint256 user1BalAfter = usdc.balanceOf(user1);

        assertEq(user1BalAfter - user1BalBefore, yesShares);
    }

    function testPulsMultiWinnerClaim() public {
        uint256 initialLiquidity = 10 * 10**6; // 10 USDC
        
        // Pre-compute contract address and approve
        address predictedAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        usdc.approve(predictedAddress, initialLiquidity);
        
        // Deploy PulsMarket
        PulsMarket market = new PulsMarket(
            address(usdc),
            "puls multi test",
            block.timestamp + 3600,
            initialLiquidity
        );
        address marketAddr = address(market);

        // User1 buys YES
        vm.startPrank(user1);
        usdc.approve(marketAddr, type(uint256).max);
        market.buyYes(15 * 10**6);
        uint256 user1Shares = market.yesShares(user1);
        vm.stopPrank();

        // User3 buys YES
        vm.startPrank(user3);
        usdc.approve(marketAddr, type(uint256).max);
        market.buyYes(10 * 10**6);
        uint256 user3Shares = market.yesShares(user3);
        vm.stopPrank();

        // User2 buys NO
        vm.startPrank(user2);
        usdc.approve(marketAddr, type(uint256).max);
        market.buyNo(20 * 10**6);
        vm.stopPrank();

        // Warp to deadline and resolve YES
        vm.warp(block.timestamp + 3600);
        market.resolve(true);

        // Owner withdraws surplus
        market.ownerWithdraw();

        // Verify both user1 and user3 can claim their respective winnings
        uint256 user1BalBefore = usdc.balanceOf(user1);
        vm.prank(user1);
        market.claim();
        uint256 user1BalAfter = usdc.balanceOf(user1);
        assertEq(user1BalAfter - user1BalBefore, user1Shares);

        uint256 user3BalBefore = usdc.balanceOf(user3);
        vm.prank(user3);
        market.claim();
        uint256 user3BalAfter = usdc.balanceOf(user3);
        assertEq(user3BalAfter - user3BalBefore, user3Shares);

        // Total claimed should match
        assertEq(market.totalClaimed(), user1Shares + user3Shares);
    }

    function testPulsCpmmInvariant(uint256 buyAmount1, uint256 buyAmount2) public {
        // Bound the fuzz inputs to reasonable amounts to avoid overflow or out of funds errors
        buyAmount1 = bound(buyAmount1, 1_000_000, 5_000 * 10**6); // between 1 USDC and 5,000 USDC
        buyAmount2 = bound(buyAmount2, 1_000_000, 5_000 * 10**6);

        uint256 initialLiquidity = 10_000 * 10**6; // 10,000 USDC
        
        // Pre-compute contract address and approve
        address predictedAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        usdc.approve(predictedAddress, initialLiquidity);
        
        PulsMarket market = new PulsMarket(
            address(usdc),
            "invariant test",
            block.timestamp + 3600,
            initialLiquidity
        );
        address marketAddr = address(market);

        uint256 initialK = market.k();

        // User 1 buys YES
        vm.startPrank(user1);
        usdc.approve(marketAddr, type(uint256).max);
        market.buyYes(buyAmount1);
        vm.stopPrank();

        // Check invariant: poolYes * poolNo should be <= initialK, and difference should be less than poolNo
        uint256 poolYes1 = market.poolYes();
        uint256 poolNo1 = market.poolNo();
        uint256 currentK1 = poolYes1 * poolNo1;
        assertTrue(currentK1 <= initialK, "K increased or integer division anomaly");
        assertTrue(initialK - currentK1 < poolNo1, "Invariant difference exceeds division remainder bounds");

        // User 2 buys NO
        vm.startPrank(user2);
        usdc.approve(marketAddr, type(uint256).max);
        market.buyNo(buyAmount2);
        vm.stopPrank();

        // Check invariant again
        uint256 poolYes2 = market.poolYes();
        uint256 poolNo2 = market.poolNo();
        uint256 currentK2 = poolYes2 * poolNo2;
        assertTrue(currentK2 <= initialK, "K increased or integer division anomaly");
        assertTrue(initialK - currentK2 < poolYes2, "Invariant difference exceeds division remainder bounds");

        // User 1 sells some shares
        uint256 user1Shares = market.yesShares(user1);
        uint256 sellShares = user1Shares / 2;
        if (sellShares > 0) {
            vm.startPrank(user1);
            market.sellYes(sellShares);
            vm.stopPrank();

            // Check invariant after sell
            uint256 poolYes3 = market.poolYes();
            uint256 poolNo3 = market.poolNo();
            uint256 currentK3 = poolYes3 * poolNo3;
            assertTrue(currentK3 <= initialK, "K increased or integer division anomaly");
            assertTrue(initialK - currentK3 < poolYes3, "Invariant difference exceeds division remainder bounds");
        }
    }

    function testPulsMinLiquidity() public {
        vm.expectRevert("Initial liquidity must be >= 1 USDC");
        new PulsMarket(
            address(usdc),
            "will btc hit 100k?",
            block.timestamp + 3600,
            999_999 // < 1 USDC
        );
    }

    // ── Ownable2Step Verification ─────────────────────────────────────────────

    function testOwnable2Step() public {
        // Test Factory Ownable2Step
        factory.transferOwnership(user1);
        assertEq(factory.owner(), owner);
        assertEq(factory.pendingOwner(), user1);

        // Non-pending owner tries to accept
        vm.prank(user2);
        vm.expectRevert("Not pending owner");
        factory.acceptOwnership();

        // Pending owner accepts
        vm.prank(user1);
        factory.acceptOwnership();
        assertEq(factory.owner(), user1);
        assertEq(factory.pendingOwner(), address(0));
    }
}
