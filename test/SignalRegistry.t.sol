// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { SignalRegistry } from "../src/SignalRegistry.sol";

contract SignalRegistryTest is Test {
    SignalRegistry registry;

    address creator = address(0xC0FFEE);
    address other   = address(0xBEEF);

    bytes32 sigId = keccak256("signal-uuid-1");
    bytes32 hash1  = keccak256("thesis content v1");
    uint256 price  = 1000; // 0.001 USDC (6 dec)

    function setUp() public {
        registry = new SignalRegistry();
    }

    function test_PublishRecordsAttestation() public {
        vm.prank(creator);
        registry.publish(sigId, hash1, price);

        (address c, bytes32 ch, uint256 p, uint64 pub, uint64 rev) = registry.getAttestation(sigId);
        assertEq(c, creator);
        assertEq(ch, hash1);
        assertEq(p, price);
        assertGt(pub, 0);
        assertEq(rev, 0);
        assertEq(registry.totalPublished(), 1);
        assertEq(registry.creatorSignalCount(creator), 1);
    }

    function test_VerifyMatchesOnlyLiveCorrectHash() public {
        vm.prank(creator);
        registry.publish(sigId, hash1, price);

        assertTrue(registry.verify(sigId, hash1));
        assertFalse(registry.verify(sigId, keccak256("tampered")));
    }

    function test_CannotPublishTwice() public {
        vm.startPrank(creator);
        registry.publish(sigId, hash1, price);
        vm.expectRevert(SignalRegistry.AlreadyPublished.selector);
        registry.publish(sigId, hash1, price);
        vm.stopPrank();
    }

    function test_OnlyCreatorRevokes() public {
        vm.prank(creator);
        registry.publish(sigId, hash1, price);

        vm.prank(other);
        vm.expectRevert(SignalRegistry.NotCreator.selector);
        registry.revoke(sigId);

        vm.prank(creator);
        registry.revoke(sigId);
        assertFalse(registry.verify(sigId, hash1)); // revoked → no longer verifiable
    }

    function test_RevokeUnpublishedReverts() public {
        vm.prank(creator);
        vm.expectRevert(SignalRegistry.NotPublished.selector);
        registry.revoke(keccak256("nope"));
    }

    function test_CreatorEnumeration() public {
        vm.startPrank(creator);
        registry.publish(keccak256("a"), hash1, price);
        registry.publish(keccak256("b"), hash1, price);
        vm.stopPrank();
        bytes32[] memory ids = registry.creatorSignals(creator);
        assertEq(ids.length, 2);
    }
}
