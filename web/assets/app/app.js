// Elysian Pyre app: connects a wallet, switches it to Elysium, and calls the ElysianPyre contract.
import {
  createPublicClient, createWalletClient, custom, http, parseUnits, formatUnits,
  isAddress, getAddress, defineChain, BaseError, ContractFunctionRevertedError,
} from './viem.js';
import { pyreAbi } from './abi.js';
import { CONTRACT_ADDRESS, CHAIN, KNOWN_TOKENS } from './config.js';

const erc20Abi = [
  { type: 'function', name: 'symbol', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'allowance', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] },
];

const elysium = defineChain({
  id: CHAIN.id, name: CHAIN.name, nativeCurrency: CHAIN.currency,
  rpcUrls: { default: { http: [CHAIN.rpc] } },
  blockExplorers: { default: { name: 'Elyscan', url: CHAIN.explorer } },
});
const pub = createPublicClient({ chain: elysium, transport: http(CHAIN.rpc) });
const PERMANENT = 2n ** 40n - 1n;
const deployed = isAddress(CONTRACT_ADDRESS);
const PYRE = deployed ? getAddress(CONTRACT_ADDRESS) : null;

const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const el = {
  notice: $('[data-notice]'), status: $('[data-status]'), statusText: $('[data-status-text]'),
  connect: $('[data-connect]'), form: $('#form'), modeLine: $('[data-mode-line]'),
  tokenSelect: $('[data-token-select]'), tokenCustom: $('[data-token-custom]'), tokenInfo: $('[data-token-info]'),
  amount: $('[data-amount]'), balance: $('[data-balance]'), max: $('[data-max]'),
  unlock: $('[data-unlock]'), otherOwner: $('[data-other-owner]'), owner: $('[data-owner]'),
  fee: $('[data-fee]'), sumDate: $('[data-sum-date]'), confirm: $('[data-confirm]'), confirmText: $('[data-confirm-text]'),
  submit: $('[data-submit]'), sumAmt: $('[data-sum-amt]'), ownerHint: $('[data-owner-hint]'), tz: $('[data-tz]'), msg: $('[data-msg]'), list: $('[data-list]'), refresh: $('[data-refresh]'),
  contractLine: $('[data-contract-line]'), tpl: $('#row-tpl'),
};

const state = { account: null, chainOk: false, mode: 'lock', fee: null, token: null, busy: false };
const tokenCache = new Map();

// ---------------------------------------------------------------- helpers

const short = a => `${a.slice(0, 6)}…${a.slice(-4)}`;
const txLink = h => `<a href="${CHAIN.explorer}/tx/${h}" target="_blank" rel="noopener">${short(h)}</a>`;
const fmt = (v, d) => {
  const s = formatUnits(v, d);
  const [i, f = ''] = s.split('.');
  const int = BigInt(i).toLocaleString('en-US');
  const frac = f.slice(0, 4).replace(/0+$/, '');
  return frac ? `${int}.${frac}` : int;
};
const fmtDate = ts => new Date(Number(ts) * 1000).toLocaleString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
const daysLeft = ts => Math.ceil((Number(ts) * 1000 - Date.now()) / 86400000);

const esc = t => String(t).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
function say(text, kind = '') {
  el.msg.className = 'msg' + (kind ? ` is-${kind}` : '');
  el.msg.innerHTML = text;
}
function sayErr(err) { say(esc(reason(err)), 'err'); }

function reason(err) {
  if (err instanceof BaseError) {
    const rev = err.walk(e => e instanceof ContractFunctionRevertedError);
    if (rev?.data?.errorName) {
      const names = {
        WrongFee: 'The fee changed. Refresh the page and try again.',
        ZeroAmount: 'Enter an amount above zero.',
        ZeroAddress: 'That address is not valid here.',
        InvalidUnlockTime: 'Pick a date in the future, at most 100 years away.',
        UnsupportedToken: 'This token is not supported (it takes a fee on transfer, or its burn does not match).',
        NotLockOwner: 'Only the lock’s owner can do this.',
        StillLocked: 'This lock has not reached its unlock date yet.',
        AlreadyWithdrawn: 'This lock was already withdrawn.',
        LockNotFound: 'This lock does not exist.',
      };
      return names[rev.data.errorName] || `The contract refused: ${rev.data.errorName}.`;
    }
    if (err.walk(e => e.code === 4001 || /rejected|denied/i.test(e.shortMessage || ''))) return 'You rejected the request in your wallet.';
    return err.shortMessage || err.message;
  }
  return err?.message || String(err);
}

