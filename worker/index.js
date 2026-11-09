// Elysian Pyre site Worker.
// Serves the static site from ./web and one small API:
//   GET  /api/config  -> { contract, admin, chainId }  the published contract address (or null)
//   POST /api/config  <- { address, signature }        publishes a contract address
// A publish is accepted only when:
//   1. the signature over PUBLISH_MESSAGE(address) recovers to env.ADMIN (the site admin wallet), and
//   2. the code at `address` on Elysium is exactly the ElysianPyre runtime bytecode (PYRE_CODE_HASH).
import { createPublicClient, http, verifyMessage, isAddress, getAddress, keccak256 } from 'viem';
import { PYRE_CODE_HASH } from './code-hash.js';

const CHAIN_ID = 99901;
const RPC = 'https://rpc.elyscan.live';
export const publishMessage = (address) =>
  `Elysian Pyre\nPublish contract ${getAddress(address)} on Elysium (chain ${CHAIN_ID}) as the site's contract.`;

const json = (data, status = 200) => new Response(JSON.stringify(data), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
});

async function readConfig(env) {
  const contract = await env.CONFIG.get('contract');
  return { contract: contract || null, admin: env.ADMIN ? getAddress(env.ADMIN) : null, chainId: CHAIN_ID };
}

async function publish(request, env) {
  if (!env.ADMIN || !isAddress(env.ADMIN)) return json({ error: 'The site has no admin wallet configured.' }, 500);
  let body;
  try { body = await request.json(); } catch { return json({ error: 'Send JSON: { address, signature }.' }, 400); }
  const { address, signature } = body || {};
  if (!isAddress(address || '')) return json({ error: 'That is not a contract address.' }, 400);
  if (typeof signature !== 'string' || !/^0x[0-9a-fA-F]+$/.test(signature)) return json({ error: 'Missing signature.' }, 400);

  const ok = await verifyMessage({ address: getAddress(env.ADMIN), message: publishMessage(address), signature }).catch(() => false);
  if (!ok) return json({ error: 'This signature does not come from the site admin wallet.' }, 403);

  const rpc = env.RPC_URL || RPC;
  const client = createPublicClient({ transport: http(rpc) });
  const code = await client.getCode({ address: getAddress(address) }).catch(() => null);
  if (!code || code === '0x') return json({ error: 'No contract at this address on Elysium yet. Wait for the deployment to confirm.' }, 409);
  if (keccak256(code) !== (env.CODE_HASH || PYRE_CODE_HASH)) return json({ error: 'The code at this address is not the Elysian Pyre contract.' }, 409);

  await env.CONFIG.put('contract', getAddress(address));
  await env.CONFIG.put('published_at', new Date().toISOString());
  return json(await readConfig(env));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/api/config') {
      if (request.method === 'GET') return json(await readConfig(env));
      if (request.method === 'POST') return publish(request, env);
      return json({ error: 'Method not allowed.' }, 405);
    }
    return env.ASSETS.fetch(request);
  },
};
