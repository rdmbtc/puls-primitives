<div align="center">
  <h1>⚡ Puls Primitives</h1>
  <p><strong>A reusable agent-economy toolkit built for the Arc blockchain.</strong></p>

  <img src="https://img.shields.io/badge/Arc-000000?style=for-the-badge&logo=circle&logoColor=white" alt="Arc" />
  <img src="https://img.shields.io/badge/Foundry-FCC624?style=for-the-badge&logo=rust&logoColor=white" alt="Foundry" />
  <img src="https://img.shields.io/badge/Solidity-363636?style=for-the-badge&logo=solidity&logoColor=white" alt="Solidity" />
  <img src="https://img.shields.io/badge/Viem-FFB84C?style=for-the-badge&logo=javascript&logoColor=black" alt="Viem" />
</div>

<br />

Welcome to the open-source toolkit powering **Puls**. This repository contains the core, reusable smart contracts and infrastructure patterns designed explicitly for builders working on the **Arc Open Source Showcase**.

If you are building the next wave of agentic applications, prediction markets, or micropayment gateways on Arc, you can fork, import, and ship on top of these primitives immediately.

---

## 📦 What primitives are we exposing?

We expose several key building blocks that push beyond standard commerce flows:

### 1. `StreamingPay.sol`: Pay-per-second Streaming
Arc lacked a native continuous-payment primitive. We built a trust-minimized escrow contract that supports continuous flow payments (deposit + rate). It allows withdrawing exactly `rate × elapsed time` with features to pause, resume, and stop with an automatic refund.  
**Use Case:** Fully agent-driveable pay-per-second video, live data streaming, or continuous API billing.

### 2. x402 Nanopayments on Arc
A working HTTP-402 flow coupled with sub-cent USDC settlement for paywalled content and APIs. 
**Use Case:** Seamless agent-to-agent and agent-to-API nanopayments—a missing link in current Web3 AI interactions. *(See `examples/x402-server.js`)*

### 3. AgentBonds (`AgentBond.sol` & `AgentDuel.sol`)
Smart contracts where AI agents must stake USDC on their calls. Correct predictions return the stake; incorrect predictions slash it to the treasury.  
**Use Case:** A drop-in "reputation-as-capital" primitive to ensure accountable AI behavior in your dApp.

### 4. UMA Optimistic Oracle V2 Adapter
We have deployed UMA's Optimistic Oracle V2 directly on Arc and provided a seamless adapter (`UMAResolverAdapter.sol`).  
**Use Case:** Any prediction market, RWA, or dispute builder on Arc can reuse this for trust-minimized resolution instead of having to port and deploy the entire UMA stack themselves.

### 5. On-Chain LMSR Market Factory
A fully on-chain Logarithmic Market Scoring Rule (LMSR) automated market maker (AMM) for binary markets (`LMSRMarket.sol` & `LMSRMarketFactory.sol`).

---

## ⚖️ Compared to existing Arc examples, what do we add?

The baseline `circlefin/arc-*` repositories generally focus on traditional, point-in-time transactions (like basic `arc-commerce` and `arc-p2p-payments`). 

**Puls ships a comprehensive toolkit targeting the emerging agent economy:**
- We add **continuous stream settlement** rather than just single-point transactions.
- We add **x402 nanopayment patterns** explicitly designed for autonomous agents buying and selling data APIs.
- We add a fully integrated **UMA Oracle adapter**, drastically reducing the heavy lifting required for complex dispute resolutions on Arc.
- We introduce **AgentBonds**, giving developers a ready-to-use contract for AI accountability.

**Net result:** Builders get advanced flows backed by live reference usage.

---

## 📂 Repository Architecture

```text
puls-primitives/
├── src/                # Solidity Contracts (StreamingPay, AgentBonds, LMSR, UMA)
├── test/               # Comprehensive Foundry test suites
├── script/             # Foundry Solidity deployment scripts
├── scripts/            # Node.js (Viem) interaction & deployment scripts
├── deployments/        # Deployed contract addresses (JSON artifacts)
└── examples/           # Application-layer examples (e.g., x402 API server)
```

---

## 🛠️ Quick Start

This repository is built with [Foundry](https://getfoundry.sh/). 

### Prerequisites
- Install Foundry
- Install Node.js & npm (for scripts)

### Build and Test

```bash
# Install dependencies
forge install
npm install

# Build the contracts
forge build

# Run the test suite
forge test
```

### Running Node Scripts

All deployment and utility scripts have been moved to the `scripts/` directory. They use `viem` to interact with the Arc Testnet.

```bash
# Example: Deploy AgentBond
node scripts/deployAgentBond.mjs
```

> **Note:** Copy `.env.example` to `.env` and fill in your variables before running deployment scripts.

---

<div align="center">
  <i>Built with ❤️ for the Arc Open Source Showcase</i>
</div>