function wallet() {
  if (!window.ethereum) return null;
  return createWalletClient({ chain: elysium, transport: custom(window.ethereum), account: state.account });
}

// ---------------------------------------------------------------- wallet and chain

async function ensureChain() {
  const id = await window.ethereum.request({ method: 'eth_chainId' });
  if (parseInt(id, 16) === CHAIN.id) return true;
  try {
    await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN.hexId }] });
  } catch (e) {
    if (e.code !== 4902) throw e;
    await window.ethereum.request({
      method: 'wallet_addEthereumChain',
      params: [{ chainId: CHAIN.hexId, chainName: CHAIN.name, nativeCurrency: CHAIN.currency, rpcUrls: [CHAIN.rpc], blockExplorerUrls: [CHAIN.explorer] }],
    });
  }
  return true;
}

async function connect() {
  if (!window.ethereum) { say('No browser wallet found. Install one such as MetaMask or Rabby, then reload this page.', 'err'); return; }
  try {
    const [acc] = await window.ethereum.request({ method: 'eth_requestAccounts' });
    state.account = getAddress(acc);
    await ensureChain();
    await syncChain();
  } catch (e) { sayErr(e); }
}

async function syncChain() {
  if (!window.ethereum || !state.account) { renderStatus(); return; }
  const id = parseInt(await window.ethereum.request({ method: 'eth_chainId' }), 16);
  state.chainOk = id === CHAIN.id;
  renderStatus();
  await Promise.all([loadToken(), loadLocks()]);
}

function renderStatus() {
  el.status.classList.toggle('is-on', !!state.account && state.chainOk);
  el.status.classList.toggle('is-warn', !!state.account && !state.chainOk);
  if (!state.account) el.statusText.textContent = 'No wallet connected';
  else if (!state.chainOk) el.statusText.textContent = `${short(state.account)} · switch to Elysium`;
  else el.statusText.textContent = `${short(state.account)} · Elysium`;
  el.connect.textContent = state.account ? (state.chainOk ? short(state.account) : 'Switch to Elysium') : 'Connect wallet';
  el.connect.classList.toggle('btn--primary', !(state.account && state.chainOk));
  el.connect.classList.toggle('btn--secondary', !!(state.account && state.chainOk));
  renderSubmit();
}

// ---------------------------------------------------------------- token

async function tokenMeta(address) {
  if (tokenCache.has(address)) return tokenCache.get(address);
  const [symbol, decimals] = await Promise.all([
    pub.readContract({ address, abi: erc20Abi, functionName: 'symbol' }).catch(() => '???'),
    pub.readContract({ address, abi: erc20Abi, functionName: 'decimals' }),
  ]);
  const meta = { address, symbol, decimals: Number(decimals) };
  tokenCache.set(address, meta);
  return meta;
}

function currentTokenAddress() {
  const v = el.tokenSelect.value === 'custom' ? el.tokenCustom.value.trim() : el.tokenSelect.value;
  return isAddress(v) ? getAddress(v) : null;
}

