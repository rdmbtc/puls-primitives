import fs from 'fs';
import 'dotenv/config';
import { createWalletClient, createPublicClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { arcTestnet } from 'viem/chains';

// Deploys AgentBond to Arc Testnet (5042002).
//   1) forge build   (produces ./out/AgentBond.sol/AgentBond.json)
//   2) PRIVATE_KEY=0x... node deployAgentBond.mjs
// Then copy the printed address into the backend .env as AGENT_BOND_ADDRESS.

const USDC = process.env.USDC_ADDRESS || '0x3600000000000000000000000000000000000000';

async function deploy() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) {
    console.error('❌ Set PRIVATE_KEY in .env');
    process.exit(1);
  }

  const account = privateKeyToAccount(pk.startsWith('0x') ? pk : `0x${pk}`);
  const treasury = process.env.TREASURY_ADDRESS || account.address;
  const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http(process.env.ARC_RPC_URL || undefined) });
  const publicClient = createPublicClient({ chain: arcTestnet, transport: http(process.env.ARC_RPC_URL || undefined) });

  const artifact = JSON.parse(fs.readFileSync('./out/AgentBond.sol/AgentBond.json', 'utf-8'));
  const ABI = artifact.abi;
  const BYTECODE = artifact.bytecode.object;

  console.log(`Deploying AgentBond from: ${account.address}`);
  console.log(`Chain: Arc Testnet (5042002)`);
  console.log(`USDC: ${USDC}`);
  console.log(`Treasury (slash sink): ${treasury}`);

  const hash = await walletClient.deployContract({
    abi: ABI,
    bytecode: BYTECODE.startsWith('0x') ? BYTECODE : `0x${BYTECODE}`,
    args: [USDC, treasury],
    gas: 2_500_000n,
  });

  console.log(`Tx: ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`\n✅ AgentBond deployed: ${receipt.contractAddress}`);
  console.log(`Explorer: https://testnet.arcscan.app/address/${receipt.contractAddress}`);
  console.log(`\nAdd to backend .env:\n  AGENT_BOND_ADDRESS=${receipt.contractAddress}`);

  fs.writeFileSync(
    './deployed-agent-bond.json',
    JSON.stringify({ agentBondAddress: receipt.contractAddress, usdc: USDC, treasury }, null, 2)
  );
}

deploy().catch((e) => { console.error(e); process.exit(1); });
