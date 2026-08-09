/**
 * Puls x402 Gateway buyer — a real, forkable buyer-side example.
 *
 * An AI agent (or human) pays for x402-protected resources through Circle
 * Gateway batched nanopayments on Arc Testnet. The GatewayClient handles the
 * full flow automatically:
 *   1. deposit USDC into Gateway (one-time, gasless from then on)
 *   2. request the resource → gets 402 + PAYMENT-REQUIRED
 *   3. signs an EIP-3009 batch authorization against the GatewayWallet
 *   4. retries with the payment signature → server verifies + settles
 *
 * Run:
 *   export PRIVATE_KEY=0x...buyer...   # Arc Testnet wallet with a little USDC
 *   npm run x402:buyer                 # points at http://localhost:3000 by default
 */
import 'dotenv/config';
import { GatewayClient } from '@circle-fin/x402-batching/client';

const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) {
  console.error('Set PRIVATE_KEY (an Arc Testnet wallet holding USDC) in .env');
  process.exit(1);
}

const BASE = (process.env.X402_URL || 'http://localhost:3000').replace(/\/$/, '');
const gateway = new GatewayClient({ chain: 'arcTestnet', privateKey: PRIVATE_KEY });

async function main() {
  console.log(`Buyer: ${gateway.address} (${gateway.chainName}, domain ${gateway.domain})`);

  // 0/3 check Gateway balance — deposit once if empty.
  const balances = await gateway.getBalances();
  console.log(
    `Balances — wallet: ${balances.wallet.formatted} USDC · gateway available: ${balances.gateway.formattedAvailable} USDC`,
  );

  const info = await (await fetch(`${BASE}/api/x402/info`)).json();
  console.log(`Server: ${info.configured ? `selling to ${info.sellerAddress}` : 'paywalls DISABLED (set X402_SELLER_ADDRESS)'}`);

  // 1/3 premium insight — $0.001
  const insight = await gateway.pay(`${BASE}/api/insight`);
  console.log(`\n1/3 /api/insight — paid ${insight.formattedAmount} USDC (tx ${insight.transaction})`);
  console.log('   →', JSON.stringify(insight.data));

  // 2/3 ask the swarm — $0.000001 (one lepton)
  const lepton = await gateway.pay(`${BASE}/api/lepton`);
  console.log(`\n2/3 /api/lepton — paid ${lepton.formattedAmount} USDC (tx ${lepton.transaction})`);
  console.log('   →', JSON.stringify(lepton.data));

  // 3/3 verify the transfers landed in Gateway history
  const transfers = await gateway.searchTransfers({ pageSize: 3 });
  console.log(`\n3/3 last ${transfers.transfers.length} Gateway transfer(s) — receipt trail on Arc:`);
  for (const t of transfers.transfers) {
    console.log(`   ${t.status.padEnd(10)} ${t.amount} USDC  ${t.fromAddress.slice(0, 10)}… → ${t.toAddress.slice(0, 10)}… (${t.createdAt})`);
  }
}

main().catch((e) => {
  console.error('buyer failed:', e?.message || e);
  process.exit(1);
});