let tokenSeq = 0;
async function loadToken() {
  const seq = ++tokenSeq;
  const address = currentTokenAddress();
  state.token = null;
  el.balance.textContent = '–';
  if (!address) {
    el.tokenInfo.innerHTML = el.tokenSelect.value === 'custom' && el.tokenCustom.value.trim()
      ? 'That is not a valid address.' : 'Pick a token or paste any ERC-20 address on Elysium.';
    renderSubmit();
    return;
  }
  el.tokenInfo.textContent = 'Reading the token…';
  try {
    const meta = await tokenMeta(address);
    const balance = state.account ? await pub.readContract({ address, abi: erc20Abi, functionName: 'balanceOf', args: [state.account] }) : null;
    if (seq !== tokenSeq) return;
    state.token = { ...meta, balance };
    el.balance.textContent = balance === null ? '–' : `${fmt(balance, meta.decimals)} ${meta.symbol}`;
    el.tokenInfo.innerHTML = `<b>${meta.symbol}</b>, ${meta.decimals} decimals · <a class="link" href="${CHAIN.explorer}/token/${address}" target="_blank" rel="noopener">${short(address)}</a>`;
  } catch {
    if (seq !== tokenSeq) return;
    el.tokenInfo.textContent = 'Could not read a token at this address. Check the address, or try again if Elysium is not reachable.';
  }
  renderSubmit();
}

// ---------------------------------------------------------------- form

const MODE_LINES = {
  lock: 'Tokens stay in the contract until the date you set. Then you withdraw them.',
  forever: 'Tokens stay in the contract for good. Nobody can ever withdraw them, you included.',
  burn: 'Tokens are destroyed. The token’s own burn lowers its supply; otherwise they go to the dead address.',
};
const CONFIRM_TEXT = {
  forever: 'I understand these tokens can never be withdrawn.',
  burn: 'I understand these tokens are destroyed for good.',
};

function setMode(mode) {
  state.mode = mode;
  el.form.dataset.mode = mode;
  $$('.seg [data-mode]').forEach(t => t.setAttribute('aria-pressed', t.dataset.mode === mode));
  el.modeLine.textContent = MODE_LINES[mode];
  if (CONFIRM_TEXT[mode]) el.confirmText.textContent = CONFIRM_TEXT[mode];
  el.confirm.checked = false;
  say('');
  renderSubmit();
}

function parsedAmount() {
  if (!state.token) return null;
  const raw = el.amount.value.trim().replace(/,/g, '');
  if (!/^\d*\.?\d*$/.test(raw) || raw === '' || raw === '.') return null;
  try { const v = parseUnits(raw, state.token.decimals); return v > 0n ? v : null; } catch { return null; }
}

function unlockTs() {
  if (!el.unlock.value) return null;
  const t = Math.floor(new Date(el.unlock.value).getTime() / 1000);
  return Number.isFinite(t) ? BigInt(t) : null;
}

function ownerAddress() {
  if (!el.otherOwner.checked) return state.account;
  const v = el.owner.value.trim();
  return isAddress(v) ? getAddress(v) : null;
}

function problems() {
  if (!deployed) return 'The contract is not deployed yet';
  if (!state.account) return null; // the button connects
  if (!state.chainOk) return null; // the button switches
  if (!state.token) return 'Pick a token';
  const amt = parsedAmount();
  if (!amt) return 'Enter an amount';
  if (state.token.balance !== null && amt > state.token.balance) return 'Not enough tokens';
  if (state.mode === 'lock') {
    const t = unlockTs();
    if (!t || t <= BigInt(Math.floor(Date.now() / 1000) + 60)) return 'Pick a future date';
  }
  if (state.mode !== 'burn' && !ownerAddress()) return 'Enter a valid owner address';
  if (state.mode !== 'lock' && !el.confirm.checked) return 'Tick the box above';
  return null;
}

