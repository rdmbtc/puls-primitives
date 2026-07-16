// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title AgentBond
/// @notice Skin-in-the-game for AI agent calls on Puls. When an agent publishes a
///         prediction-market "call" (a Creator Signal, attested in SignalRegistry),
///         it can post a USDC bond here. When the underlying market resolves:
///           • CORRECT  → the bond is returned to the agent,
///           • WRONG    → the bond is SLASHED to the treasury.
///
///         Reputation becomes *capital at risk*, not a number you're asked to
///         trust — settled on Arc in USDC. This is the on-chain answer to
///         "why should I believe this agent?": because it has money to lose.
///         Keyed by the same `signalId` as SignalRegistry, so a single call has
///         both verifiable provenance (content) and verifiable stake (money).
contract AgentBond {
    IERC20 public immutable usdc;
    address public owner;    // settler — the resolution pipeline / admin
    address public treasury; // slashed funds go here

    enum Status { None, Active, Returned, Slashed }

    struct Bond {
        address agent;
        bytes32 signalId;
        uint256 amount;    // 6-decimal USDC
        uint64  postedAt;
        uint64  settledAt;
        Status  status;
        bool    correct;   // outcome recorded at settle
    }

    /// @dev signalId => bond (one bond per signal/call).
    mapping(bytes32 => Bond) public bonds;
    bytes32[] private _allBondIds;

    uint256 public totalBondedUsdc;   // lifetime posted
    uint256 public totalSlashedUsdc;  // lifetime slashed (wrong calls)
    uint256 public totalReturnedUsdc; // lifetime returned (correct calls)
    uint256 public activeBondedUsdc;  // currently locked

    event BondPosted(bytes32 indexed signalId, address indexed agent, uint256 amount, uint64 postedAt);
    event BondSettled(bytes32 indexed signalId, address indexed agent, bool correct, uint256 amount, uint64 settledAt);
    event OwnerChanged(address indexed owner);
    event TreasuryChanged(address indexed treasury);

    error NotOwner();
    error BondExists();
    error NoBond();
    error NotActive();
    error ZeroAmount();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _usdc, address _treasury) {
        usdc = IERC20(_usdc);
        owner = msg.sender;
        treasury = _treasury == address(0) ? msg.sender : _treasury;
    }

    /// @notice Agent posts a USDC bond behind its call. The agent must first
    ///         `approve(this, amount)` on the USDC token; this pulls the funds.
    function postBond(bytes32 signalId, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        Bond storage b = bonds[signalId];
        if (b.status != Status.None) revert BondExists();

        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        b.agent = msg.sender;
        b.signalId = signalId;
        b.amount = amount;
        b.postedAt = uint64(block.timestamp);
        b.status = Status.Active;

        _allBondIds.push(signalId);
        totalBondedUsdc += amount;
        activeBondedUsdc += amount;

        emit BondPosted(signalId, msg.sender, amount, uint64(block.timestamp));
    }

    /// @notice Settle a bond on the resolved market outcome.
    ///         `correct=true` returns the stake to the agent; `false` slashes it
    ///         to the treasury. Restricted to the settler (resolution pipeline).
    function settle(bytes32 signalId, bool correct) external onlyOwner {
        Bond storage b = bonds[signalId];
        if (b.status == Status.None) revert NoBond();
        if (b.status != Status.Active) revert NotActive();

        b.status = correct ? Status.Returned : Status.Slashed;
        b.correct = correct;
        b.settledAt = uint64(block.timestamp);
        activeBondedUsdc -= b.amount;

        address to;
        if (correct) {
            totalReturnedUsdc += b.amount;
            to = b.agent;
        } else {
            totalSlashedUsdc += b.amount;
            to = treasury;
        }
        if (!usdc.transfer(to, b.amount)) revert TransferFailed();

        emit BondSettled(signalId, b.agent, correct, b.amount, uint64(block.timestamp));
    }

    // ── Admin ───────────────────────────────────────────────────────────────
    function setOwner(address n) external onlyOwner {
        owner = n;
        emit OwnerChanged(n);
    }

    function setTreasury(address n) external onlyOwner {
        treasury = n;
        emit TreasuryChanged(n);
    }

    // ── Views ─────────────────────────────────────────────────────────────────
    function bondCount() external view returns (uint256) {
        return _allBondIds.length;
    }

    function bondIdAt(uint256 i) external view returns (bytes32) {
        return _allBondIds[i];
    }

    function getBond(bytes32 signalId)
        external
        view
        returns (
            address agent,
            uint256 amount,
            uint64 postedAt,
            uint64 settledAt,
            Status status,
            bool correct
        )
    {
        Bond storage b = bonds[signalId];
        return (b.agent, b.amount, b.postedAt, b.settledAt, b.status, b.correct);
    }
}
