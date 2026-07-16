/**
 * Puls — bridge USDC from Ethereum Sepolia to Arc Testnet via Circle CCTP.
 *
 * Onboarding path: a user (or an agent treasury) brings USDC from Ethereum to
 * Arc so they can trade on Puls without waiting on a faucet. Uses CCTP V2 with
 * the **Forwarding Service** (burn-with-hook): Circle mints on Arc for you, so
 * you don't need ARC gas to call receiveMessage yourself.
 *
 * Verified CCTP V2 testnet constants (Circle docs, 2026-06):
 *   Ethereum Sepolia USDC            0x1c7d4b196cb0c7b01d743fbc6116a902379c7238
 *   Ethereum Sepolia TokenMessengerV2 0x8fe6b999dc680ccfdd5bf7eb0974218be2542daa
 *   Arc Testnet domain               26   ·   Ethereum Sepolia domain 0
 *   Iris attestation API (sandbox)   https://iris-api-sandbox.circle.com
 *
 * Prereqs (.env — NEVER commit):
 *   PRIVATE_KEY   Ethereum Sepolia EOA with Sepolia ETH (gas) + Sepolia USDC
 *                 (both from faucets: cloud.google faucet + faucet.circle.com)
 *   BRIDGE_AMOUNT optional, USDC to bridge (default "1")
 *   DEST_ADDRESS  optional, Arc recipient (default = source EOA address)
 *
 * Run:  cd contracts && node cctp-bridge-to-arc.mjs
 */
import 'dotenv/config';
import {
  createWalletClient, createPublicClient, http, encodeFunctionData, pad,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { sepolia } from 'viem/chains';

const PRIVATE_KEY = process.env.PRIVATE_KEY;
if (!PRIVATE_KEY) { console.error('Set PRIVATE_KEY (Ethereum Sepolia EOA) in .env'); process.exit(1); }
const account = privateKeyToAccount(PRIVATE_KEY.startsWith('0x') ? PRIVATE_KEY : `0x${PRIVATE_KEY}`);

const SEPOLIA_USDC = '0x1c7d4b196cb0c7b01d743fbc6116a902379c7238';
const SEPOLIA_TOKEN_MESSENGER = '0x8fe6b999dc680ccfdd5bf7eb0974218be2542daa';
const SEPOLIA_DOMAIN = 0;
const ARC_DOMAIN = 26;
const IRIS = 'https://iris-api-sandbox.circle.com';
const FORWARD_HOOK = '0x636374702d666f72776172640000000000000000000000000000000000000000';

const AMOUNT = BigInt(Math.round(parseFloat(process.env.BRIDGE_AMOUNT || '1') * 1_000_000));
const DEST = (process.env.DEST_ADDRESS || account.address);
const DEST_B32 = pad(DEST, { size: 32 });
const CALLER_B32 = pad('0x', { size: 32 });

const sepoliaWallet = createWalletClient({ chain: sepolia, transport: http(), account });
const sepoliaPublic = createPublicClient({ chain: sepolia, transport: http() });

const erc20Approve = [{
  type: 'function', name: 'approve', stateMutability: 'nonpayable',
  inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }],
  outputs: [{ name: '', type: 'bool' }],
}];
const burnWithHook = [{
  type: 'function', name: 'depositForBurnWithHook', stateMutability: 'nonpayable',
  inputs: [
    { name: 'amount', type: 'uint256' }, { name: 'destinationDomain', type: 'uint32' },
    { name: 'mintRecipient', type: 'bytes32' }, { name: 'burnToken', type: 'address' },
    { name: 'destinationCaller', type: 'bytes32' }, { name: 'maxFee', type: 'uint256' },
    { name: 'minFinalityThreshold', type: 'uint32' }, { name: 'hookData', type: 'bytes' },
  ],
  outputs: [],
}];

async function forwardingFees() {
  const r = await fetch(`${IRIS}/v2/burn/USDC/fees/${SEPOLIA_DOMAIN}/${ARC_DOMAIN}?forward=true`,
    { headers: { 'Content-Type': 'application/json' } });
  if (!r.ok) throw new Error(`fees ${r.status}: ${await r.text()}`);
  const fees = await r.json();
  const f = fees.find((x) => x.finalityThreshold === 1000);
  if (!f) throw new Error('fast-transfer forwarding fee not available');
  const forwardFee = BigInt(f.forwardFee.med);
  const protocolFee = (AMOUNT * BigInt(Math.round(f.minimumFee * 100))) / 1_000_000n;
  const maxFee = forwardFee + protocolFee;
  return { maxFee, total: AMOUNT + maxFee };
}

async function main() {
  console.log(`CCTP bridge → Arc | from ${account.address} | recipient ${DEST}`);
  const { maxFee, total } = await forwardingFees();
  console.log(`Bridging ${Number(AMOUNT) / 1e6} USDC (+${Number(maxFee) / 1e6} fee) = ${Number(total) / 1e6} burned`);

  console.log('1/3 approve…');
  const approveTx = await sepoliaWallet.sendTransaction({
    to: SEPOLIA_USDC,
    data: encodeFunctionData({ abi: erc20Approve, functionName: 'approve', args: [SEPOLIA_TOKEN_MESSENGER, total] }),
  });
  await sepoliaPublic.waitForTransactionReceipt({ hash: approveTx });
  console.log(`   approve tx ${approveTx}`);

  console.log('2/3 burn-with-hook (Forwarding Service mints on Arc)…');
  const burnTx = await sepoliaWallet.sendTransaction({
    to: SEPOLIA_TOKEN_MESSENGER,
    data: encodeFunctionData({
      abi: burnWithHook, functionName: 'depositForBurnWithHook',
      args: [total, ARC_DOMAIN, DEST_B32, SEPOLIA_USDC, CALLER_B32, maxFee, 1000, FORWARD_HOOK],
    }),
  });
  console.log(`   burn tx ${burnTx}`);

  console.log('3/3 waiting for Circle to mint on Arc…');
  while (true) {
    const r = await fetch(`${IRIS}/v2/messages/${SEPOLIA_DOMAIN}?transactionHash=${burnTx}`);
    if (r.ok) {
      const d = await r.json();
      const fwd = d?.messages?.[0]?.forwardTxHash;
      if (fwd) {
        console.log(`\n✅ Minted on Arc: ${fwd}`);
        console.log(`   https://testnet.arcscan.app/tx/${fwd}`);
        console.log(`   ${DEST} now holds USDC on Arc — ready to trade on Puls.`);
        return;
      }
    }
    await new Promise((s) => setTimeout(s, 5000));
  }
}

main().catch((e) => { console.error('bridge failed:', e?.message || e); process.exit(1); });
