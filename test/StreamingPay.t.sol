// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { StreamingPay } from "../src/StreamingPay.sol";

/// Minimal 6-decimal ERC20 mock.
contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { require(balanceOf[msg.sender] >= a, "bal"); balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a, "bal"); require(allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract StreamingPayTest is Test {
    MockUSDC usdc;
    StreamingPay sp;

    address payer;
    address recipient;
    address stranger;

    uint256 constant RATE = 1000;       // 1000 micro-USDC/sec = $0.001/s
    uint256 constant DEPOSIT = 1_000_000; // 1 USDC

    function setUp() public {
        payer = makeAddr("payer");
        recipient = makeAddr("recipient");
        stranger = makeAddr("stranger");
        usdc = new MockUSDC();
        sp = new StreamingPay(address(usdc));
        usdc.mint(payer, 10_000_000); // 10 USDC
    }

    function _open() internal returns (uint256 id) {
        vm.startPrank(payer);
        usdc.approve(address(sp), DEPOSIT);
        id = sp.open(recipient, RATE, DEPOSIT);
        vm.stopPrank();
    }

    function testOpenEscrowsDeposit() public {
        uint256 id = _open();
        assertEq(usdc.balanceOf(address(sp)), DEPOSIT);
        assertEq(usdc.balanceOf(payer), 9_000_000);
        StreamingPay.Stream memory s = sp.getStream(id);
        assertEq(s.payer, payer);
        assertEq(s.recipient, recipient);
        assertEq(s.ratePerSec, RATE);
        assertEq(s.deposit, DEPOSIT);
        assertTrue(s.active);
        assertEq(sp.streamed(id), 0);
    }

    function testAccruesPerSecond() public {
        uint256 id = _open();
        vm.warp(block.timestamp + 100);          // 100 seconds of flow
        assertEq(sp.streamed(id), RATE * 100);    // 100000 micro = $0.10
        assertEq(sp.withdrawable(id), RATE * 100);
    }

    function testCappedAtDeposit() public {
        uint256 id = _open();
        vm.warp(block.timestamp + 100000);        // would be $100, capped at $1
        assertEq(sp.streamed(id), DEPOSIT);
    }

    function testWithdraw() public {
        uint256 id = _open();
        vm.warp(block.timestamp + 100);
        vm.prank(recipient);
        uint256 amt = sp.withdraw(id);
        assertEq(amt, RATE * 100);
        assertEq(usdc.balanceOf(recipient), RATE * 100);
        assertEq(sp.withdrawable(id), 0);
    }

    function testPauseFreezesThenResume() public {
        uint256 id = _open();
        vm.warp(block.timestamp + 50);            // accrue $0.05
        vm.prank(payer);
        sp.pause(id);
        uint256 frozen = sp.streamed(id);
        assertEq(frozen, RATE * 50);
        vm.warp(block.timestamp + 1000);          // time passes, but paused
        assertEq(sp.streamed(id), frozen);        // no accrual while paused
        vm.prank(payer);
        sp.resume(id);
        vm.warp(block.timestamp + 50);            // 50 more active seconds
        assertEq(sp.streamed(id), RATE * 100);    // 50 + 50
    }

    function testStopPaysRecipientAndRefundsPayer() public {
        uint256 id = _open();
        vm.warp(block.timestamp + 100);           // streamed $0.10
        vm.prank(payer);
        (uint256 streamedAmt, uint256 refunded) = sp.stop(id);
        assertEq(streamedAmt, RATE * 100);
        assertEq(refunded, DEPOSIT - RATE * 100);
        assertEq(usdc.balanceOf(recipient), RATE * 100);       // paid what flowed
        assertEq(usdc.balanceOf(payer), 9_000_000 + (DEPOSIT - RATE * 100)); // refunded the rest
        assertEq(usdc.balanceOf(address(sp)), 0);              // escrow emptied
        StreamingPay.Stream memory s = sp.getStream(id);
        assertTrue(s.stopped);
    }

    function testTopUpExtends() public {
        uint256 id = _open();
        vm.startPrank(payer);
        usdc.approve(address(sp), 500_000);
        sp.topUp(id, 500_000);
        vm.stopPrank();
        assertEq(sp.getStream(id).deposit, DEPOSIT + 500_000);
        assertEq(usdc.balanceOf(address(sp)), DEPOSIT + 500_000);
    }

    function testOnlyPayerCanResume() public {
        uint256 id = _open();
        vm.prank(payer); sp.pause(id);
        vm.prank(recipient);
        vm.expectRevert(StreamingPay.NotPayer.selector);
        sp.resume(id);
    }

    function testStrangerCannotStop() public {
        uint256 id = _open();
        vm.prank(stranger);
        vm.expectRevert(StreamingPay.NotParty.selector);
        sp.stop(id);
    }

    function testCannotStopTwice() public {
        uint256 id = _open();
        vm.startPrank(payer);
        sp.stop(id);
        vm.expectRevert(StreamingPay.AlreadyStopped.selector);
        sp.stop(id);
        vm.stopPrank();
    }

    function testUnknownReverts() public {
        vm.expectRevert(StreamingPay.NotFound.selector);
        sp.streamed(999);
    }
}