function renderSubmit() {
  const t = unlockTs();
  el.sumDate.textContent = t ? `${fmtDate(t)} (${daysLeft(t)} days)` : 'Pick a date';
  el.owner.hidden = !el.otherOwner.checked;
  el.ownerHint.hidden = !el.otherOwner.checked;
  const amt = parsedAmount();
  el.sumAmt.textContent = amt && state.token ? `${fmt(amt, state.token.decimals)} ${state.token.symbol}${state.mode === 'burn' ? ', removed from supply' : ''}` : 'Enter an amount';
  if (state.mode !== 'lock') {
    const what = amt && state.token ? `${fmt(amt, state.token.decimals)} ${state.token.symbol}` : 'these tokens';
    el.confirmText.textContent = state.mode === 'burn' ? `I understand ${what} will be destroyed for good.` : `I understand ${what} can never be withdrawn, by me or anyone.`;
  }
  $$('[data-plus]').forEach(b => {
    const t0 = unlockTs();
    const want = Math.floor(Date.now() / 1000) + Number(b.dataset.plus) * 86400;
    b.setAttribute('aria-pressed', !!t0 && Math.abs(Number(t0) - want) < 120);
  });
  el.tokenCustom.hidden = el.tokenSelect.value !== 'custom';
  if (state.busy) return;
  const p = problems();
  const verb = { lock: 'Lock', forever: 'Lock forever', burn: 'Burn' }[state.mode];
  let label;
  if (!deployed) label = 'Contract not deployed yet';
  else if (!state.account) label = 'Connect wallet';
  else if (!state.chainOk) label = 'Switch to Elysium';
  else label = p || `${verb} ${el.amount.value.trim()} ${state.token.symbol}`;
  el.submit.textContent = label;
  el.submit.disabled = !!p;
}

async function submit(e) {
  e.preventDefault();
  if (!state.account) return connect();
  if (!state.chainOk) { try { await ensureChain(); await syncChain(); } catch (err) { sayErr(err); } return; }
  if (problems()) return;

  const w = wallet();
  const token = state.token;
  const amount = parsedAmount();
  state.busy = true;
  el.submit.disabled = true;
  try {
    const fee = state.fee ?? await pub.readContract({ address: PYRE, abi: pyreAbi, functionName: 'fee' });
    const allowance = await pub.readContract({ address: token.address, abi: erc20Abi, functionName: 'allowance', args: [state.account, PYRE] });
    if (allowance < amount) {
      el.submit.textContent = `Approve ${token.symbol} in your wallet…`;
      say(`Step 1 of 2: allow Elysian Pyre to move ${fmt(amount, token.decimals)} ${token.symbol}.`);
      const h = await w.writeContract({ address: token.address, abi: erc20Abi, functionName: 'approve', args: [PYRE, amount] });
      say(`Waiting for the approval ${txLink(h)}…`);
      await pub.waitForTransactionReceipt({ hash: h });
    }
    const call = state.mode === 'lock'
      ? { functionName: 'lock', args: [token.address, amount, unlockTs(), ownerAddress()] }
      : state.mode === 'forever'
        ? { functionName: 'lockPermanent', args: [token.address, amount, ownerAddress()] }
        : { functionName: 'burn', args: [token.address, amount] };
    const { request } = await pub.simulateContract({ address: PYRE, abi: pyreAbi, account: state.account, value: fee, ...call });
    el.submit.textContent = 'Confirm in your wallet…';
    say(allowance < amount ? 'Step 2 of 2: sign the transaction.' : 'Sign the transaction in your wallet.');
    const hash = await w.writeContract(request);
    say(`Sent ${txLink(hash)}, waiting for Elysium…`);
    const rc = await pub.waitForTransactionReceipt({ hash });
    if (rc.status !== 'success') throw new Error('The transaction failed on chain.');
    const done = { lock: 'Locked', forever: 'Locked forever', burn: 'Burned' }[state.mode];
    say(`${done}: ${fmt(amount, token.decimals)} ${token.symbol}. ${txLink(hash)}`, 'ok');
    el.amount.value = '';
    el.confirm.checked = false;
    await Promise.all([loadToken(), loadLocks()]);
  } catch (err) {
    sayErr(err);
  } finally {
    state.busy = false;
    renderSubmit();
  }
}

// ---------------------------------------------------------------- my locks

