// Elysian Pyre admin: deploy the contract from the browser, publish its address on the site, run it.
import { createPublicClient, createWalletClient, custom, http, parseUnits, formatUnits, isAddress, getAddress, defineChain, BaseError, ContractFunctionRevertedError } from './viem.js';
import { pyreAbi, pyreBytecode } from './abi.js';
import { CHAIN } from './config.js';

const elysium = defineChain({ id: CHAIN.id, name: CHAIN.name, nativeCurrency: CHAIN.currency, rpcUrls: { default: { http: [CHAIN.rpc] } }, blockExplorers: { default: { name: 'Elyscan', url: CHAIN.explorer } } });
const pub = createPublicClient({ chain: elysium, transport: http(CHAIN.rpc) });
// must match worker/index.js publishMessage() exactly
const publishMessage = (address) => `Elysian Pyre\nPublish contract ${getAddress(address)} on Elysium (chain 99901) as the site's contract.`;

const $ = (s) => document.querySelector(s);
const esc = (t) => String(t).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const link = (kind, v) => `<a href="${CHAIN.explorer}/${kind}/${v}" target="_blank" rel="noopener">${short(v)}</a>`;
const say = (el, html, kind = '') => { el.className = 'msg' + (kind ? ` is-${kind}` : ''); el.innerHTML = html; };
const hype = (wei) => `${Number(formatUnits(wei, 18)).toLocaleString('en-US', { maximumFractionDigits: 4 })} HYPE`;
function reason(err) {
  if (err instanceof BaseError) {
    const rev = err.walk((e) => e instanceof ContractFunctionRevertedError);
    if (rev?.data?.errorName) return ({ FeeTooHigh: 'The fee can be 1 HYPE at most.', ZeroAddress: 'That address is not valid here.', NothingToWithdraw: 'There are no fees to send yet.', OwnableUnauthorizedAccount: 'Only the contract admin can do this.' })[rev.data.errorName] || `The contract refused: ${rev.data.errorName}.`;
    if (err.walk((e) => e.code === 4001 || /rejected|denied/i.test(e.shortMessage || ''))) return 'You rejected the request in your wallet.';
    return err.shortMessage || err.message;
  }
  return err?.message || String(err);
}

const state = { account: null, chainOk: false, site: { contract: null, admin: null }, apiOk: false, contract: null };
let pending = null; try { pending = localStorage.getItem('pyre-pending-contract'); } catch { /* storage off */ }

const wallet = () => createWalletClient({ chain: elysium, transport: custom(window.ethereum), account: state.account });
async function ensureChain() {
  const id = parseInt(await window.ethereum.request({ method: 'eth_chainId' }), 16);
  if (id === CHAIN.id) return;
  try { await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN.hexId }] }); }
  catch (e) {
    if (e.code !== 4902) throw e;
    await window.ethereum.request({ method: 'wallet_addEthereumChain', params: [{ chainId: CHAIN.hexId, chainName: CHAIN.name, nativeCurrency: CHAIN.currency, rpcUrls: [CHAIN.rpc], blockExplorerUrls: [CHAIN.explorer] }] });
  }
}
async function connect() {
  if (!window.ethereum) { say($('[data-deploy-msg]'), 'No browser wallet found. Install one such as MetaMask or Rabby, then reload this page.', 'err'); return; }
  try {
    const [a] = await window.ethereum.request({ method: 'eth_requestAccounts' });
    state.account = getAddress(a);
    await ensureChain();
    await sync();
  } catch (e) { say($('[data-deploy-msg]'), esc(reason(e)), 'err'); }
}
async function sync() {
  if (state.account && window.ethereum) state.chainOk = parseInt(await window.ethereum.request({ method: 'eth_chainId' }), 16) === CHAIN.id;
  render();
  await loadContract();
}

async function loadSite() {
  try {
    const r = await fetch('/api/config', { cache: 'no-store' });
    state.site = await r.json(); state.apiOk = true;
  } catch { state.apiOk = false; }
}

