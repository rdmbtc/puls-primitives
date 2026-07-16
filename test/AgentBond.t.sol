// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { AgentBond } from "../src/AgentBond.sol";

/// Minimal 6-decimal ERC20 mock for tests.
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        require(allowance[from][msg.sender] >= amount, "allow");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AgentBondTest is Test {
    MockUSDC usdc;
    AgentBond bond;

    address owner = address(this); // deployer = settler
    address treasury = address(0xBEEF);
    address agent = address(0xA11CE);

    bytes32 constant SIG = keccak256("signal-1");
    uint256 constant AMT = 2_000_000; // 2 USDC (6 decimals)

    function setUp() public {
        usdc = new MockUSDC();
        bond = new AgentBond(address(usdc), treasury);
        usdc.mint(agent, 10_000_000); // 10 USDC
    }

    function _post() internal {
        vm.startPrank(agent);
        usdc.approve(address(bond), AMT);
        bond.postBond(SIG, AMT);
        vm.stopPrank();
    }

    function testPostBondLocksFunds() public {
        _post();
        assertEq(usdc.balanceOf(address(bond)), AMT);
        assertEq(usdc.balanceOf(agent), 8_000_000);
        assertEq(bond.activeBondedUsdc(), AMT);
        assertEq(bond.totalBondedUsdc(), AMT);
        assertEq(bond.bondCount(), 1);
        (address a, uint256 amt,,, AgentBond.Status st,) = bond.getBond(SIG);
        assertEq(a, agent);
        assertEq(amt, AMT);
        assertEq(uint8(st), uint8(AgentBond.Status.Active));
    }

    function testCorrectCallReturnsBond() public {
        _post();
        bond.settle(SIG, true);
        assertEq(usdc.balanceOf(agent), 10_000_000); // got it back
        assertEq(usdc.balanceOf(address(bond)), 0);
        assertEq(bond.totalReturnedUsdc(), AMT);
        assertEq(bond.activeBondedUsdc(), 0);
        (,,,, AgentBond.Status st, bool correct) = bond.getBond(SIG);
        assertEq(uint8(st), uint8(AgentBond.Status.Returned));
        assertTrue(correct);
    }

    function testWrongCallSlashesToTreasury() public {
        _post();
        bond.settle(SIG, false);
        assertEq(usdc.balanceOf(treasury), AMT); // slashed to treasury
        assertEq(usdc.balanceOf(agent), 8_000_000); // did NOT get it back
        assertEq(bond.totalSlashedUsdc(), AMT);
        assertEq(bond.activeBondedUsdc(), 0);
        (,,,, AgentBond.Status st, bool correct) = bond.getBond(SIG);
        assertEq(uint8(st), uint8(AgentBond.Status.Slashed));
        assertFalse(correct);
    }

    function testCannotDoubleBond() public {
        _post();
        vm.startPrank(agent);
        usdc.approve(address(bond), AMT);
        vm.expectRevert(AgentBond.BondExists.selector);
        bond.postBond(SIG, AMT);
        vm.stopPrank();
    }

    function testZeroAmountReverts() public {
        vm.prank(agent);
        vm.expectRevert(AgentBond.ZeroAmount.selector);
        bond.postBond(SIG, 0);
    }

    function testOnlyOwnerSettles() public {
        _post();
        vm.prank(agent);
        vm.expectRevert(AgentBond.NotOwner.selector);
        bond.settle(SIG, true);
    }

    function testCannotSettleTwice() public {
        _post();
        bond.settle(SIG, true);
        vm.expectRevert(AgentBond.NotActive.selector);
        bond.settle(SIG, false);
    }

    function testSettleUnknownReverts() public {
        vm.expectRevert(AgentBond.NoBond.selector);
        bond.settle(keccak256("nope"), true);
    }
}