async function loadLocks() {
  if (!deployed) { el.list.innerHTML = '<p class="empty">Your locks show here once the contract is deployed.</p>'; return; }
  if (!state.account) { el.list.innerHTML = '<p class="empty">Connect a wallet to see your locks.</p>'; return; }
  el.list.innerHTML = '<p class="empty">Reading your locks…</p>';
  try {
    const n = await pub.readContract({ address: PYRE, abi: pyreAbi, functionName: 'userLockCount', args: [state.account] });
    const ids = n ? await pub.readContract({ address: PYRE, abi: pyreAbi, functionName: 'userLockIds', args: [state.account, 0n, n] }) : [];
    const unique = [...new Set(ids.map(String))].map(BigInt).reverse();
    const locks = await Promise.all(unique.map(async id => ({ id, ...(await pub.readContract({ address: PYRE, abi: pyreAbi, functionName: 'getLock', args: [id] })) })));
    const mine = locks.filter(l => getAddress(l.owner) === state.account);
    if (!mine.length) { el.list.innerHTML = '<p class="empty">No locks for this wallet yet.</p>'; return; }
    el.list.replaceChildren(...await Promise.all(mine.map(row)));
  } catch (err) {
    el.list.innerHTML = `<p class="empty">Could not read your locks: ${reason(err)}</p>`;
  }
}