function render() {
  const st = $('[data-status]');
  st.classList.toggle('is-on', !!state.account && state.chainOk); st.classList.toggle('is-warn', !!state.account && !state.chainOk);
  $('[data-status-text]').textContent = !state.account ? 'No wallet connected' : state.chainOk ? `${short(state.account)} · Elysium` : `${short(state.account)} · switch to Elysium`;
  const c = $('[data-connect]');
  c.textContent = state.account ? (state.chainOk ? short(state.account) : 'Switch to Elysium') : 'Connect wallet';
  c.classList.toggle('btn--primary', !(state.account && state.chainOk)); c.classList.toggle('btn--secondary', !!(state.account && state.chainOk));

  const admin = state.site.admin;
  const isAdmin = !!(admin && state.account && getAddress(admin) === state.account);
  $('[data-admin-line]').innerHTML = !state.apiOk
    ? 'The site API is not reachable from here, so publishing is off. Open this page on the live site.'
    : !admin ? 'The site has no admin wallet set yet.'
    : `Site admin wallet: <span class="addr">${esc(admin)}</span>${state.account ? (isAdmin ? ' <span class="tag tag--ok">You</span>' : ' <span class="tag tag--warn">Not this wallet</span>') : ''}`;

  // step 1
  const d = $('[data-deploy]');
  for (const id of ['#d-owner', '#d-recipient']) if (state.account && !$(id).value) $(id).value = state.account;
  d.textContent = !state.account ? 'Connect wallet' : !state.chainOk ? 'Switch to Elysium' : 'Deploy contract';
  // step 2
  const addr = $('#p-address').value.trim() || pending || '';
  if (!$('#p-address').value && pending) $('#p-address').value = pending;
  const published = state.site.contract;
  const canPublish = state.apiOk && isAdmin && isAddress(addr) && (!published || getAddress(addr) !== getAddress(published));
  $('[data-publish]').disabled = !canPublish;
  $('[data-step="publish"]').classList.toggle('is-locked', !(isAddress(addr) || published));
  $('[data-step="deploy"]').classList.toggle('is-done', !!(pending || published));
  $('[data-step="publish"]').classList.toggle('is-done', !!published && (!addr || getAddress(addr) === getAddress(published)));
  if (published && !$('[data-publish-msg]').textContent) say($('[data-publish-msg]'), `Live on the site: ${link('address', published)}.`, 'ok');
  if (!isAdmin && state.account && state.apiOk && admin && isAddress(addr)) say($('[data-publish-msg]'), 'Connect the site admin wallet to publish.');

  const live = $('[data-live-tag]');
  live.textContent = published ? 'Live on the site' : pending ? 'Deployed, not published' : 'Not published';
  live.className = 'tag' + (published ? ' tag--ok' : pending ? ' tag--warn' : '');
}

// step 1: deploy from the browser
async function deploy() {
  if (!state.account) return connect();
  if (!state.chainOk) { await ensureChain().catch((e) => say($('[data-deploy-msg]'), esc(reason(e)), 'err')); return sync(); }
  const msg = $('[data-deploy-msg]');
  const owner = $('#d-owner').value.trim(), recipient = $('#d-recipient').value.trim();
  if (!isAddress(owner)) return say(msg, 'Enter a valid admin address.', 'err');
  if (!isAddress(recipient)) return say(msg, 'Enter a valid fee recipient address.', 'err');
  let fee; try { fee = parseUnits($('#d-fee').value.trim() || '0', 18); } catch { return say(msg, 'Enter the fee as a number, like 0.1.', 'err'); }
  if (fee > 10n ** 18n) return say(msg, 'The fee can be 1 HYPE at most.', 'err');
  const btn = $('[data-deploy]'); btn.disabled = true;
  try {
    say(msg, 'Confirm the deployment in your wallet.');
    const hash = await wallet().deployContract({ abi: pyreAbi, bytecode: pyreBytecode, args: [getAddress(owner), getAddress(recipient), fee] });
    say(msg, `Sent ${link('tx', hash)}, waiting for Elysium…`);
    const rc = await pub.waitForTransactionReceipt({ hash });
    if (rc.status !== 'success' || !rc.contractAddress) throw new Error('The deployment failed on chain.');
    pending = getAddress(rc.contractAddress);
    try { localStorage.setItem('pyre-pending-contract', pending); } catch { /* storage off */ }
    $('#p-address').value = pending;
    say(msg, `Contract deployed at ${link('address', pending)}. Now publish it on the site.`, 'ok');
    render(); await loadContract();
  } catch (e) { say(msg, esc(reason(e)), 'err'); }
  finally { btn.disabled = false; }
}

