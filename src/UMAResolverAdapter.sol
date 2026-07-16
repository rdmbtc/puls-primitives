// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title UMAResolverAdapter
 * @notice Bridges Puls LMSR markets to UMA's Optimistic Oracle V2 (OOV2) for
 *         decentralized, disputable resolution.
 *
 *         Flow:
 *           1. Backend creates an LMSRMarket via the factory, then transfers
 *              ownership to this adapter (2-step). `registerMarket` accepts
 *              ownership and stores the resolution question (ancillary data).
 *           2. After the market deadline, ANYONE can call `requestResolution`
 *              — the adapter opens a YES_OR_NO_QUERY price request on OOV2
 *              (bond + custom liveness configured here).
 *           3. A proposer (the Puls bot, or anyone) proposes 1e18 (YES) or 0
 *              (NO) directly on OOV2, posting the USDC bond.
 *           4. If nobody disputes during the liveness window, ANYONE can call
 *              `settle` — the adapter settles the OOV2 request and calls
 *              `market.resolve(outcome)`. Disputes escalate to the DVM
 *              (mock oracle on Arc Testnet).
 *
 *         Escape hatches (admin only): `adminResolve` for indeterminate
 *         answers / dead oracle, `reclaimMarket` to take ownership back.
 *
 * Arc Testnet:
 *   Chain ID : 5042002
 *   USDC     : 0x3600000000000000000000000000000000000000 (6 decimals)
 */
interface ILMSRMarket {
    function deadline() external view returns (uint256);
    function resolved() external view returns (bool);
    function resolve(bool _outcome) external;
    function acceptOwnership() external;
    function transferOwnership(address newOwner) external;
    function owner() external view returns (address);
}

interface IOptimisticOracleV2 {
    function requestPrice(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        address currency,
        uint256 reward
    ) external returns (uint256 totalBond);

    function setBond(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        uint256 bond
    ) external returns (uint256 totalBond);

    function setCustomLiveness(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        uint256 customLiveness
    ) external;

    function settleAndGetPrice(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData
    ) external returns (int256);

    /// @dev OOV2 State enum: 0 Invalid, 1 Requested, 2 Proposed, 3 Expired,
    ///      4 Disputed, 5 Resolved, 6 Settled
    function getState(
        address requester,
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData
    ) external view returns (uint8);

    function hasPrice(
        address requester,
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData
    ) external view returns (bool);
}

