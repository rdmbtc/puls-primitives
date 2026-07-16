import { isAddress, getAddress } from 'viem';
const addrs = [
  '0x846e5c49ec9ff98f5f6344073725ae55719e488a',
  '0x230234c41da01d01f0e0e3d15a6852c64b7edd2d',
  '0x2514ed8d8a46a666d9db86d7b978c73adee00d2d',
  '0x47adeb6238f0045e78c7ec01ea459507b4242fd7',
  '0x7b74a5884eb5b95240a0975c4b1eaf63d850374c',
  '0xf17f57e43fd61a66f59f46e180f55e8965fb146a',
  '0x708361ec460e0a412e6df926ae2cdd2c38fc8741'
];
for (const a of addrs) {
  console.log(a, 'isAddress:', isAddress(a), 'getAddress:', getAddress(a));
}