// step 2: sign and publish
async function publish() {
  const msg = $('[data-publish-msg]');
  const addr = $('#p-address').value.trim();
  if (!isAddress(addr)) return say(msg, 'Enter the contract address.', 'err');
  const btn = $('[data-publish]'); btn.disabled = true;
  try {
    say(msg, 'Sign the message in your wallet. It costs nothing.');
    const signature = await wallet().signMessage({ message: publishMessage(addr) });
    say(msg, 'Checking the contract and publishing…');
    const r = await fetch('/api/config', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ address: getAddress(addr), signature }) });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error || `The site refused (${r.status}).`);
    state.site = j; pending = null; try { localStorage.removeItem('pyre-pending-contract'); } catch { /* storage off */ }
    say(msg, `Published. The app and the home page now use ${link('address', j.contract)}.`, 'ok');
    render(); await loadContract();
  } catch (e) { say(msg, esc(reason(e)), 'err'); render(); }
}

// the contract panel
async function loadContract() {
  const addr = state.site.contract || pending;
  $('[data-run]').hidden = !addr; $('[data-run-empty]').hidden = !!addr;
  if (!addr) return;
  state.contract = getAddress(addr);
  $('[data-run-address]').innerHTML = `Contract ${link('address', state.contract)}`;
  const read = (functionName) => pub.readContract({ address: state.contract, abi: pyreAbi, functionName });
  try {
    const [locks, fee, recipient, owner, pendingOwner, balance] = await Promise.all([read('lockCount'), read('fee'), read('feeRecipient'), read('owner'), read('pendingOwner'), pub.getBalance({ address: state.contract })]);
    $('[data-s-locks]').textContent = locks.toLocaleString('en-US');
    $('[data-s-balance]').textContent = hype(balance);
    $('[data-s-fee]').textContent = hype(fee);
    $('[data-s-recipient]').textContent = recipient; $('[data-s-owner]').textContent = owner;
    const none = pendingOwner === '0x0000000000000000000000000000000000000000';
    $('[data-s-pending]').textContent = none ? 'None' : pendingOwner;
    $('[data-a="acceptOwnership"]').hidden = none || !state.account || getAddress(pendingOwner) !== state.account;
  } catch (e) { say($('[data-run-msg]'), `Could not read the contract: ${esc(reason(e))}`, 'err'); }
}
async function run(functionName, args = []) {
  const msg = $('[data-run-msg]');
  if (!state.account) return connect();
  try {
    if (!state.chainOk) { await ensureChain(); await sync(); }
    const { request } = await pub.simulateContract({ address: state.contract, abi: pyreAbi, account: state.account, functionName, args });
    say(msg, 'Confirm in your wallet.');
    const hash = await wallet().writeContract(request);
    say(msg, `Sent ${link('tx', hash)}, waiting for Elysium…`);
    await pub.waitForTransactionReceipt({ hash });
    say(msg, `Done. ${link('tx', hash)}`, 'ok');
    await loadContract();
  } catch (e) { say(msg, esc(reason(e)), 'err'); }
}

// wiring
$('[data-connect]').addEventListener('click', () => (state.account && state.chainOk ? null : state.account ? ensureChain().then(sync) : connect()));
$('[data-deploy]').addEventListener('click', deploy);
$('[data-publish]').addEventListener('click', publish);
$('#p-address').addEventListener('input', render);
document.querySelector('[data-a="withdrawFees"]').addEventListener('click', () => run('withdrawFees'));
document.querySelector('[data-a="acceptOwnership"]').addEventListener('click', () => run('acceptOwnership'));
document.querySelectorAll('[data-form]').forEach((f) => f.addEventListener('submit', (e) => {
  e.preventDefault();
  const input = f.querySelector('input'); const v = input.value.trim(); input.removeAttribute('aria-invalid');
  if (f.dataset.form === 'setFee') {
    let wei; try { wei = parseUnits(v, 18); } catch { input.setAttribute('aria-invalid', 'true'); return; }
    if (wei > 10n ** 18n) { input.setAttribute('aria-invalid', 'true'); say($('[data-run-msg]'), 'The fee can be 1 HYPE at most.', 'err'); return; }
    return run('setFee', [wei]);
  }
  if (!isAddress(v)) { input.setAttribute('aria-invalid', 'true'); return; }
  run(f.dataset.form, [getAddress(v)]);
}));
if (window.ethereum) {
  window.ethereum.on?.('accountsChanged', (a) => { state.account = a[0] ? getAddress(a[0]) : null; sync(); });
  window.ethereum.on?.('chainChanged', () => sync());
  window.ethereum.request({ method: 'eth_accounts' }).then((a) => { if (a[0]) { state.account = getAddress(a[0]); sync(); } }).catch(() => {});
}
await loadSite();
render();
await loadContract();