async function row(l) {
  const meta = await tokenMeta(getAddress(l.token)).catch(() => ({ symbol: '???', decimals: 18 }));
  const node = el.tpl.content.firstElementChild.cloneNode(true);
  const now = BigInt(Math.floor(Date.now() / 1000));
  const forever = BigInt(l.unlockTime) === PERMANENT;
  const open = !forever && BigInt(l.unlockTime) <= now;
  $('[data-r-tok]', node).textContent = meta.symbol.slice(0, 4);
  $('[data-r-amount]', node).textContent = `${fmt(l.amount, meta.decimals)} ${meta.symbol}`;
  $('[data-r-meta]', node).textContent = forever ? `Lock #${l.id} · permanent`
    : `Lock #${l.id} · ${l.withdrawn ? 'opened' : 'opens'} ${fmtDate(l.unlockTime)}`;
  const chip = $('[data-r-chip]', node);
  if (l.withdrawn) { chip.textContent = 'Withdrawn'; chip.classList.add('chip--done'); }
  else if (forever) { chip.textContent = 'Forever'; chip.classList.add('chip--forever'); }
  else if (open) { chip.textContent = 'Unlocked'; chip.classList.add('chip--open'); }
  else { const d = daysLeft(l.unlockTime); chip.textContent = d > 365 ? `${Math.round(d / 365)} years left` : `${d} days left`; }

  const acts = $('[data-r-acts]', node);
  if (l.withdrawn) acts.replaceChildren();
  else {
    if (!open) $('[data-act="withdraw"]', node).remove();
    if (forever) $('[data-act="extend"]', node).remove();
  }
  const edit = $('[data-r-edit]', node), input = $('[data-r-input]', node), label = $('[data-r-edit-label]', node);
  let action = null;
  acts.addEventListener('click', async ev => {
    const b = ev.target.closest('[data-act]');
    if (!b) return;
    action = b.dataset.act;
    if (action === 'withdraw') return tx(node, 'withdraw', [l.id], 'Withdrawn');
    edit.hidden = false;
    input.id = `edit-${l.id}`;
    label.htmlFor = input.id;
    if (action === 'extend') {
      input.type = 'datetime-local'; label.textContent = 'New unlock date';
      const base = new Date(Math.max(Number(l.unlockTime) * 1000, Date.now()) + 30 * 86400000);
      input.value = new Date(base.getTime() - base.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
    } else {
      input.type = 'text'; input.value = ''; input.placeholder = '0x… new owner'; label.textContent = 'New owner address';
    }
    input.focus();
  });
  $('[data-r-cancel]', node).addEventListener('click', () => { edit.hidden = true; });
  edit.addEventListener('submit', ev => {
    ev.preventDefault();
    if (action === 'extend') {
      const t = Math.floor(new Date(input.value).getTime() / 1000);
      if (!Number.isFinite(t) || BigInt(t) <= BigInt(l.unlockTime)) { input.setAttribute('aria-invalid', 'true'); return; }
      tx(node, 'extendLock', [l.id, BigInt(t)], 'Extended');
    } else {
      const v = input.value.trim();
      if (!isAddress(v)) { input.setAttribute('aria-invalid', 'true'); return; }
      tx(node, 'transferLock', [l.id, getAddress(v)], 'Transferred');
    }
  });
  return node;
}

async function tx(node, functionName, args, done) {
  const buttons = $$('button', node);
  buttons.forEach(b => { b.disabled = true; });
  try {
    if (!state.chainOk) await ensureChain();
    const { request } = await pub.simulateContract({ address: PYRE, abi: pyreAbi, account: state.account, functionName, args });
    say('Sign the transaction in your wallet.');
    const hash = await wallet().writeContract(request);
    say(`Sent ${txLink(hash)}, waiting for Elysium…`);
    await pub.waitForTransactionReceipt({ hash });
    say(`${done}. ${txLink(hash)}`, 'ok');
    await Promise.all([loadToken(), loadLocks()]);
  } catch (err) {
    sayErr(err);
    buttons.forEach(b => { b.disabled = false; });
  }
}

// ---------------------------------------------------------------- start

function init() {
  el.tokenSelect.innerHTML = KNOWN_TOKENS.map(t => `<option value="${t.address}">${t.symbol}</option>`).join('')
    + '<option value="custom">Another token…</option>';
  const d = new Date(Date.now() + 30 * 86400000);
  el.unlock.value = new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
  el.unlock.min = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 16);

  if (!deployed) {
    el.notice.hidden = false;
    el.notice.innerHTML = '<b>The contract is not deployed on Elysium yet.</b> You can try the form, but nothing can be signed until its address is published here.';
  } else {
    el.contractLine.innerHTML = `Contract <a class="link" href="${CHAIN.explorer}/address/${PYRE}" target="_blank" rel="noopener"><code>${short(PYRE)}</code></a>`;
    pub.readContract({ address: PYRE, abi: pyreAbi, functionName: 'fee' }).then(f => {
      state.fee = f;
      el.fee.textContent = `${fmt(f, 18)} HYPE`;
    }).catch(() => {});
  }

  $$('.seg [data-mode]').forEach(t => t.addEventListener('click', () => setMode(t.dataset.mode)));
  el.tokenSelect.addEventListener('change', () => { renderSubmit(); loadToken(); if (el.tokenSelect.value === 'custom') el.tokenCustom.focus(); });
  let t;
  el.tokenCustom.addEventListener('input', () => { clearTimeout(t); t = setTimeout(loadToken, 350); });
  el.max.addEventListener('click', () => { if (state.token?.balance != null) { el.amount.value = formatUnits(state.token.balance, state.token.decimals); renderSubmit(); } });
  $$('[data-plus]').forEach(b => b.addEventListener('click', () => {
    const dt = new Date(Date.now() + Number(b.dataset.plus) * 86400000);
    el.unlock.value = new Date(dt.getTime() - dt.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
    renderSubmit();
  }));
  [el.amount, el.unlock, el.owner, el.confirm, el.otherOwner].forEach(i => i.addEventListener('input', renderSubmit));
  el.otherOwner.addEventListener('change', renderSubmit);
  el.form.addEventListener('submit', submit);
  el.connect.addEventListener('click', async () => {
    if (!state.account) return connect();
    if (!state.chainOk) { try { await ensureChain(); await syncChain(); } catch (e) { sayErr(e); } }
  });
  el.refresh.addEventListener('click', () => { loadToken(); loadLocks(); });

  if (window.ethereum) {
    window.ethereum.on?.('accountsChanged', a => { state.account = a[0] ? getAddress(a[0]) : null; syncChain(); });
    window.ethereum.on?.('chainChanged', () => syncChain());
    window.ethereum.request({ method: 'eth_accounts' }).then(a => { if (a[0]) { state.account = getAddress(a[0]); syncChain(); } }).catch(() => {});
  }
  el.tz.textContent = Intl.DateTimeFormat().resolvedOptions().timeZone || 'local';
  setMode('lock');
  loadToken();
  loadLocks();
}

init();
