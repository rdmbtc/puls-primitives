// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title AgentDuel — the Colosseum
/// @notice Adversarial skin-in-the-game between two AI agents. Where AgentBond
///         lets a single agent stake on its own call (returned if right, slashed
///         to treasury if wrong), AgentDuel pits TWO agents against each other on
///         the SAME prediction market, on OPPOSITE sides:
///
///           • Agent A stakes USDC on YES, Agent B stakes USDC on NO.
///           • When the market resolves, the WINNER takes the LOSER's stake.
///           • Reputation isn't a score you're asked to trust — it's capital you
///             win or lose to another machine, settled on Arc in USDC.
///
///         This is the on-chain answer to "which agent is actually right?":
///         the one still holding the money. Keyed by a `duelId` (derived off-chain
///         from the market slug + the two agents) so a single market can host many
///         duels and each is independently verifiable.
///
///         An optional protocol fee (bps of the loser's stake) is skimmed to the
///         treasury on settlement — the house rake of the Colosseum.
contract AgentDuel {
    IERC20 public immutable usdc;
    address public owner;    // settler — the resolution pipeline / admin
    address public treasury; // protocol-fee sink
    uint16  public feeBps;    // protocol fee on the loser's stake, in bps (max 1000 = 10%)

    uint16 public constant MAX_FEE_BPS = 1000; // hard cap: 10%

    enum Status { None, Open, Locked, Settled, Cancelled }

    struct Duel {
        bytes32 duelId;
        address agentYes;   // staked on YES
        address agentNo;    // staked on NO
        uint256 stakeYes;   // 6-decimal USDC posted by agentYes
        uint256 stakeNo;    // 6-decimal USDC posted by agentNo
        uint64  openedAt;
        uint64  settledAt;
        Status  status;
        bool    outcomeYes; // resolved outcome recorded at settle (true = YES won)
        address winner;     // set at settle
    }

    /// @dev duelId => duel (one duel per id).
    mapping(bytes32 => Duel) public duels;
    bytes32[] private _allDuelIds;

    uint256 public totalDueledUsdc;   // lifetime staked across both sides
    uint256 public totalPaidUsdc;     // lifetime paid to winners (loser stake moved)
    uint256 public totalFeeUsdc;      // lifetime protocol fees to treasury
    uint256 public lockedUsdc;        // currently locked in open/locked duels
    uint256 public duelsSettled;      // lifetime settled

    event DuelOpened(bytes32 indexed duelId, address indexed agentYes, uint256 stakeYes, uint64 at);
    event DuelJoined(bytes32 indexed duelId, address indexed agentNo, uint256 stakeNo, uint64 at);
    event DuelSettled(bytes32 indexed duelId, address indexed winner, bool outcomeYes, uint256 payout, uint256 fee, uint64 at);
    event DuelCancelled(bytes32 indexed duelId, uint64 at);
    event OwnerChanged(address indexed owner);
    event TreasuryChanged(address indexed treasury);
    event FeeChanged(uint16 feeBps);

    error NotOwner();
    error DuelExists();
    error NoDuel();
    error NotOpen();
    error NotLocked();
    error ZeroAmount();
    error SameAgent();
    error TransferFailed();
    error FeeTooHigh();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _usdc, address _treasury, uint16 _feeBps) {
        if (_feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        usdc = IERC20(_usdc);
        owner = msg.sender;
        treasury = _treasury == address(0) ? msg.sender : _treasury;
        feeBps = _feeBps;
    }

    /// @notice Open a duel: the YES-side agent posts its stake and challenges the
    ///         NO side. The agent must first `approve(this, stakeYes)` on USDC.
    function openDuel(bytes32 duelId, uint256 stakeYes) external {
        if (stakeYes == 0) revert ZeroAmount();
        Duel storage d = duels[duelId];
        if (d.status != Status.None) revert DuelExists();

        if (!usdc.transferFrom(msg.sender, address(this), stakeYes)) revert TransferFailed();

        d.duelId = duelId;
        d.agentYes = msg.sender;
        d.stakeYes = stakeYes;
        d.openedAt = uint64(block.timestamp);
        d.status = Status.Open;

        _allDuelIds.push(duelId);
        totalDueledUsdc += stakeYes;
        lockedUsdc += stakeYes;

        emit DuelOpened(duelId, msg.sender, stakeYes, uint64(block.timestamp));
    }

    /// @notice Join an open duel on the NO side. The joining agent posts its own
    ///         stake (need not equal the YES stake — each side risks its own).
    ///         Must first `approve(this, stakeNo)` on USDC.
    function joinDuel(bytes32 duelId, uint256 stakeNo) external {
        if (stakeNo == 0) revert ZeroAmount();
        Duel storage d = duels[duelId];
        if (d.status != Status.Open) revert NotOpen();
        if (msg.sender == d.agentYes) revert SameAgent();

        if (!usdc.transferFrom(msg.sender, address(this), stakeNo)) revert TransferFailed();

        d.agentNo = msg.sender;
        d.stakeNo = stakeNo;
        d.status = Status.Locked;

        totalDueledUsdc += stakeNo;
        lockedUsdc += stakeNo;

        emit DuelJoined(duelId, msg.sender, stakeNo, uint64(block.timestamp));
    }

    /// @notice Settle a locked duel on the resolved market outcome.
    ///         The winner receives their own stake back PLUS the loser's stake,
    ///         minus an optional protocol fee taken from the loser's stake.
    ///         Restricted to the settler (resolution pipeline).
    function settle(bytes32 duelId, bool outcomeYes) external onlyOwner {
        Duel storage d = duels[duelId];
        if (d.status == Status.None) revert NoDuel();
        if (d.status != Status.Locked) revert NotLocked();

        d.status = Status.Settled;
        d.outcomeYes = outcomeYes;
        d.settledAt = uint64(block.timestamp);

        address winner = outcomeYes ? d.agentYes : d.agentNo;
        uint256 winnerStake = outcomeYes ? d.stakeYes : d.stakeNo;
        uint256 loserStake  = outcomeYes ? d.stakeNo  : d.stakeYes;

        d.winner = winner;
        lockedUsdc -= (d.stakeYes + d.stakeNo);

        uint256 fee = (loserStake * feeBps) / 10_000;
        uint256 spoils = loserStake - fee;      // loser's stake (net of fee) → winner
        uint256 payout = winnerStake + spoils;  // own stake back + spoils

        totalPaidUsdc += spoils;
        totalFeeUsdc += fee;
        duelsSettled += 1;

        if (payout > 0) {
            if (!usdc.transfer(winner, payout)) revert TransferFailed();
        }
        if (fee > 0) {
            if (!usdc.transfer(treasury, fee)) revert TransferFailed();
        }

        emit DuelSettled(duelId, winner, outcomeYes, payout, fee, uint64(block.timestamp));
    }

    /// @notice Refund an OPEN duel that never found an opponent. Returns the
    ///         YES-side stake to the agent. Settler-only (called by the reconciler
    ///         after a challenge window elapses or the market resolves unmatched).
    function cancelOpen(bytes32 duelId) external onlyOwner {
        Duel storage d = duels[duelId];
        if (d.status == Status.None) revert NoDuel();
        if (d.status != Status.Open) revert NotOpen();

        d.status = Status.Cancelled;
        d.settledAt = uint64(block.timestamp);
        lockedUsdc -= d.stakeYes;

        if (d.stakeYes > 0) {
            if (!usdc.transfer(d.agentYes, d.stakeYes)) revert TransferFailed();
        }

        emit DuelCancelled(duelId, uint64(block.timestamp));
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

    function setFeeBps(uint16 n) external onlyOwner {
        if (n > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = n;
        emit FeeChanged(n);
    }

    // ── Views ───────────────────────────────────────────────────────────────
    function duelCount() external view returns (uint256) {
        return _allDuelIds.length;
    }

    function duelIdAt(uint256 i) external view returns (bytes32) {
        return _allDuelIds[i];
    }

    function getDuel(bytes32 duelId)
        external
        view
        returns (
            address agentYes,
            address agentNo,
            uint256 stakeYes,
            uint256 stakeNo,
            uint64  openedAt,
            uint64  settledAt,
            Status  status,
            bool    outcomeYes,
            address winner
        )
    {
        Duel storage d = duels[duelId];
        return (d.agentYes, d.agentNo, d.stakeYes, d.stakeNo, d.openedAt, d.settledAt, d.status, d.outcomeYes, d.winner);
    }
}
