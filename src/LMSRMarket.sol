// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SD59x18, sd, unwrap, exp, ln } from "prb-math/SD59x18.sol";

/**
 * @title LMSRMarket
 * @notice Logarithmic Market Scoring Rule (LMSR) binary prediction market on Arc Testnet.
 *         Users buy YES or NO shares with USDC (6 decimals).
 *         Cost function: C = b * ln(exp(q1/b) + exp(q2/b))
 *
 * v2 changes:
 *   - Slippage protection: buy/sell overloads with minSharesOut / minUsdcOut
 *   - On-chain price views: getYesPrice() / getNoPrice() (6-decimal probability)
 *   - Safe ERC20 transfers (return values checked everywhere)
 *   - Trading fully closes at deadline (sells were previously open until resolution)
 *   - Emergency exit: if the market is never resolved, traders can redeem
 *     pro-rata after deadline + EMERGENCY_DELAY instead of losing funds forever
 *
 * Arc Testnet:
 *   Chain ID : 5042002
 *   USDC     : 0x3600000000000000000000000000000000000000
 */
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract LMSRMarket {
    // ── State ─────────────────────────────────────────────────────────────────

    IERC20 public immutable usdc;
    address public owner;
    uint256 public totalClaimed;

    string  public slug;
    uint256 public deadline;
    bool    public resolved;
    bool    public outcome; // true = YES wins, false = NO wins

    // Liquid parameter `b` (USDC scaled to 6 decimals)
    uint256 public b;

    // Outstanding shares (6 decimals)
    uint256 public yesOutstanding;
    uint256 public noOutstanding;

    mapping(address => uint256) public yesShares;
    mapping(address => uint256) public noShares;
    mapping(address => bool)    public claimed;

    // ── Emergency exit (unresolved markets) ───────────────────────────────────

    /// @notice If the owner never resolves, traders can exit pro-rata after this delay.
    uint256 public constant EMERGENCY_DELAY = 30 days;

    uint256 public emergencyPool;        // USDC balance snapshot at first emergency redemption
    uint256 public emergencyTotalShares; // yes+no outstanding snapshot at first emergency redemption
    mapping(address => bool) public emergencyClaimed;

    // ── Events ────────────────────────────────────────────────────────────────

    event Funded(address indexed funder, uint256 amount);
    event Bought(address indexed user, bool side, uint256 amount, uint256 shares);
    event Sold(address indexed user, bool side, uint256 shares, uint256 usdcOut);
    event Resolved(bool outcome);
    event Claimed(address indexed user, uint256 payout);
    event EmergencyRedeemed(address indexed user, uint256 shares, uint256 payout);

    // ── Constructor ───────────────────────────────────────────────────────────

    bool public isFunded;
    address public immutable factory;

    constructor(
        address _usdc,
        string memory _slug,
        uint256 _deadline,
        uint256 _b, // Liquidity parameter (e.g. 1000 USDC = 1_000_000_000)
        address _owner
    ) {
        require(_b > 0, "b required");
        require(_deadline > block.timestamp, "Deadline in past");
        usdc     = IERC20(_usdc);
        owner    = _owner;
        factory  = msg.sender;
        slug     = _slug;
        deadline = _deadline;
        b        = _b;
    }

    // ── Safe ERC20 helpers ────────────────────────────────────────────────────

    function _safeTransfer(address to, uint256 amount) internal {
        require(usdc.transfer(to, amount), "USDC transfer failed");
    }

    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        require(usdc.transferFrom(from, to, amount), "USDC transferFrom failed");
    }

    /// @notice The market creator must seed the maximum theoretical loss (subsidy)
    function fund() external {
        require(msg.sender == owner || msg.sender == factory, "Not owner or factory");
        require(!isFunded, "Already funded");
        uint256 initialCost = getCostStable(0, 0);
        require(initialCost > 0, "Initial cost too small");
        _safeTransferFrom(msg.sender, address(this), initialCost);
        isFunded = true;
        emit Funded(msg.sender, initialCost);
    }

    // ── Math (Log-Sum-Exp Trick) ───────────────────────────────────────────────

    /// @notice Stable implementation of C(q1, q2) = b * ln(exp(q1/b) + exp(q2/b))
    /// M = max(q1, q2)
    /// C = M + b * ln(exp((q1 - M)/b) + exp((q2 - M)/b))
    function getCostStable(uint256 q1, uint256 q2) public view returns (uint256) {
        SD59x18 b_sd = sd(int256(b * 1e12));
        SD59x18 q1_sd = sd(int256(q1 * 1e12));
        SD59x18 q2_sd = sd(int256(q2 * 1e12));

        SD59x18 max_q = q1_sd > q2_sd ? q1_sd : q2_sd;

        SD59x18 exp1 = exp((q1_sd.sub(max_q)).div(b_sd));
        SD59x18 exp2 = exp((q2_sd.sub(max_q)).div(b_sd));

        SD59x18 lnSum = ln(exp1.add(exp2));

        // cost = max_q + b * lnSum
        SD59x18 cost_sd = max_q.add(b_sd.mul(lnSum));

        int256 costInt = unwrap(cost_sd);
        return uint256(costInt) / 1e12;
    }

    // ── Prices ────────────────────────────────────────────────────────────────

    /// @notice Marginal YES price as a 6-decimal probability (500000 = $0.50).
    ///         p_yes = exp(q1/b) / (exp(q1/b) + exp(q2/b)) = 1 / (1 + exp((q2-q1)/b))
    function getYesPrice() public view returns (uint256) {
        SD59x18 b_sd = sd(int256(b * 1e12));
        SD59x18 q1_sd = sd(int256(yesOutstanding * 1e12));
        SD59x18 q2_sd = sd(int256(noOutstanding * 1e12));

        SD59x18 one = sd(1e18);
        SD59x18 expTerm = exp((q2_sd.sub(q1_sd)).div(b_sd));
        SD59x18 price = one.div(one.add(expTerm)); // 18-decimal fraction in [0,1]

        int256 p = unwrap(price);
        if (p < 0) return 0;
        return uint256(p) / 1e12; // scale to 6 decimals
    }

    /// @notice Marginal NO price as a 6-decimal probability (complement of YES).
    function getNoPrice() external view returns (uint256) {
        return 1e6 - getYesPrice();
    }

    /// @notice Returns YES shares obtained for spending `amount` USDC
    function calcBuyYesShares(uint256 amount) public view returns (uint256) {
        uint256 c0 = getCostStable(yesOutstanding, noOutstanding);
        uint256 c1 = c0 + amount;

        SD59x18 b_sd = sd(int256(b * 1e12));
        SD59x18 c1_sd = sd(int256(c1 * 1e12));
        SD59x18 q2_sd = sd(int256(noOutstanding * 1e12));

        SD59x18 expTerm = exp((q2_sd.sub(c1_sd)).div(b_sd));
        SD59x18 one = sd(1e18);
        SD59x18 inner = one.sub(expTerm);
        require(unwrap(inner) > 0, "Lopsided market: precision limit");
        SD59x18 logInner = ln(inner);

        SD59x18 term = c1_sd.add(b_sd.mul(logInner));
        SD59x18 q1_sd = sd(int256(yesOutstanding * 1e12));
        SD59x18 delta_q_sd = term.sub(q1_sd);

        int256 deltaVal = unwrap(delta_q_sd);
        require(deltaVal >= 0, "Math error: negative shares");
        return uint256(deltaVal) / 1e12;
    }

    /// @notice Returns NO shares obtained for spending `amount` USDC
    function calcBuyNoShares(uint256 amount) public view returns (uint256) {
        uint256 c0 = getCostStable(yesOutstanding, noOutstanding);
        uint256 c1 = c0 + amount;

        SD59x18 b_sd = sd(int256(b * 1e12));
        SD59x18 c1_sd = sd(int256(c1 * 1e12));
        SD59x18 q1_sd = sd(int256(yesOutstanding * 1e12));

        SD59x18 expTerm = exp((q1_sd.sub(c1_sd)).div(b_sd));
        SD59x18 one = sd(1e18);
        SD59x18 inner = one.sub(expTerm);
        require(unwrap(inner) > 0, "Lopsided market: precision limit");
        SD59x18 logInner = ln(inner);

        SD59x18 term = c1_sd.add(b_sd.mul(logInner));
        SD59x18 q2_sd = sd(int256(noOutstanding * 1e12));
        SD59x18 delta_q_sd = term.sub(q2_sd);

        int256 deltaVal = unwrap(delta_q_sd);
        require(deltaVal >= 0, "Math error: negative shares");
        return uint256(deltaVal) / 1e12;
    }

    function calcSellYesUsdc(uint256 shares) public view returns (uint256) {
        uint256 c0 = getCostStable(yesOutstanding, noOutstanding);
        uint256 c1 = getCostStable(yesOutstanding - shares, noOutstanding);
        return c0 - c1;
    }

    function calcSellNoUsdc(uint256 shares) public view returns (uint256) {
        uint256 c0 = getCostStable(yesOutstanding, noOutstanding);
        uint256 c1 = getCostStable(yesOutstanding, noOutstanding - shares);
        return c0 - c1;
    }

    // ── Trading ───────────────────────────────────────────────────────────────

    /// @notice Buy YES with no slippage bound (kept for backward compatibility).
    function buyYes(uint256 amount) external {
        _buyYes(amount, 0);
    }

    /// @notice Buy YES, reverting if fewer than `minSharesOut` shares are received.
    function buyYes(uint256 amount, uint256 minSharesOut) external {
        _buyYes(amount, minSharesOut);
    }

    /// @notice Buy NO with no slippage bound (kept for backward compatibility).
    function buyNo(uint256 amount) external {
        _buyNo(amount, 0);
    }

    /// @notice Buy NO, reverting if fewer than `minSharesOut` shares are received.
    function buyNo(uint256 amount, uint256 minSharesOut) external {
        _buyNo(amount, minSharesOut);
    }

    function _buyYes(uint256 amount, uint256 minSharesOut) internal {
        require(isFunded, "Not funded");
        require(!resolved, "Market resolved");
        require(block.timestamp < deadline, "Market closed");
        require(amount > 0, "Amount zero");

        uint256 boughtYes = calcBuyYesShares(amount);
        require(boughtYes > 0, "Zero shares out");
        require(boughtYes >= minSharesOut, "Slippage: insufficient shares out");

        yesOutstanding += boughtYes;
        yesShares[msg.sender] += boughtYes;

        _safeTransferFrom(msg.sender, address(this), amount);

        emit Bought(msg.sender, true, amount, boughtYes);
    }

    function _buyNo(uint256 amount, uint256 minSharesOut) internal {
        require(isFunded, "Not funded");
        require(!resolved, "Market resolved");
        require(block.timestamp < deadline, "Market closed");
        require(amount > 0, "Amount zero");

        uint256 boughtNo = calcBuyNoShares(amount);
        require(boughtNo > 0, "Zero shares out");
        require(boughtNo >= minSharesOut, "Slippage: insufficient shares out");

        noOutstanding += boughtNo;
        noShares[msg.sender] += boughtNo;

        _safeTransferFrom(msg.sender, address(this), amount);

        emit Bought(msg.sender, false, amount, boughtNo);
    }

    // ── Selling ───────────────────────────────────────────────────────────────

    /// @notice Sell YES with no slippage bound (kept for backward compatibility).
    function sellYes(uint256 shares) external {
        _sellYes(shares, 0);
    }

    /// @notice Sell YES, reverting if less than `minUsdcOut` USDC is received.
    function sellYes(uint256 shares, uint256 minUsdcOut) external {
        _sellYes(shares, minUsdcOut);
    }

    /// @notice Sell NO with no slippage bound (kept for backward compatibility).
    function sellNo(uint256 shares) external {
        _sellNo(shares, 0);
    }

    /// @notice Sell NO, reverting if less than `minUsdcOut` USDC is received.
    function sellNo(uint256 shares, uint256 minUsdcOut) external {
        _sellNo(shares, minUsdcOut);
    }

    function _sellYes(uint256 shares, uint256 minUsdcOut) internal {
        require(isFunded, "Not funded");
        require(!resolved, "Market resolved");
        require(block.timestamp < deadline, "Market closed");
        require(yesShares[msg.sender] >= shares, "Insufficient shares");
        require(shares > 0, "Shares zero");

        uint256 usdcOut = calcSellYesUsdc(shares);
        require(usdcOut > 0, "Payout too small");
        require(usdcOut >= minUsdcOut, "Slippage: insufficient USDC out");

        yesShares[msg.sender] -= shares;
        yesOutstanding -= shares;

        _safeTransfer(msg.sender, usdcOut);

        emit Sold(msg.sender, true, shares, usdcOut);
    }

    function _sellNo(uint256 shares, uint256 minUsdcOut) internal {
        require(isFunded, "Not funded");
        require(!resolved, "Market resolved");
        require(block.timestamp < deadline, "Market closed");
        require(noShares[msg.sender] >= shares, "Insufficient shares");
        require(shares > 0, "Shares zero");

        uint256 usdcOut = calcSellNoUsdc(shares);
        require(usdcOut > 0, "Payout too small");
        require(usdcOut >= minUsdcOut, "Slippage: insufficient USDC out");

        noShares[msg.sender] -= shares;
        noOutstanding -= shares;

        _safeTransfer(msg.sender, usdcOut);

        emit Sold(msg.sender, false, shares, usdcOut);
    }

    // ── Resolution ────────────────────────────────────────────────────────────

    function resolve(bool _outcome) external {
        require(msg.sender == owner, "Not owner");
        require(!resolved, "Already resolved");
        require(block.timestamp >= deadline, "Not yet");

        resolved = true;
        outcome  = _outcome;

        emit Resolved(_outcome);
    }

    function claim() external {
        require(resolved, "Not resolved");
        require(!claimed[msg.sender], "Already claimed");

        uint256 payout = outcome ? yesShares[msg.sender] : noShares[msg.sender];
        require(payout > 0, "No winning shares");

        claimed[msg.sender] = true;
        totalClaimed += payout;
        _safeTransfer(msg.sender, payout);

        emit Claimed(msg.sender, payout);
    }

    // ── Emergency exit ────────────────────────────────────────────────────────

    /// @notice If the market is never resolved (owner key lost, oracle dead, …)
    ///         traders can redeem their shares pro-rata against the contract
    ///         balance after `deadline + EMERGENCY_DELAY`. The pool and total
    ///         shares are snapshotted at the first redemption so every trader
    ///         gets the same rate regardless of redemption order.
    function emergencyRedeem() external {
        require(!resolved, "Market resolved");
        require(block.timestamp >= deadline + EMERGENCY_DELAY, "Emergency delay not reached");
        require(!emergencyClaimed[msg.sender], "Already redeemed");

        if (emergencyTotalShares == 0) {
            emergencyPool = usdc.balanceOf(address(this));
            emergencyTotalShares = yesOutstanding + noOutstanding;
            require(emergencyTotalShares > 0, "No shares outstanding");
        }

        uint256 userShares = yesShares[msg.sender] + noShares[msg.sender];
        require(userShares > 0, "No shares");

        uint256 payout = (emergencyPool * userShares) / emergencyTotalShares;
        require(payout > 0, "Payout too small");

        emergencyClaimed[msg.sender] = true;
        _safeTransfer(msg.sender, payout);

        emit EmergencyRedeemed(msg.sender, userShares, payout);
    }

    function ownerWithdraw() external {
        require(msg.sender == owner, "Not owner");
        require(resolved, "Not resolved");

        uint256 winningShares = outcome ? yesOutstanding : noOutstanding;
        uint256 unclaimed = winningShares - totalClaimed;
        uint256 balance = usdc.balanceOf(address(this));

        uint256 withdrawable = balance > unclaimed ? balance - unclaimed : 0;
        require(withdrawable > 0, "No withdrawable balance");

        _safeTransfer(msg.sender, withdrawable);
    }

    // ── Ownable2Step ──────────────────────────────────────────────────────────

    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "Not owner");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    // ── View ──────────────────────────────────────────────────────────────────

    function getMarketInfo() external view returns (
        string memory _slug,
        uint256 _deadline,
        bool _resolved,
        bool _outcome,
        uint256 _yesOutstanding,
        uint256 _noOutstanding
    ) {
        return (slug, deadline, resolved, outcome, yesOutstanding, noOutstanding);
    }

    function getUserPosition(address user) external view returns (
        uint256 _yesShares,
        uint256 _noShares,
        bool _claimed
    ) {
        return (yesShares[user], noShares[user], claimed[user]);
    }
}
