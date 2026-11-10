// Elysian Pyre app settings.
// The deployed ElysianPyre contract on Elysium (owner 0xCc1a62a89e5900DbbE458E746eEaFcF538dF0115).
export const CONTRACT_ADDRESS = '0xcA87757556767E3605dc1c7Eb166C050eBFC9644';

export const CHAIN = {
  id: 99901,
  hexId: '0x1863d',
  name: 'Elysium',
  rpc: 'https://rpc.elyscan.live',
  explorer: 'https://elyscan.live',
  currency: { name: 'HYPE', symbol: 'HYPE', decimals: 18 },
};

// Tokens offered in the picker. Any other ERC-20 address can be pasted in.
export const KNOWN_TOKENS = [
  { address: '0xb47c4C8F73F009CC0C0d3f92B388d13E293F0B65', symbol: 'USDC' },
  { address: '0xbA876237B0F021A6c6D852d6c26E107997cC5E81', symbol: 'WHYPE' },
];
