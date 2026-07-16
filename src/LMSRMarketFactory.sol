// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { LMSRMarket } from "./LMSRMarket.sol";

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract LMSRMarketFactory {
    address public immutable usdc;
    address public owner;
    address[] public markets;

    event MarketCreated(address indexed market, string slug, uint256 deadline);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address _usdc) {
        usdc = _usdc;
        owner = msg.sender;
    }

    function createMarket(
        string calldata slug,
        uint256 deadline,
        uint256 b
    ) external onlyOwner returns (address market) {
        // Pass owner (the factory owner) to the LMSRMarket constructor
        LMSRMarket m = new LMSRMarket(usdc, slug, deadline, b, owner);
        market = address(m);
        
        // Calculate funding cost
        uint256 initialCost = m.getCostStable(0, 0);
        
        // Transfer USDC from owner (msg.sender) to factory
        require(IERC20(usdc).transferFrom(msg.sender, address(this), initialCost), "Transfer from owner failed");
        
        // Approve market to pull USDC from factory
        require(IERC20(usdc).approve(market, initialCost), "Approve failed");
        
        // Fund the market
        m.fund();
        
        markets.push(market);
        emit MarketCreated(market, slug, deadline);
    }

    function allMarkets() external view returns (address[] memory) {
        return markets;
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    // ── Proxy functions ───────────────────────────────────────────────────────

    function resolveMarket(address market, bool outcome) external onlyOwner {
        LMSRMarket(market).resolve(outcome);
    }

    function withdrawFromMarket(address market) external onlyOwner {
        LMSRMarket(market).ownerWithdraw();
        uint256 balance = IERC20(usdc).balanceOf(address(this));
        if (balance > 0) {
            require(IERC20(usdc).transfer(owner, balance), "Transfer to owner failed");
        }
    }

    // ── Ownable2Step ──────────────────────────────────────────────────────────

    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
