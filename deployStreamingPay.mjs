import fs from 'fs';
import 'dotenv/config';
import { createWalletClient, createPublicClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { arcTestnet } from 'viem/chains';

// Deploys StreamingPay to Arc Testnet (5042002).
//   1) forge build   (produces ./out/StreamingPay.sol/StreamingPay.json)
//   2) PRIVATE_KEY=0x... node deployStreamingPay.mjs
// Then copy the printed address into the backend .env as STREAMING_PAY_ADDRESS.

const USDC = process.env.USDC_ADDRESS || '0x3600000000000000000000000000000000000000';

async function deploy() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) {
    console.error('❌ Set PRIVATE_KEY in .env');
    process.exit(1);
  }

  const account = privateKeyToAccount(pk.startsWith('0x') ? pk : `0x${pk}`);
  const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http(process.env.ARC_RPC_URL || undefined) });
  const publicClient = createPublicClient({ chain: arcTestnet, transport: http(process.env.ARC_RPC_URL || undefined) });

  const artifact = JSON.parse(fs.readFileSync('./out/StreamingPay.sol/StreamingPay.json', 'utf-8'));
  const ABI = artifact.abi;
  const BYTECODE = artifact.bytecode.object;

  console.log(`Deploying StreamingPay from: ${account.address}`);
  console.log(`Chain: Arc Testnet (5042002)`);
  console.log(`USDC: ${USDC}`);

  const hash = await walletClient.deployContract({
    abi: ABI,
    bytecode: BYTECODE.startsWith('0x') ? BYTECODE : `0x${BYTECODE}`,
    args: [USDC],
    gas: 1_800_000n,
  });

  console.log(`Tx: ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`\n✅ StreamingPay deployed: ${receipt.contractAddress}`);
  console.log(`Explorer: https://testnet.arcscan.app/address/${receipt.contractAddress}`);
  console.log(`\nAdd to backend .env:\n  STREAMING_PAY_ADDRESS=${receipt.contractAddress}`);

  fs.writeFileSync(
    './deployed-streaming-pay.json',
    JSON.stringify({ streamingPayAddress: receipt.contractAddress, usdc: USDC }, null, 2)
  );
}

deploy().catch((e) => { console.error(e); process.exit(1); });
