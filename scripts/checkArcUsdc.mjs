import 'dotenv/config';
import { createPublicClient, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { arcTestnet } from 'viem/chains';

const pk = process.env.PRIVATE_KEY;
const acct = privateKeyToAccount(pk.startsWith('0x') ? pk : `0x${pk}`);
const pc = createPublicClient({ chain: arcTestnet, transport: http(process.env.ARC_RPC_URL || undefined) });

const native = await pc.getBalance({ address: acct.address });
const erc = await pc.readContract({
  address: '0x3600000000000000000000000000000000000000',
  abi: [{ name: 'balanceOf', type: 'function', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] }],
  functionName: 'balanceOf',
  args: [acct.address],
});

console.log('addr        ', acct.address);
console.log('native (raw)', native.toString());
console.log('erc20  (raw)', erc.toString());
console.log('same?       ', native.toString() === erc.toString());
console.log('native/1e6  ', Number(native) / 1e6);
console.log('native/1e18 ', Number(native) / 1e18);
console.log('erc20 /1e6  ', Number(erc) / 1e6);
