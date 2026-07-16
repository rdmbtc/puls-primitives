# Puls Primitives for Arc Open Source Showcase

This repository contains the core, reusable infrastructure and primitives built for the **Puls** agent-economy toolkit. It is designed for developers building on the **Arc** blockchain who need robust solutions for agent interactions, streaming payments, and on-chain prediction markets.

## What primitives are we exposing?

We expose several key primitives that any Arc builder can easily fork and adapt:

1. **x402 Nanopayments on Arc**
   - **What it is:** A working HTTP-402 flow coupled with sub-cent USDC settlement for paywalled content and APIs. 
   - **Why it matters:** It enables seamless agent-to-agent and agent-to-API nanopayments, a missing link in current Web3 AI interactions.
   - **Where to find it:** See the `examples/x402-server.js` reference implementation.

2. **Pay-per-second Streaming (`StreamingPay.sol`)**
   - **What it is:** A trust-minimized escrow contract that supports continuous flow payments (deposit + rate). It allows withdrawing exactly `rate × elapsed time` with features to pause, resume, and stop with a refund.
   - **Why it matters:** Arc lacked a continuous-payment primitive. `StreamingPay.sol` is fully agent-driveable, enabling models like pay-per-second video or live data streaming.

3. **UMA Optimistic Oracle V2 Adapter**
   - **What it is:** We have deployed UMA's Optimistic Oracle V2 on Arc and provided an adapter (`UMAResolverAdapter.sol`).
   - **Why it matters:** Prediction market, RWA, or dispute builders on Arc can reuse this for trust-minimized resolution instead of having to port and deploy the entire UMA stack themselves.

4. **AgentBond**
   - **What it is:** A smart contract (`AgentBond.sol`) where AI agents must stake USDC on their calls. Correct predictions return the stake; incorrect predictions slash it to the treasury.
   - **Why it matters:** It serves as a reusable "reputation-as-capital" primitive to ensure accountable AI behavior.

5. **ERC-8004 Agent Identity**
   - **What it is:** Agent identity structures wired to real on-chain outcomes, providing verifiable reputation patterns.

6. **LMSR Market Factory**
   - **What it is:** An on-chain Logarithmic Market Scoring Rule (LMSR) automated market maker (AMM) for binary markets (`LMSRMarket.sol` & `LMSRMarketFactory.sol`).

## Compared to the code out there for Arc builders (mostly in circlefin/arc-* repos), what tools and flows do we add?

The baseline `circlefin/arc-*` repositories generally focus on basic commerce and escrow flows (e.g., `arc-commerce`, `arc-p2p-payments`). 

**Puls** ships a comprehensive toolkit targeting the emerging **agent economy**:
- We add **continuous stream settlement** rather than just point-in-time transactions.
- We add **x402 nanopayment** patterns explicitly designed for agents buying and selling data APIs.
- We add a fully integrated **UMA Oracle adapter**, reducing the heavy lifting required for complex dispute resolutions.
- We introduce **AgentBonds**, giving developers a drop-in contract for AI accountability.

In summary, builders get the missing advanced flows—streaming, nanopayments, on-chain oracle resolution, and agent capital accountability—backed by live reference usage.

## Repository Structure

- `src/` - Contains the Foundry smart contracts (`StreamingPay.sol`, `AgentBond.sol`, `LMSRMarket.sol`, `UMAResolverAdapter.sol`).
- `test/` - Comprehensive Foundry test suites for the contracts.
- `script/` - Deployment scripts.
- `examples/` - Application-layer examples (e.g., x402 payment flows).

## Getting Started

This is a standard Foundry project. To build and test the contracts:

```bash
forge install
forge build
forge test
```
