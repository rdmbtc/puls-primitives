/**
 * Puls x402 Gateway server — a real, forkable seller-side example.
 *
 * Turns any Express route into a paid resource using Circle Gateway batched
 * nanopayments (x402) on Arc Testnet. A buyer (human or AI agent) pays a
 * sub-cent USDC nanopayment that settles to the seller's wallet through
 * Circle's Gateway facilitator — no per-transaction signing, no gas.
 *
 * Built on @circle-fin/x402-batching (the same library the live Puls backend
 * uses in `lib/x402.js`):
 *   - createGatewayMiddleware()  → Express middleware that answers 402 with a
 *     PAYMENT-REQUIRED header, verifies the buyer's signature against Circle
 *     Gateway, settles the nanopayment and exposes `req.payment`.
 *   - Gateway Wallet batched transfers (EIP-3009 authorizations against the
 *     GatewayWallet contract).
 *
 * Verified Arc Testnet constants (baked into @circle-fin/x402-batching):
 *   network           eip155:5042002
 *   USDC              0x3600000000000000000000000000000000000000 (6 dp)
 *   Gateway Wallet    0x0077777d7EBA4688BDeF3E311b846F25870A19B9
 *
 * Run:
 *   export X402_SELLER_ADDRESS=0x...YourSellerWallet...
 *   npm run x402:server
 *
 * Then pay with the buyer example (separate terminal):
 *   npm run x402:buyer
 */
import 'dotenv/config';
import express from 'express';
import { createGatewayMiddleware } from '@circle-fin/x402-batching/server';

const SELLER = (process.env.X402_SELLER_ADDRESS || '').trim();
const PORT = Number(process.env.PORT || 3000);

const app = express();
app.use(express.json());

if (!SELLER) {
  console.error('[x402] X402_SELLER_ADDRESS not set — paywalls disabled. Set it in .env to enable payments.');
}

// Accept payments on Arc Testnet only (default: all Gateway-supported networks).
const gateway = createGatewayMiddleware({
  sellerAddress: SELLER,
  networks: ['eip155:5042002'],
  description: 'Puls x402 example — pay sub-cent USDC for agent-grade insight',
});

// ── Free config endpoint (handy for demos + buyers) ─────────────────────────
app.get('/api/x402/info', (_req, res) => {
  res.json({
    network: 'eip155:5042002',
    asset: '0x3600000000000000000000000000000000000000',
    gatewayWallet: '0x0077777d7EBA4688BDeF3E311b846F25870A19B9',
    sellerAddress: SELLER || null,
    configured: Boolean(SELLER),
    paywalledEndpoints: [
      { path: '/api/insight', price: '$0.001' },
      { path: '/api/lepton', price: '$0.000001' },
    ],
  });
});

// ── Paid: premium insight, $0.001 per unlock ────────────────────────────────
app.get('/api/insight', gateway.require('$0.001'), (req, res) => {
  res.json({
    data: 'Verified macro + crypto intel for autonomous agents.',
    agent_action: 'Execute strategy',
    receipt: req.payment, // { verified, payer, amount, network, transaction }
  });
});

// ── Paid: ask the swarm, $0.000001 (one lepton) ─────────────────────────────
app.get('/api/lepton', gateway.require('$0.000001'), (req, res) => {
  res.json({
    answer: 'The swarm leans yes — 72% confidence across 8 agents.',
    receipt: req.payment,
  });
});

app.listen(PORT, () => {
  console.log(`Puls x402 Gateway server on :${PORT}${SELLER ? ` — selling to ${SELLER}` : ' — paywalls disabled'}`);
  console.log('Endpoints: GET /api/x402/info (free), /api/insight ($0.001), /api/lepton ($0.000001)');
});
