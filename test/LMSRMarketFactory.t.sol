// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LMSRMarketFactory } from "../src/LMSRMarketFactory.sol";
import { LMSRMarket } from "../src/LMSRMarket.sol";

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

contract LMSRMarketFactoryTest is Test {
    LMSRMarketFactory public factory;
    MockUSDC public usdc;
    address public owner;
    address public nonOwner;

    function setUp() public {
        owner = address(this);
        nonOwner = address(0x123);
        usdc = new MockUSDC();
        factory = new LMSRMarketFactory(address(usdc));
    }

    function test_CreateMarket() public {
        uint256 deadline = block.timestamp + 3600;
        uint256 b = 10 * 10**6; // 10 USDC
        string memory slug = "btc-100k";

        // Calculate initial cost
        // C(0,0) = b * ln(2) = 10 * ln(2) ~ 6.93 USDC
        uint256 expectedCost = 6931471; // 6.931471 USDC

        // Approve factory to spend owner's USDC
        usdc.approve(address(factory), expectedCost);

        // Record balances
        uint256 balBefore = usdc.balanceOf(owner);

        // Create market
        address marketAddr = factory.createMarket(slug, deadline, b);

        // Verifications
        assertTrue(marketAddr != address(0));
        assertEq(factory.marketCount(), 1);
        assertEq(factory.markets(0), marketAddr);

        // Check balances
        uint256 balAfter = usdc.balanceOf(owner);
        assertEq(balBefore - balAfter, expectedCost);
        assertEq(usdc.balanceOf(marketAddr), expectedCost);

        // Check market parameters
        LMSRMarket market = LMSRMarket(marketAddr);
        assertEq(market.slug(), slug);
        assertEq(market.deadline(), deadline);
        assertEq(market.b(), b);
        assertTrue(market.isFunded());
    }

    function test_CreateMarket_OnlyOwner() public {
        uint256 deadline = block.timestamp + 3600;
        uint256 b = 10 * 10**6;
        string memory slug = "btc-100k";

        vm.startPrank(nonOwner);
        vm.expectRevert("Not owner");
        factory.createMarket(slug, deadline, b);
        vm.stopPrank();
    }

    function test_MultipleMarkets() public {
        usdc.approve(address(factory), 100 * 10**6);

        address m1 = factory.createMarket("q1", block.timestamp + 1000, 10 * 10**6);
        address m2 = factory.createMarket("q2", block.timestamp + 2000, 20 * 10**6);

        assertEq(factory.marketCount(), 2);
        assertTrue(m1 != m2);
        assertEq(LMSRMarket(m1).slug(), "q1");
        assertEq(LMSRMarket(m2).slug(), "q2");
    }
}
