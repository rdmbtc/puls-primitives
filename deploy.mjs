/**
 * Deploy PulsMarket to Arc Testnet
 *
 * 1. Go to https://remix.ethereum.org
 * 2. Create a new file, paste the contents of src/PulsMarket.sol
 * 3. Compile (Solidity 0.8.24, optimizer ON, 200 runs)
 * 4. In the Compilation Details, copy the BYTECODE → object field (hex string)
 * 5. Paste it below as BYTECODE
 * 6. Set PRIVATE_KEY in .env
 * 7. Run: node deploy.mjs
 */

import fs from 'fs';
import 'dotenv/config';
import { createWalletClient, createPublicClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { arcTestnet } from 'viem/chains';

// Read artifact from Forge output
const artifact = JSON.parse(fs.readFileSync('./out/LMSRMarket.sol/LMSRMarket.json', 'utf-8'));
const ABI = artifact.abi;
const BYTECODE = artifact.bytecode.object;

const USDC = '0x3600000000000000000000000000000000000000';

async function deploy() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) { console.error('❌ Set PRIVATE_KEY in .env'); process.exit(1); }

  const account = privateKeyToAccount(pk);
  const walletClient = createWalletClient({ account, chain: arcTestnet, transport: http() });
  const publicClient = createPublicClient({ chain: arcTestnet, transport: http() });

  const question = process.env.MARKET_QUESTION || 'Will Bitcoin close above $100k this quarter?';
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 30 * 24 * 3600);
  const bParam = 10000000n; // b = 10 USDC. Max loss is ~ 6.93 USDC

  console.log(`Deploying from: ${account.address}`);
  console.log(`Question: ${question}`);
  console.log(`Chain: Arc Testnet (5042002)`);

  const hash = await walletClient.deployContract({
    abi: ABI,
    bytecode: BYTECODE.startsWith('0x') ? BYTECODE : `0x${BYTECODE}`,
    args: [USDC, question, deadline, bParam],
  });

  console.log(`Tx: ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`\n✅ Contract deployed: ${receipt.contractAddress}`);

  console.log('Approving USDC for funding...');
  const { request: approveReq } = await publicClient.simulateContract({
    account,
    address: USDC,
    abi: [{ type: 'function', name: 'approve', inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ name: '', type: 'bool' }], stateMutability: 'nonpayable' }],
    functionName: 'approve',
    args: [receipt.contractAddress, bParam],
  });
  const approveHash = await walletClient.writeContract(approveReq);
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  console.log('Funding LMSR Market...');
  const { request: fundReq } = await publicClient.simulateContract({
    account,
    address: receipt.contractAddress,
    abi: ABI,
    functionName: 'fund',
  });
  const fundHash = await walletClient.writeContract(fundReq);
  await publicClient.waitForTransactionReceipt({ hash: fundHash });

  console.log(`✅ Market Funded!`);
  console.log(`Explorer: https://testnet.arcscan.app/address/${receipt.contractAddress}`);
  console.log(`\nAdd to backend/.env:\nMARKET_CONTRACT=${receipt.contractAddress}`);
}

deploy().catch(console.error);
