// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { LMSRMarket } from "../src/LMSRMarket.sol";
import { UMAResolverAdapter } from "../src/UMAResolverAdapter.sol";

contract MockUSDCUma {
    string public name = "Mock USDC";
    string public symbol = "USDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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

/// @dev Minimal OOV2 mock: records requests, lets the test drive proposal /
///      settlement, and enforces the same coarse state machine the adapter
///      relies on (request once, settle after price exists).
contract MockOptimisticOracleV2 {
    struct Request {
        address requester;
        address currency;
        uint256 reward;
        uint256 bond;
        uint256 customLiveness;
        bool exists;
        bool hasPrice;
        bool settled;
        int256 price;
    }

    mapping(bytes32 => Request) public requests;

    function _key(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(requester, identifier, timestamp, ancillaryData));
    }

    function requestPrice(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        address currency,
        uint256 reward
    ) external returns (uint256) {
        bytes32 k = _key(msg.sender, identifier, timestamp, ancillaryData);
        require(!requests[k].exists, "request already exists");
        requests[k] = Request({
            requester: msg.sender,
            currency: currency,
            reward: reward,
            bond: 0,
            customLiveness: 0,
            exists: true,
            hasPrice: false,
            settled: false,
            price: 0
        });
        return 0;
    }

    function setBond(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, uint256 bond)
        external returns (uint256)
    {
        bytes32 k = _key(msg.sender, identifier, timestamp, ancillaryData);
        require(requests[k].exists, "no request");
        requests[k].bond = bond;
        return bond;
    }

    function setCustomLiveness(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, uint256 liveness)
        external
    {
        bytes32 k = _key(msg.sender, identifier, timestamp, ancillaryData);
        require(requests[k].exists, "no request");
        requests[k].customLiveness = liveness;
    }

    /// @dev Test helper: simulate a proposal surviving liveness with `price`.
    function pushPrice(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, int256 price)
        external
    {
        bytes32 k = _key(requester, identifier, timestamp, ancillaryData);
        require(requests[k].exists, "no request");
        requests[k].hasPrice = true;
        requests[k].price = price;
    }

    function settleAndGetPrice(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external returns (int256)
    {
        bytes32 k = _key(msg.sender, identifier, timestamp, ancillaryData);
        Request storage r = requests[k];
        require(r.exists, "no request");
        require(r.hasPrice, "price not available");
        r.settled = true;
        return r.price;
    }

    function getState(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external view returns (uint8)
    {
        bytes32 k = _key(requester, identifier, timestamp, ancillaryData);
        Request storage r = requests[k];
        if (!r.exists) return 0; // Invalid
        if (r.settled) return 6; // Settled
        if (r.hasPrice) return 3; // Expired (proposal survived liveness)
        return 1; // Requested
    }

    function hasPrice(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external view returns (bool)
    {
        return requests[_key(requester, identifier, timestamp, ancillaryData)].hasPrice;
    }

    function getRequestBond(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external view returns (uint256)
    {
        return requests[_key(requester, identifier, timestamp, ancillaryData)].bond;
    }

    function getRequestLiveness(address requester, bytes32 identifier, uint256 timestamp, bytes memory ancillaryData)
        external view returns (uint256)
    {
        return requests[_key(requester, identifier, timestamp, ancillaryData)].customLiveness;
    }
}

contract UMAResolverAdapterTest is Test {
    MockUSDCUma usdc;
    MockOptimisticOracleV2 oo;
    UMAResolverAdapter adapter;
    LMSRMarket market;

    address admin = address(this);
    address alice = address(0xA11CE);
    address rando = address(0xBEEF);

    uint256 constant B = 1_000_000_000; // 1000 USDC liquidity param
    uint256 constant BOND = 1_000_000;  // 1 USDC
    uint256 constant LIVENESS = 600;    // 10 minutes
    string constant QUESTION = "Will BTC exceed $100k before 2027?";

    bytes32 constant IDENTIFIER = "YES_OR_NO_QUERY";

    function setUp() public {
        usdc = new MockUSDCUma();
        oo = new MockOptimisticOracleV2();
        adapter = new UMAResolverAdapter(address(oo), address(usdc), BOND, LIVENESS);

        market = new LMSRMarket(address(usdc), "btc-100k", block.timestamp + 1 days, B, admin);
        usdc.mint(admin, 10_000_000_000);
        usdc.approve(address(market), type(uint256).max);
        market.fund();

        // Hand market to the adapter (2-step) and register.
        market.transferOwnership(address(adapter));
        adapter.registerMarket(address(market), QUESTION);
    }

    function _ancillary() internal view returns (bytes memory data) {
        (, , , , data, ) = adapter.getResolution(address(market));
    }

    // ── Registration ──────────────────────────────────────────────────────────

    function testRegisterAcceptsOwnership() public view {
        assertEq(market.owner(), address(adapter));
        (bool registered, bool requested, bool settled, , bytes memory data, ) =
            adapter.getResolution(address(market));
        assertTrue(registered);
        assertFalse(requested);
        assertFalse(settled);
        assertGt(data.length, 0);
        assertEq(adapter.marketCount(), 1);
    }

    function testRegisterRevertsIfNotPendingOwner() public {
        LMSRMarket other = new LMSRMarket(address(usdc), "x", block.timestamp + 1 days, B, admin);
        vm.expectRevert("Not pending owner");
        adapter.registerMarket(address(other), QUESTION);
    }

    function testRegisterOnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert("Not admin");
        adapter.registerMarket(address(market), QUESTION);
    }

    function testRegisterTwiceReverts() public {
        vm.expectRevert("Already registered");
        adapter.registerMarket(address(market), QUESTION);
    }

    // ── requestResolution ─────────────────────────────────────────────────────

    function testRequestBeforeDeadlineReverts() public {
        vm.expectRevert("Market not expired");
        adapter.requestResolution(address(market));
    }

    function testRequestUnregisteredReverts() public {
        vm.expectRevert("Not registered");
        adapter.requestResolution(address(0xDEAD));
    }

    function testAnyoneCanRequestAfterDeadline() public {
        vm.warp(market.deadline() + 1);
        vm.prank(rando);
        adapter.requestResolution(address(market));

        (, bool requested, , uint256 ts, bytes memory data, uint8 state) =
            adapter.getResolution(address(market));
        assertTrue(requested);
        assertEq(ts, market.deadline());
        assertEq(uint256(state), 1); // Requested
        assertEq(oo.getRequestBond(address(adapter), IDENTIFIER, ts, data), BOND);
        assertEq(oo.getRequestLiveness(address(adapter), IDENTIFIER, ts, data), LIVENESS);
    }

    function testRequestTwiceReverts() public {
        vm.warp(market.deadline() + 1);
        adapter.requestResolution(address(market));
        vm.expectRevert("Already requested");
        adapter.requestResolution(address(market));
    }

    // ── settle ────────────────────────────────────────────────────────────────

    function testSettleYes() public {
        vm.warp(market.deadline() + 1);
        adapter.requestResolution(address(market));
        oo.pushPrice(address(adapter), IDENTIFIER, market.deadline(), _ancillary(), 1e18);

        vm.prank(rando);
        adapter.settle(address(market));

        assertTrue(market.resolved());
        assertTrue(market.outcome());
        (, , bool settled, , , uint8 state) = adapter.getResolution(address(market));
        assertTrue(settled);
        assertEq(uint256(state), 6); // Settled
    }

    function testSettleNo() public {
        vm.warp(market.deadline() + 1);
        adapter.requestResolution(address(market));
        oo.pushPrice(address(adapter), IDENTIFIER, market.deadline(), _ancillary(), 0);

        adapter.settle(address(market));

        assertTrue(market.resolved());
        assertFalse(market.outcome());
    }

    function testSettleBeforePriceReverts() public {
        vm.warp(market.deadline() + 1);
        adapter.requestResolution(address(market));
        vm.expectRevert("price not available");
        adapter.settle(address(market));
    }

    function testSettleWithoutRequestReverts() public {
        vm.expectRevert("Not requested");
        adapter.settle(address(market));
    }

    function testSettleIndeterminateReverts() public {
        vm.warp(market.deadline() + 1);
        adapter.requestResolution(address(market));
        oo.pushPrice(address(adapter), IDENTIFIER, market.deadline(), _ancillary(), 0.5e18);

        vm.expectRevert("Indeterminate answer");
        adapter.settle(address(market));

        // Escape hatch still works.
        adapter.adminResolve(address(market), false);
        assertTrue(market.resolved());
        assertFalse(market.outcome());
    }

    function testSettleTwiceReverts() public {
        vm.warp(market.deadline() + 1);
        adapter.requestResolution(address(market));
        oo.pushPrice(address(adapter), IDENTIFIER, market.deadline(), _ancillary(), 1e18);
        adapter.settle(address(market));
        vm.expectRevert("Already settled");
        adapter.settle(address(market));
    }

    // ── Claims after UMA settlement (end to end) ─────────────────────────────

    function testTraderCanClaimAfterUmaSettlement() public {
        usdc.mint(alice, 1_000_000_000);
        vm.startPrank(alice);
        usdc.approve(address(market), type(uint256).max);
        market.buyYes(100_000_000); // 100 USDC on YES
        vm.stopPrank();

        vm.warp(market.deadline() + 1);
        adapter.requestResolution(address(market));
        oo.pushPrice(address(adapter), IDENTIFIER, market.deadline(), _ancillary(), 1e18);
        adapter.settle(address(market));

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        market.claim();
        assertGt(usdc.balanceOf(alice), before);
    }

    // ── Admin escape hatches ──────────────────────────────────────────────────

    function testAdminResolveOnlyAdmin() public {
        vm.warp(market.deadline() + 1);
        vm.prank(alice);
        vm.expectRevert("Not admin");
        adapter.adminResolve(address(market), true);
    }

    function testAdminResolve() public {
        vm.warp(market.deadline() + 1);
        adapter.adminResolve(address(market), true);
        assertTrue(market.resolved());
        assertTrue(market.outcome());
    }

    function testReclaimMarket() public {
        adapter.reclaimMarket(address(market), admin);
        market.acceptOwnership();
        assertEq(market.owner(), admin);
    }

    function testReclaimOnlyAdmin() public {
        vm.prank(alice);
        vm.expectRevert("Not admin");
        adapter.reclaimMarket(address(market), alice);
    }

    function testSetConfig() public {
        adapter.setConfig(5_000_000, 7200);
        assertEq(adapter.bond(), 5_000_000);
        assertEq(adapter.liveness(), 7200);

        vm.prank(alice);
        vm.expectRevert("Not admin");
        adapter.setConfig(1, 1);
    }

    function testTransferAdmin() public {
        adapter.transferAdmin(alice);
        assertEq(adapter.admin(), alice);
        vm.expectRevert("Not admin");
        adapter.setConfig(1, 1);
    }
}