contract UMAResolverAdapter {
    // ── Constants ─────────────────────────────────────────────────────────────

    bytes32 public constant IDENTIFIER = "YES_OR_NO_QUERY";
    int256 public constant YES_PRICE = 1e18;
    int256 public constant NO_PRICE = 0;

    // ── State ─────────────────────────────────────────────────────────────────

    IOptimisticOracleV2 public immutable oracle;
    address public immutable bondCurrency; // USDC
    address public admin;

    uint256 public bond;     // proposer bond in bondCurrency units (6 dec USDC)
    uint256 public liveness; // dispute window in seconds

    struct Resolution {
        bool registered;
        bool requested;
        bool settled;
        uint256 requestTimestamp; // timestamp key of the OOV2 request
        bytes ancillaryData;
    }

    mapping(address => Resolution) public resolutions;
    address[] public registeredMarkets;

    // ── Events ────────────────────────────────────────────────────────────────

    event MarketRegistered(address indexed market, bytes ancillaryData);
    event ResolutionRequested(address indexed market, uint256 timestamp, bytes ancillaryData);
    event MarketSettled(address indexed market, int256 price, bool outcome);
    event AdminResolved(address indexed market, bool outcome);
    event MarketReclaimed(address indexed market, address indexed to);
    event ConfigUpdated(uint256 bond, uint256 liveness);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    // ── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(
        address _oracle,
        address _bondCurrency,
        uint256 _bond,
        uint256 _liveness
    ) {
        require(_oracle != address(0) && _bondCurrency != address(0), "Zero address");
        require(_liveness > 0, "Liveness required");
        oracle = IOptimisticOracleV2(_oracle);
        bondCurrency = _bondCurrency;
        admin = msg.sender;
        bond = _bond;
        liveness = _liveness;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setConfig(uint256 _bond, uint256 _liveness) external onlyAdmin {
        require(_liveness > 0, "Liveness required");
        bond = _bond;
        liveness = _liveness;
        emit ConfigUpdated(_bond, _liveness);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero address");
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    /// @notice Accept ownership of a market (must be `pendingOwner` already)
    ///         and store the resolution question as UMA ancillary data.
    function registerMarket(address market, string calldata question) external onlyAdmin {
        Resolution storage r = resolutions[market];
        require(!r.registered, "Already registered");

        ILMSRMarket(market).acceptOwnership();
        require(ILMSRMarket(market).owner() == address(this), "Ownership not accepted");

        r.registered = true;
        r.ancillaryData = abi.encodePacked(
            "q: title: ", question,
            ", res_data: p1: 0, p2: 1, p3: 0.5. Where p1 corresponds to NO, p2 to YES, p3 to unknown/50-50"
        );
        registeredMarkets.push(market);

        emit MarketRegistered(market, r.ancillaryData);
    }

    /// @notice Escape hatch: directly resolve a market the adapter owns
    ///         (indeterminate oracle answer, dead oracle, ...).
    function adminResolve(address market, bool outcome) external onlyAdmin {
        ILMSRMarket(market).resolve(outcome);
        resolutions[market].settled = true;
        emit AdminResolved(market, outcome);
    }

    /// @notice Escape hatch: hand market ownership back (2-step on the market).
    function reclaimMarket(address market, address to) external onlyAdmin {
        require(to != address(0), "Zero address");
        ILMSRMarket(market).transferOwnership(to);
        emit MarketReclaimed(market, to);
    }

    // ── Permissionless resolution flow ───────────────────────────────────────

    /// @notice After the market deadline, open a price request on OOV2.
    ///         Callable by anyone.
    function requestResolution(address market) external {
        Resolution storage r = resolutions[market];
        require(r.registered, "Not registered");
        require(!r.requested, "Already requested");
        require(!ILMSRMarket(market).resolved(), "Already resolved");

        uint256 marketDeadline = ILMSRMarket(market).deadline();
        require(block.timestamp >= marketDeadline, "Market not expired");

        r.requested = true;
        r.requestTimestamp = marketDeadline;

        oracle.requestPrice(IDENTIFIER, marketDeadline, r.ancillaryData, bondCurrency, 0);
        if (bond > 0) {
            oracle.setBond(IDENTIFIER, marketDeadline, r.ancillaryData, bond);
        }
        oracle.setCustomLiveness(IDENTIFIER, marketDeadline, r.ancillaryData, liveness);

        emit ResolutionRequested(market, marketDeadline, r.ancillaryData);
    }

    /// @notice After a proposal survives its liveness window (or a dispute is
    ///         resolved by the DVM), settle the request and resolve the market.
    ///         Callable by anyone.
    function settle(address market) external {
        Resolution storage r = resolutions[market];
        require(r.requested, "Not requested");
        require(!r.settled, "Already settled");

        int256 price = oracle.settleAndGetPrice(IDENTIFIER, r.requestTimestamp, r.ancillaryData);

        bool outcome;
        if (price == YES_PRICE) {
            outcome = true;
        } else if (price == NO_PRICE) {
            outcome = false;
        } else {
            // 0.5e18 ("unknown") or any non-standard answer: leave for adminResolve.
            revert("Indeterminate answer");
        }

        r.settled = true;
        ILMSRMarket(market).resolve(outcome);

        emit MarketSettled(market, price, outcome);
    }

    // ── Views ─────────────────────────────────────────────────────────────────

    function marketCount() external view returns (uint256) {
        return registeredMarkets.length;
    }

    function getResolution(address market)
        external
        view
        returns (
            bool registered,
            bool requested,
            bool settled,
            uint256 requestTimestamp,
            bytes memory ancillaryData,
            uint8 oracleState
        )
    {
        Resolution storage r = resolutions[market];
        uint8 state = 0;
        if (r.requested) {
            state = oracle.getState(address(this), IDENTIFIER, r.requestTimestamp, r.ancillaryData);
        }
        return (r.registered, r.requested, r.settled, r.requestTimestamp, r.ancillaryData, state);
    }
}
