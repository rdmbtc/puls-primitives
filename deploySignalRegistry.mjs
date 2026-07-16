import fs from 'fs';
import 'dotenv/config';
import { createWalletClient, createPublicClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { arcTestnet } from 'viem/chains';

// Deploys SignalRegistry to Arc Testnet (5042002).
//   1) forge build      (produces ./out/SignalRegistry.sol/SignalRegistry.json)
//   2) PRIVATE_KEY=0x... node deploySignalRegistry.mjs
// Then copy the printed address into the backend .env as SIGNAL_REGISTRY_ADDRESS.

async function deploy() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) {
    console.error('❌ Set PRIVATE_KEY in .env');
    process.exit(1);
  }

  const account = privateKeyToAccount(pk.startsWith('0x') ? pk : `0x${pk}`);
  const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http() });
  const publicClient = createPublicClient({ chain: arcTestnet, transport: http() });

  const artifact = JSON.parse(
    fs.readFileSync('./out/SignalRegistry.sol/SignalRegistry.json', 'utf-8')
  );
  const ABI = artifact.abi;
  const BYTECODE = artifact.bytecode.object;

  console.log(`Deploying SignalRegistry from: ${account.address}`);
  console.log('Chain: Arc Testnet (5042002)');

  const hash = await walletClient.deployContract({
    abi: ABI,
    bytecode: BYTECODE.startsWith('0x') ? BYTECODE : `0x${BYTECODE}`,
    args: [],
    gas: 1_500_000n,
  });

  console.log(`Tx: ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`\n✅ SignalRegistry deployed: ${receipt.contractAddress}`);
  console.log(`Explorer: https://testnet.arcscan.app/address/${receipt.contractAddress}`);
  console.log(`\nAdd to backend .env:\n  SIGNAL_REGISTRY_ADDRESS=${receipt.contractAddress}`);

  fs.writeFileSync(
    './deployed-signal-registry.json',
    JSON.stringify({ signalRegistryAddress: receipt.contractAddress }, null, 2)
  );
}

deploy().catch(console.error);
