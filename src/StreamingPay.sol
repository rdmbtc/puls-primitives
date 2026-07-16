// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title StreamingPay
/// @notice On-chain pay-per-second USDC streaming on Arc (streaming &
///         continuous payments). The trust-minimised counterpart to Puls'
///         off-chain stream metering: a payer escrows USDC and authorises a
///         RATE (micro-USDC/second) instead of signing each payment. The
///         recipient can withdraw exactly `rate * elapsed-active-seconds` at any
///         time; the payer can pause (freeze the meter), resume, top up, or stop
///         (the recipient is paid what flowed, the payer is refunded the rest).
///
///         "A grant of water was a rate of flow, not a volume." One signature
///         authorises a continuous flow that settles by the second on Arc.
contract StreamingPay {
    IERC20 public immutable usdc;
    uint256 public nextId = 1;

    struct Stream {
        address payer;
        address recipient;
        uint256 ratePerSec;   // micro-USDC per second
        uint256 deposit;      // escrowed cap (micro-USDC)
        uint256 withdrawn;    // already paid out to the recipient
        uint256 accruedBase;  // accrual frozen at the last pause/stop
        uint64  lastResumeAt; // when the meter last (re)started
        bool    active;       // is the meter running?
        bool    stopped;      // terminal
    }

    mapping(uint256 => Stream) public streams;

    event StreamOpened(uint256 indexed id, address indexed payer, address indexed recipient, uint256 ratePerSec, uint256 deposit);
    event Withdrawn(uint256 indexed id, address indexed recipient, uint256 amount);
    event Paused(uint256 indexed id);
    event Resumed(uint256 indexed id);
    event ToppedUp(uint256 indexed id, uint256 amount, uint256 deposit);
    event StreamStopped(uint256 indexed id, uint256 streamed, uint256 refunded);

    error BadParams();
    error NotFound();
    error NotPayer();
    error NotParty();
    error AlreadyStopped();
    error Exhausted();
    error TransferFailed();
    error Nothing();

    constructor(address _usdc) {
        usdc = IERC20(_usdc);
    }

    /// @notice Open a stream: escrow `deposit` USDC and authorise `ratePerSec`.
    function open(address recipient, uint256 ratePerSec, uint256 deposit) external returns (uint256 id) {
        if (recipient == address(0) || recipient == msg.sender || ratePerSec == 0 || deposit == 0) revert BadParams();
        if (!usdc.transferFrom(msg.sender, address(this), deposit)) revert TransferFailed();
        id = nextId++;
        streams[id] = Stream({
            payer: msg.sender,
            recipient: recipient,
            ratePerSec: ratePerSec,
            deposit: deposit,
            withdrawn: 0,
            accruedBase: 0,
            lastResumeAt: uint64(block.timestamp),
            active: true,
            stopped: false
        });
        emit StreamOpened(id, msg.sender, recipient, ratePerSec, deposit);
    }

    /// @notice Total streamed so far (capped at the deposit).
    function streamed(uint256 id) public view returns (uint256) {
        Stream storage s = streams[id];
        if (s.payer == address(0)) revert NotFound();
        uint256 a = s.accruedBase;
        if (s.active && !s.stopped) a += s.ratePerSec * (block.timestamp - s.lastResumeAt);
        return a > s.deposit ? s.deposit : a;
    }

    /// @notice Amount the recipient can withdraw right now.
    function withdrawable(uint256 id) external view returns (uint256) {
        return streamed(id) - streams[id].withdrawn;
    }

    /// @notice Recipient pulls everything that has flowed but isn't yet paid.
    function withdraw(uint256 id) external returns (uint256 amount) {
        Stream storage s = streams[id];
        if (s.payer == address(0)) revert NotFound();
        amount = streamed(id) - s.withdrawn;
        if (amount == 0) revert Nothing();
        s.withdrawn += amount;
        if (!usdc.transfer(s.recipient, amount)) revert TransferFailed();
        emit Withdrawn(id, s.recipient, amount);
    }

    function _freeze(Stream storage s) internal {
        uint256 a = s.accruedBase + (s.active ? s.ratePerSec * (block.timestamp - s.lastResumeAt) : 0);
        s.accruedBase = a > s.deposit ? s.deposit : a;
        s.active = false;
    }

    /// @notice Pause the meter (payer or recipient). Accrual freezes.
    function pause(uint256 id) external {
        Stream storage s = streams[id];
        if (s.payer == address(0)) revert NotFound();
        if (msg.sender != s.payer && msg.sender != s.recipient) revert NotParty();
        if (s.stopped || !s.active) return;
        _freeze(s);
        emit Paused(id);
    }

    /// @notice Resume a paused stream (payer only).
    function resume(uint256 id) external {
        Stream storage s = streams[id];
        if (s.payer == address(0)) revert NotFound();
        if (msg.sender != s.payer) revert NotPayer();
        if (s.stopped) revert AlreadyStopped();
        if (s.active) return;
        if (s.accruedBase >= s.deposit) revert Exhausted();
        s.lastResumeAt = uint64(block.timestamp);
        s.active = true;
        emit Resumed(id);
    }

    /// @notice Extend a stream by escrowing more USDC (payer only).
    function topUp(uint256 id, uint256 amount) external {
        Stream storage s = streams[id];
        if (s.payer == address(0)) revert NotFound();
        if (msg.sender != s.payer) revert NotPayer();
        if (s.stopped) revert AlreadyStopped();
        if (amount == 0) revert BadParams();
        if (!usdc.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        s.deposit += amount;
        emit ToppedUp(id, amount, s.deposit);
    }

    /// @notice Stop the stream (payer or recipient): pay the recipient what
    ///         flowed, refund the payer the rest. Terminal.
    function stop(uint256 id) external returns (uint256 streamedAmt, uint256 refunded) {
        Stream storage s = streams[id];
        if (s.payer == address(0)) revert NotFound();
        if (msg.sender != s.payer && msg.sender != s.recipient) revert NotParty();
        if (s.stopped) revert AlreadyStopped();
        _freeze(s);
        s.stopped = true;
        streamedAmt = s.accruedBase;

        uint256 owed = streamedAmt - s.withdrawn;
        if (owed > 0) {
            s.withdrawn += owed;
            if (!usdc.transfer(s.recipient, owed)) revert TransferFailed();
            emit Withdrawn(id, s.recipient, owed);
        }
        refunded = s.deposit - streamedAmt;
        if (refunded > 0) {
            if (!usdc.transfer(s.payer, refunded)) revert TransferFailed();
        }
        emit StreamStopped(id, streamedAmt, refunded);
    }

    function getStream(uint256 id) external view returns (Stream memory) {
        return streams[id];
    }
}
