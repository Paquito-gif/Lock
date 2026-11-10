// Wallet discovery and choice (EIP-6963). Several wallets can be installed at once, and some
// (Phantom) take over window.ethereum while not supporting custom networks such as Elysium.
// This lists every wallet the browser announces, lets the visitor pick one, remembers the pick,
// and explains plainly when a wallet cannot use Elysium.
const found = new Map();
addEventListener('eip6963:announceProvider', (e) => { if (e.detail?.info?.uuid) found.set(e.detail.info.uuid, e.detail); });
dispatchEvent(new Event('eip6963:requestProvider'));

// wallets known to support only their own fixed list of EVM networks
const FIXED_NETWORKS = [/phantom/i];
// Phantom can also pose as MetaMask ("Default App Wallet" setting): check the provider's own flags too
const isPhantomProvider = (p) => !!(p && (p.isPhantom || p._phantom || p.phantom));
export const cannotAddNetworks = (info, provider) => isPhantomProvider(provider) || FIXED_NETWORKS.some((re) => re.test(info?.name || '') || re.test(info?.rdns || ''));
const blocked = (w) => cannotAddNetworks(w.info, w.provider);

export const current = { provider: null, info: null };
const KEY = 'pyre-wallet';

function list() {
  const items = [...found.values()];
  if (!items.length && window.ethereum) {
    const p = window.ethereum;
    items.push({ provider: p, info: { uuid: 'injected', rdns: 'injected', name: p.isPhantom ? 'Phantom' : p.isRabby ? 'Rabby' : p.isMetaMask ? 'MetaMask' : 'Browser wallet', icon: '' } });
  }
  return items;
}

export function unsupportedMessage(name = 'This wallet') {
  return `${name} does not support the Elysium network. Use a wallet that lets you add a network, such as MetaMask, Rabby or OKX Wallet.`;
}

function use(detail) {
  current.provider = detail.provider; current.info = detail.info;
  try { localStorage.setItem(KEY, detail.info.rdns); } catch { /* storage off */ }
  return detail;
}

// the wallet picked last time, if it is still installed (used to reconnect silently on load)
export async function remembered() {
  await new Promise((r) => setTimeout(r, 250)); // let wallets announce themselves
  let rdns = null; try { rdns = localStorage.getItem(KEY); } catch { /* storage off */ }
  const items = list();
  const hit = items.find((w) => w.info.rdns === rdns && !blocked(w)) || (items.length === 1 && !blocked(items[0]) ? items[0] : null);
  return hit ? use(hit) : null;
}

// ask which wallet to use; resolves to the chosen wallet, or null (none usable, or cancelled)
export async function choose() {
  await new Promise((r) => setTimeout(r, 150));
  const items = list();
  const usable = items.filter((w) => !blocked(w));
  if (!items.length) return null;
  if (items.length === 1) return usable.length ? use(usable[0]) : null;
  return new Promise((resolve) => {
    const dlg = document.createElement('dialog');
    dlg.className = 'wallet-pick';
    dlg.setAttribute('aria-labelledby', 'wallet-pick-h');
    dlg.innerHTML = `<h2 id="wallet-pick-h">Choose a wallet</h2><p class="hint">Elysium is a custom network, so the wallet must let you add a network.</p><div class="wallet-pick__list"></div><button type="button" class="btn btn--secondary btn--block" data-cancel>Cancel</button>`;
    const box = dlg.querySelector('.wallet-pick__list');
    for (const w of items) {
      const ok = !blocked(w);
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'wallet-pick__item'; b.disabled = !ok;
      const icon = /^data:image\//.test(w.info.icon || '') ? `<img src="${w.info.icon}" alt="" width="28" height="28">` : '<span class="wallet-pick__blank" aria-hidden="true"></span>';
      b.innerHTML = `${icon}<span><b></b><small></small></span>`;
      b.querySelector('b').textContent = w.info.name;
      b.querySelector('small').textContent = ok ? 'Supports Elysium' : isPhantomProvider(w.provider) && !/phantom/i.test(w.info.name) ? 'This is Phantom posing as it' : 'Does not support Elysium';
      b.addEventListener('click', () => { dlg.close(); dlg.remove(); resolve(use(w)); });
      box.append(b);
    }
    const cancel = () => { if (dlg.open) dlg.close(); dlg.remove(); resolve(null); };
    dlg.querySelector('[data-cancel]').addEventListener('click', cancel);
    dlg.addEventListener('cancel', (e) => { e.preventDefault(); cancel(); });
    document.body.append(dlg); dlg.showModal();
  });
}

// why a connect attempt found nothing usable
export function noWalletReason() {
  const items = list();
  if (!items.length) return 'No browser wallet found. Install one that supports custom networks, such as MetaMask or Rabby, then reload this page.';
  if (items.every(blocked)) return isPhantomProvider(items[0].provider) && !/phantom/i.test(items[0].info.name)
    ? 'Phantom is answering in place of your other wallet. In Phantom, open Settings, Preferences, and turn off "Default App Wallet", then reload this page.'
    : unsupportedMessage(items[0].info.name);
  return null; // the visitor cancelled
}

// switch the current wallet to Elysium, adding the network when the wallet does not know it yet
export async function ensureChain(CHAIN) {
  const p = current.provider; const name = current.info?.name || 'This wallet';
  if (cannotAddNetworks(current.info, p)) throw new Error(unsupportedMessage('Phantom'));
  const id = parseInt(await p.request({ method: 'eth_chainId' }), 16);
  if (id === CHAIN.id) return;
  try {
    await p.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN.hexId }] });
  } catch (e) {
    if (e?.code === 4001) throw e;
    try {
      await p.request({ method: 'wallet_addEthereumChain', params: [{ chainId: CHAIN.hexId, chainName: CHAIN.name, nativeCurrency: CHAIN.currency, rpcUrls: [CHAIN.rpc], blockExplorerUrls: [CHAIN.explorer] }] });
    } catch (e2) {
      if (e2?.code === 4001) throw e2;
      throw new Error(unsupportedMessage(name));
    }
  }
}
