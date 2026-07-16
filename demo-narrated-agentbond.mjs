/**
 * Puls - narrated AgentBond demo (for the submission video, no voice-over).
 *
 * Tells the story in plain English, step by step, so a judge watching the
 * screen understands exactly what is happening: an AI agent stakes USDC on its
 * calls. A WRONG call is slashed to the treasury; a RIGHT call is returned.
 * Every step is a REAL transaction on Arc with a live explorer link.
 *
 * Run locally:   cd contracts && node demo-narrated-agentbond.mjs
 * Prereqs:       deployed-agent-bond.json + PRIVATE_KEY (treasury) in contracts/.env
 * Pace control:  DEMO_PAUSE_MS=2200 node demo-narrated-agentbond.mjs   (slower for camera)
 */
import fs from 'fs';
import 'dotenv/config';
import { createWalletClient, createPublicClient, http, keccak256, toHex, formatUnits } from 'viem';
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts';
import { arcTestnet } from 'viem/chains';

const PAUSE = parseInt(process.env.DEMO_PAUSE_MS || '1700', 10);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hr = (c = '=') => console.log(c.repeat(68));
function banner(t) { console.log(); hr(); console.log('  ' + t); hr(); }
async function say(s) { console.log(s); await sleep(PAUSE); }

const USDC = '0x3600000000000000000000000000000000000000';
const BOND = JSON.parse(fs.readFileSync('./deployed-agent-bond.json', 'utf-8')).agentBondAddress;
const rpc = http(process.env.ARC_RPC_URL || undefined);

const ERC20 = [
  { name: 'transfer', type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { name: 'approve', type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { name: 'balanceOf', type: 'function', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
];
const BOND_ABI = [
  { name: 'postBond', type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'signalId', type: 'bytes32' }, { name: 'amount', type: 'uint256' }], outputs: [] },
  { name: 'settle', type: 'function', stateMutability: 'nonpayable', inputs: [{ name: 'signalId', type: 'bytes32' }, { name: 'correct', type: 'bool' }], outputs: [] },
];

const pc = createPublicClient({ chain: arcTestnet, transport: rpc });
const treAcct = privateKeyToAccount((process.env.PRIVATE_KEY.startsWith('0x') ? '' : '0x') + process.env.PRIVATE_KEY);
const tre = createWalletClient({ account: treAcct, chain: arcTestnet, transport: rpc });
const agentPk = generatePrivateKey();
const agAcct = privateKeyToAccount(agentPk);
const ag = createWalletClient({ account: agAcct, chain: arcTestnet, transport: rpc });

const wait = (h) => pc.waitForTransactionReceipt({ hash: h });
const link = (h) => `   tx -> https://testnet.arcscan.app/tx/${h}`;
const bal = async (a) => Number(formatUnits(await pc.readContract({ address: USDC, abi: ERC20, functionName: 'balanceOf', args: [a] }), 6));
const WRONG = keccak256(toHex(`puls:agentbond:demo:wrong:${Date.now()}`));
const RIGHT = keccak256(toHex(`puls:agentbond:demo:right:${Date.now()}`));

async function main() {
  banner('PULS  -  AGENTBOND: REPUTATION AS CAPITAL AT RISK');
  await say('On Puls, AI agents do not just talk. They put money on every call.');
  await say('They stake a USDC bond:  WRONG call -> SLASHED.  RIGHT call -> RETURNED.');
  await say('Watch the full lifecycle happen live on Arc, one real tx at a time.');
  await say('');
  await say(`AgentBond contract : ${BOND}`);
  await say(`Treasury (slash sink): ${treAcct.address}`);
  await say(`Fresh demo agent     : ${agAcct.address}`);

  banner('STEP 1 / 5  -  FUND THE AGENT WITH 0.7 USDC');
  await say('On Arc, USDC is also the gas token - the agent needs no ETH, ever.');
  let h = await tre.writeContract({ address: USDC, abi: ERC20, functionName: 'transfer', args: [agAcct.address, 700000n] });
  await say(link(h)); await wait(h); await say('   [confirmed]');

  banner('STEP 2 / 5  -  AGENT STAKES 0.3 USDC ON A CALL (this one will be WRONG)');
  await say('The agent locks 0.3 USDC behind its prediction. This is its skin in the game.');
  h = await ag.writeContract({ address: USDC, abi: ERC20, functionName: 'approve', args: [BOND, 300000n] }); await wait(h);
  h = await ag.writeContract({ address: BOND, abi: BOND_ABI, functionName: 'postBond', args: [WRONG, 300000n] });
  await say('   bond posted (0.3 USDC locked)'); await say(link(h)); await wait(h); await say('   [confirmed]');

  banner('STEP 3 / 5  -  THE CALL WAS WRONG  ->  BOND SLASHED');
  await say('The real-world outcome proves the agent wrong. Its bond is slashed to the treasury.');
  h = await tre.writeContract({ address: BOND, abi: BOND_ABI, functionName: 'settle', args: [WRONG, false] });
  await say('   SLASHED: 0.3 USDC leaves the agent -> treasury'); await say(link(h)); await wait(h);
  await say('   >> The agent just lost real money for a bad call. Reputation has teeth.');

  banner('STEP 4 / 5  -  AGENT STAKES 0.2 USDC ON A CALL (this one will be RIGHT)');
  await say('New call, new stake. The agent locks 0.2 USDC behind it.');
  h = await ag.writeContract({ address: USDC, abi: ERC20, functionName: 'approve', args: [BOND, 200000n] }); await wait(h);
  h = await ag.writeContract({ address: BOND, abi: BOND_ABI, functionName: 'postBond', args: [RIGHT, 200000n] });
  await say('   bond posted (0.2 USDC locked)'); await say(link(h)); await wait(h); await say('   [confirmed]');

  banner('STEP 5 / 5  -  THE CALL WAS RIGHT  ->  BOND RETURNED');
  await say('The agent was right. Its bond is returned in full - good calls are honoured.');
  h = await tre.writeContract({ address: BOND, abi: BOND_ABI, functionName: 'settle', args: [RIGHT, true] });
  await say('   RETURNED: 0.2 USDC goes back to the agent'); await say(link(h)); await wait(h);

  const left = await bal(agAcct.address);
  banner('DONE  -  REPUTATION = CAPITAL AT RISK, SETTLED ON ARC');
  await say(`Agent balance now: ${left.toFixed(4)} USDC`);
  await say('  (started 0.7, lost 0.3 to the slash, kept the 0.2 return, the rest was gas)');
  await say('Wrong calls cost the agent. Right calls are honoured. Every step verifiable on Arcscan.');
  fs.writeFileSync('./agent-bond-demo.json', JSON.stringify({ bond: BOND, agent: agAcct.address, sigWrong: WRONG, sigRight: RIGHT }, null, 2));
}

main().catch((e) => { console.error('demo failed:', e.shortMessage || e.message); process.exit(1); });
