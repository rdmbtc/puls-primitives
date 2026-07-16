import fs from 'fs';
import 'dotenv/config';
import { createWalletClient, createPublicClient, http, keccak256, toHex } from 'viem';
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts';
import { arcTestnet } from 'viem/chains';

// Demonstrates the AgentBond lifecycle on Arc with REAL on-chain txs:
//   • a fresh "agent" address stakes USDC behind two calls,
//   • the WRONG call is slashed to the treasury (the agent loses it),
//   • the CORRECT call is returned to the agent.
// Amounts are tiny (testnet). Proves the mechanic end-to-end, verifiable on arcscan.

const USDC = '0x3600000000000000000000000000000000000000';
const BOND = JSON.parse(fs.readFileSync('./deployed-agent-bond.json', 'utf-8')).agentBondAddress;
const rpc = http(process.env.ARC_RPC_URL || undefined);

const ERC20_ABI = [
  { name: 'transfer', type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { name: 'approve', type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { name: 'balanceOf', type: 'function', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
];
const BOND_ABI = [
  { name: 'postBond', type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'signalId', type: 'bytes32' }, { name: 'amount', type: 'uint256' }], outputs: [] },
  { name: 'settle', type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'signalId', type: 'bytes32' }, { name: 'correct', type: 'bool' }], outputs: [] },
];

const pc = createPublicClient({ chain: arcTestnet, transport: rpc });
const treasuryAcct = privateKeyToAccount((process.env.PRIVATE_KEY.startsWith('0x') ? '' : '0x') + process.env.PRIVATE_KEY);
const treasury = createWalletClient({ account: treasuryAcct, chain: arcTestnet, transport: rpc });

const agentPk = generatePrivateKey();
const agentAcct = privateKeyToAccount(agentPk);
const agent = createWalletClient({ account: agentAcct, chain: arcTestnet, transport: rpc });

const wait = (hash) => pc.waitForTransactionReceipt({ hash });
const log = (label, hash) => console.log(`${label}: ${hash}  → https://testnet.arcscan.app/tx/${hash}`);

const SIG_WRONG = keccak256(toHex(`puls:agentbond:demo:wrong:${Date.now()}`));
const SIG_RIGHT = keccak256(toHex(`puls:agentbond:demo:right:${Date.now()}`));

async function main() {
  console.log(`AgentBond: ${BOND}`);
  console.log(`Treasury (owner/sink): ${treasuryAcct.address}`);
  console.log(`Demo agent:            ${agentAcct.address}\n`);

  // 1) Fund the demo agent with 0.7 USDC (gas + stake; native == ERC20 pool on Arc).
  let h = await treasury.writeContract({ address: USDC, abi: ERC20_ABI, functionName: 'transfer', args: [agentAcct.address, 700000n] });
  log('fund agent 0.7 USDC', h); await wait(h);

  // 2) Agent approves + posts a 0.3 USDC bond behind a (to-be-WRONG) call.
  h = await agent.writeContract({ address: USDC, abi: ERC20_ABI, functionName: 'approve', args: [BOND, 300000n] });
  await wait(h);
  h = await agent.writeContract({ address: BOND, abi: BOND_ABI, functionName: 'postBond', args: [SIG_WRONG, 300000n] });
  log('agent posts 0.3 bond (wrong call)', h); await wait(h);

  // 3) Owner settles it WRONG → slashed to treasury (agent loses the 0.3).
  h = await treasury.writeContract({ address: BOND, abi: BOND_ABI, functionName: 'settle', args: [SIG_WRONG, false] });
  log('SLASH wrong call → treasury', h); await wait(h);

  // 4) Agent posts a 0.2 USDC bond behind a (to-be-CORRECT) call, then it's returned.
  h = await agent.writeContract({ address: USDC, abi: ERC20_ABI, functionName: 'approve', args: [BOND, 200000n] });
  await wait(h);
  h = await agent.writeContract({ address: BOND, abi: BOND_ABI, functionName: 'postBond', args: [SIG_RIGHT, 200000n] });
  log('agent posts 0.2 bond (correct call)', h); await wait(h);
  h = await treasury.writeContract({ address: BOND, abi: BOND_ABI, functionName: 'settle', args: [SIG_RIGHT, true] });
  log('RETURN correct call → agent', h); await wait(h);

  const aBal = await pc.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [agentAcct.address] });
  console.log(`\nDemo agent USDC left: ${Number(aBal) / 1e6} (started 0.7, lost 0.3 slash, 0.2 returned, rest gas)`);
  console.log('\nSignalIds:');
  console.log(`  slashed: ${SIG_WRONG}`);
  console.log(`  returned: ${SIG_RIGHT}`);
  fs.writeFileSync('./agent-bond-demo.json', JSON.stringify({ bond: BOND, agent: agentAcct.address, sigWrong: SIG_WRONG, sigRight: SIG_RIGHT }, null, 2));
}

main().catch((e) => { console.error(e.shortMessage || e.message); process.exit(1); });
