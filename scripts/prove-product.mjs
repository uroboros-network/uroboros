// prove-product · Uroboros (Base, 8453) · real transactions against a Sanctum made by the live PRODUCT factory
// (script/DeployProduct.s.sol → deployments/base-product.json), written to site/proof.json for the home page.
//
// Three keys, all read from env and never printed or stored (only signed transactions are saved, for resume):
//   PK          hot key: creates the proof Sanctum through factory.create, deposits, withdraws, executes the queue
//   COLD_PK     the proof Sanctum's cold key (a fresh `cast wallet new` key): unfreezes, approves the re-queue
//   GUARDIAN_PK the proof Sanctum's one guardian (another fresh key): the panic
// Cold and guardian get a tiny gas top-up from PK when they hold less than GAS_TOPUP_ETH.
//
//   look (sends nothing):   node scripts/prove-product.mjs
//   run:                    node scripts/prove-product.mjs go       (PK, COLD_PK, GUARDIAN_PK)
//   6 hours later:          node scripts/prove-product.mjs follow   (PK only: executes the matured re-queue)
//   rewrite proof.json:     node scripts/prove-product.mjs write    (no key, reads chain + state)
//
// `go` (resumable: every signed tx is saved before broadcast, a re-run skips what is done):
//   1. factory.create(cold, [guardian], 1) with DEPOSIT_ETH (default 0.002) → Sanctum with the DEFAULT rules
//   2. withdraw 4% → paid at once (inside 5%/h and 10%/24h)
//   3. withdraw 20% → QUEUED for 6 hours (queue id + readyAt recorded)
//   4. guardian panic() → frozen 24h, the queued transfer is voided
//   5. eth_call withdraw while frozen → reverts "frozen" (no gas; block recorded)
//   6. cold unfreeze() → outflows resume, guardians muted 24h
//   7. eth_call executeQueued(step 3) → reverts "voided by panic"
//   8. withdraw 20% again → QUEUED 6h; 9. cold approveQueued (queued inside the 24h guardian mute, so the cold key vouches)
// `follow` (from readyAt of step 8 on): 10. executeQueued → paid after 6h, 0.25% fee to FeeCollector.
//
// env: BASE_RPC=https://mainnet.base.org · DEPLOYMENT=deployments/base-product.json
//      PROOF_STATE=deployments/product-proof-state.json · PROOF_SITE=site/proof.json
//      DEPOSIT_ETH=0.002 · GAS_TOPUP_ETH=0.0002 · ALLOW_FORK=1 (anvil fork with --chain-id 8453 is still refused without it)
import {
  createWalletClient, createPublicClient, http, getAddress, parseAbi, parseEther, formatEther, decodeEventLog,
  encodeFunctionData, encodeAbiParameters, parseAbiParameters, keccak256,
} from 'viem';
import { base } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'fs';
import { dirname } from 'path';

const RPC = process.env.BASE_RPC || 'https://mainnet.base.org';
const MODE = (process.argv[2] || 'look').toLowerCase();
const DEP = process.env.DEPLOYMENT || 'deployments/base-product.json';
const STATE = process.env.PROOF_STATE || 'deployments/product-proof-state.json';
const SITE_OUT = process.env.PROOF_SITE || 'site/proof.json';
const DEPOSIT = parseEther(process.env.DEPOSIT_ETH || '0.002');
const TOPUP = parseEther(process.env.GAS_TOPUP_ETH || '0.0002');
const ZERO = '0x0000000000000000000000000000000000000000';
const SCAN = 'https://basescan.org';
if (!['look', 'go', 'follow', 'write'].includes(MODE)) { console.error('  ✗ mode must be look | go | follow | write'); process.exit(1); }

if (!existsSync(DEP)) { console.error('  ✗ ' + DEP + ' not found (run STEP=deploy of script/DeployProduct.s.sol first)'); process.exit(1); }
const D = JSON.parse(readFileSync(DEP, 'utf8'));
const need = (k) => { if (!D[k]) { console.error('  ✗ ' + DEP + ' has no "' + k + '"'); process.exit(1); } return getAddress(D[k]); };
const FACTORY = need('factory'), COLLECTOR = need('feeCollector');

const F = parseAbi([
  'function create(address cold, address[] guardians, uint8 threshold) payable returns (address)',
  'function feeRouter() view returns (address)', 'function blacklist() view returns (address)', 'function watcherRegistry() view returns (address)',
  'event SanctumCreated(address sanctum, address owner, address cold, address[] guardians, uint8 threshold)',
]);
const V = parseAbi([
  'function withdraw(address token, address to, uint256 amount) returns (uint256)', 'function panic()', 'function unfreeze()',
  'function executeQueued(uint256 id)', 'function approveQueued(uint256 id)',
  'function frozenUntil() view returns (uint64)', 'function queueLength() view returns (uint256)', 'function capRoom(address) view returns (uint256)',
  'function owner() view returns (address)', 'function cold() view returns (address)', 'function isGuardian(address) view returns (bool)',
  'function guardianMutedUntil() view returns (uint64)', 'function feeRouter() view returns (address)',
  'function lastPanicAt() view returns (uint64)', 'function queuedAt(uint256) view returns (uint64)',
  'function queue(uint256) view returns (address token, address to, uint256 amount, uint64 readyAt, bool done)',
  'function rules() view returns (uint16 capBps, uint16 dayCapBps, uint16 delayBps, uint32 delay, bool allowlistOn)',
  'event QueuedTransfer(uint256 id, address token, address to, uint256 amount, uint64 readyAt)', 'event Sent(address token, address to, uint256 amount)',
  'event QueuedFee(uint256 id, address token, uint256 fee)',
  'event Panic(address by, uint64 until)', 'event GuardianPanic(address sanctum, address guardian)', 'event Unfrozen(address by)',
]);

const transport = http(RPC, { retryCount: 6, retryDelay: 1500 });
const pub = createPublicClient({ chain: base, transport, cacheTime: 0 });
const S = existsSync(STATE) ? JSON.parse(readFileSync(STATE, 'utf8')) : {};
const save = () => { mkdirSync(dirname(STATE), { recursive: true }); writeFileSync(STATE, JSON.stringify(S, null, 2)); };
const fe = (w) => Number(formatEther(w)).toLocaleString('en-US', { maximumFractionDigits: 8 });
const pl = (t) => new Date(Number(t) * 1000).toLocaleString('en-GB', { timeZone: 'Europe/Warsaw', dateStyle: 'medium', timeStyle: 'short' }) + ' Poland time';
const utc = (t) => new Date(Number(t) * 1000).toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
const reasonOf = (e) => {
  for (let c = e; c; c = c.cause) { if (typeof c.reason === 'string' && c.reason) return c.reason; if (c.data?.errorName && c.data.errorName !== 'Error') return c.data.errorName; }
  const m = [e.shortMessage, e.details, e.message].filter(Boolean).join('\n');
  const r = m.match(/reverted with the following reason:\s*([^\n]+)/) || m.match(/reason:\s*([^\n]+)/) || m.match(/execution reverted:?\s*([^\n]+)/);
  return r ? r[1].trim() : m.split('\n')[0].slice(0, 120);
};
const chainNow = async () => Number((await pub.getBlock()).timestamp);
const logsOf = (rc, abi) => rc.logs.flatMap((l) => { try { return [{ ...decodeEventLog({ abi, data: l.data, topics: l.topics }), address: l.address }]; } catch { return []; } });

/// idempotent send: the signed tx is saved before broadcast, so a crash or timeout never double-sends
async function step(w, key, label, req) {
  S.tx = S.tx || {};
  if (S.tx[key]?.status === 'success') { console.log('   ' + label.padEnd(44) + '(done) ' + S.tx[key].hash); return { ...S.tx[key], rc: null }; }
  let hash = S.tx[key]?.hash;
  if (hash) {
    const rc = await pub.getTransactionReceipt({ hash }).catch(() => null);
    if (!rc) { try { await pub.sendRawTransaction({ serializedTransaction: S.tx[key].raw }); } catch (e) { if (!/known|already|nonce too low/i.test(e.message)) throw e; } }
  } else {
    const data = req.abi ? encodeFunctionData({ abi: req.abi, functionName: req.functionName, args: req.args || [] }) : '0x';
    if (req.abi) await pub.simulateContract({ account: w.account, ...req });
    const gas = (await pub.estimateGas({ account: w.account.address, to: req.address, data, value: req.value })) * 13n / 10n;
    const raw = await w.signTransaction(await w.prepareTransactionRequest({ to: req.address, data, gas, value: req.value }));
    hash = keccak256(raw);
    S.tx[key] = { hash, raw, from: w.account.address }; save();
    await pub.sendRawTransaction({ serializedTransaction: raw });
  }
  process.stdout.write('   ' + label.padEnd(44) + hash.slice(0, 14) + '… ');
  const rc = await pub.waitForTransactionReceipt({ hash, timeout: 600_000 });
  if (rc.status !== 'success') { console.log('✗ reverted'); process.exit(1); }
  const blk = await pub.getBlock({ blockNumber: rc.blockNumber });
  S.tx[key] = { hash, status: 'success', block: Number(rc.blockNumber), at: Number(blk.timestamp), from: S.tx[key].from, gasUsed: rc.gasUsed.toString() }; save();
  console.log('ok');
  return { ...S.tx[key], rc };
}
const receipt = async (r) => r.rc || pub.getTransactionReceipt({ hash: r.hash });

/// a revert proven by eth_call (no gas, nothing mined): recorded with block number + reason instead of a hash
async function proveRevert(key, label, req, want) {
  S.calls = S.calls || {};
  if (S.calls[key]) { console.log('   ' + label.padEnd(44) + '(done) eth_call "' + S.calls[key].reason + '"'); return; }
  let reason = 'did not revert';
  try { await pub.simulateContract(req); } catch (e) { reason = reasonOf(e); }
  const ok = new RegExp(want, 'i').test(reason);
  console.log('   ' + label.padEnd(44) + (ok ? 'reverted: "' + want + '" ✓' : '✗ ' + reason));
  if (!ok) process.exit(1);
  S.calls[key] = { reverted: true, reason: want, block: Number(await pub.getBlockNumber()), at: new Date().toISOString(), args: (req.args || []).map(String) };
  save();
}

/// queue id + readyAt from a withdraw receipt
async function recordQueue(key, r) {
  if (S.queue?.[key]) return S.queue[key];
  const ev = logsOf(await receipt(r), V).find((e) => e.eventName === 'QueuedTransfer');
  if (!ev) { console.error('  ✗ ' + key + ': no QueuedTransfer event — the withdraw was paid, not queued'); process.exit(1); }
  if (key === 'second') {
    const [qa, lp] = await Promise.all([
      pub.readContract({ address: S.sanctum, abi: V, functionName: 'queuedAt', args: [ev.args.id] }),
      pub.readContract({ address: S.sanctum, abi: V, functionName: 'lastPanicAt' }),
    ]);
    if (qa <= lp) { console.error('  ✗ re-queue #' + ev.args.id + ' landed in the panic\'s second and is void; delete S.tx.requeue from ' + STATE + ' and rerun go'); process.exit(1); }
  }
  S.queue = S.queue || {};
  S.queue[key] = { id: Number(ev.args.id), readyAt: Number(ev.args.readyAt), amount: ev.args.amount.toString() };
  save();
  return S.queue[key];
}

function wallet(envName) {
  const k = process.env[envName];
  if (!k) return null;
  const account = privateKeyToAccount(k.startsWith('0x') ? k : '0x' + k);
  return createWalletClient({ account, chain: base, transport });
}

async function main() {
  const chainId = await pub.getChainId();
  if (chainId !== 8453) { console.error('  ✗ not Base (chainId ' + chainId + ')'); process.exit(1); }
  if (/127\.0\.0\.1|localhost/.test(RPC) && !process.env.ALLOW_FORK) { console.error('  ✗ local RPC: set ALLOW_FORK=1 for an anvil rehearsal'); process.exit(1); }
  console.log('\n🐍  Uroboros · Sanctum product proof on Base · mode ' + MODE);
  const [fr, fcCode] = await Promise.all([pub.readContract({ address: FACTORY, abi: F, functionName: 'feeRouter' }), pub.getCode({ address: COLLECTOR })]);
  if (!fcCode || fcCode === '0x') { console.error('  ✗ feeCollector has no code'); process.exit(1); }
  if (getAddress(fr) !== COLLECTOR) { console.error('  ✗ factory.feeRouter ' + fr + ' ≠ feeCollector ' + COLLECTOR); process.exit(1); }
  console.log('   factory   ' + FACTORY + ' · fees → FeeCollector ' + COLLECTOR);

  const hot = MODE === 'go' || MODE === 'follow' ? wallet('PK') : null;
  const coldW = MODE === 'go' ? wallet('COLD_PK') : null;
  const guardW = MODE === 'go' ? wallet('GUARDIAN_PK') : null;
  if ((MODE === 'go' || MODE === 'follow') && !hot) { console.error('  ✗ PK not set'); process.exit(1); }
  if (MODE === 'go') {
    if (!coldW || !guardW) { console.error('  ✗ go needs COLD_PK and GUARDIAN_PK too (make them with: cast wallet new)'); process.exit(1); }
    const a = [hot, coldW, guardW].map((w) => w.account.address);
    if (new Set(a).size !== 3) { console.error('  ✗ PK, COLD_PK and GUARDIAN_PK must be three different keys'); process.exit(1); }
    if (S.hot && getAddress(S.hot) !== a[0]) { console.error('  ✗ this proof was started by hot ' + S.hot + '; use that PK or delete ' + STATE); process.exit(1); }
    if (S.cold && getAddress(S.cold) !== a[1]) { console.error('  ✗ this proof uses cold ' + S.cold + '; use that COLD_PK'); process.exit(1); }
    if (S.guardian && getAddress(S.guardian) !== a[2]) { console.error('  ✗ this proof uses guardian ' + S.guardian + '; use that GUARDIAN_PK'); process.exit(1); }
    const eth = await pub.getBalance({ address: a[0] });
    console.log('   hot       ' + a[0] + ' · ' + fe(eth) + ' ETH\n   cold      ' + a[1] + '\n   guardian  ' + a[2]);
    if (!S.sanctum && eth < DEPOSIT + 2n * TOPUP + parseEther('0.0005')) { console.error('  ✗ hot needs DEPOSIT (' + fe(DEPOSIT) + ') + 2 × gas top-up (' + fe(TOPUP) + ') + ~0.0005 gas'); process.exit(1); }
    S.hot = a[0]; S.cold = a[1]; S.guardian = a[2]; S.chainId = chainId; S.factory = FACTORY; S.feeCollector = COLLECTOR;
    S.deposit = S.deposit || DEPOSIT.toString(); save();
  }
  if (MODE === 'follow' && S.hot && getAddress(S.hot) !== hot.account.address) { console.error('  ✗ PK is not the proof hot key ' + S.hot); process.exit(1); }

  if (MODE === 'look') {
    console.log('   plan: create (cold + 1 guardian, ' + fe(DEPOSIT) + ' ETH) → withdraw 4% (paid) → withdraw 20% (queued 6h) → guardian panic (voids queue)'
      + ' → eth_call withdraw ("frozen") → cold unfreeze → eth_call executeQueued ("voided by panic") → re-queue 20% + cold approve → [6h later: follow] execute');
    if (S.sanctum) console.log('   state: Sanctum ' + S.sanctum + ' · ' + Object.keys(S.tx || {}).filter((k) => S.tx[k].status === 'success').join(', '));
    console.log('   look-only. Send with: node scripts/prove-product.mjs go\n');
    return;
  }
  if (MODE === 'write') { if (!S.sanctum) { console.error('  ✗ no proof Sanctum in ' + STATE); process.exit(1); } return writeOut(chainId); }

  const dep = BigInt(S.deposit || DEPOSIT);
  const P = (bps) => dep * BigInt(bps) / 10000n;

  if (MODE === 'go') {
    // gas for cold and guardian (they only sign 1–2 small txs)
    for (const [k, w] of [['fundCold', coldW], ['fundGuardian', guardW]]) {
      if (S.tx?.[k]?.status === 'success') continue;
      const b = await pub.getBalance({ address: w.account.address });
      if (b >= TOPUP) { console.log('   ' + ('gas ' + k.slice(4).toLowerCase()).padEnd(44) + 'has ' + fe(b) + ' ETH'); continue; }
      await step(hot, k, 'gas top-up ' + fe(TOPUP) + ' → ' + k.slice(4).toLowerCase(), { address: w.account.address, value: TOPUP });
    }

    // 1. create through the live factory
    if (!S.sanctum) {
      const c = await step(hot, 'create', 'factory.create (+' + fe(dep) + ' ETH)', { address: FACTORY, abi: F, functionName: 'create', args: [S.cold, [S.guardian], 1], value: dep });
      const ev = logsOf(await receipt(c), F).find((e) => e.eventName === 'SanctumCreated' && getAddress(e.address) === FACTORY);
      if (!ev) { console.error('  ✗ SanctumCreated not found'); process.exit(1); }
      S.sanctum = getAddress(ev.args.sanctum); save();
    } else console.log('   ' + 'factory.create'.padEnd(44) + '(done) ' + S.tx.create.hash);
  }
  if (!S.sanctum) { console.error('  ✗ no proof Sanctum yet: run go first'); process.exit(1); }
  const sanctum = getAddress(S.sanctum);
  const rd = (fn, args) => pub.readContract({ address: sanctum, abi: V, functionName: fn, args });
  const [owner, cold, fr2] = await Promise.all([rd('owner'), rd('cold'), rd('feeRouter')]);
  if (getAddress(fr2) !== COLLECTOR) { console.error('  ✗ Sanctum feeRouter ≠ FeeCollector'); process.exit(1); }
  if (getAddress(owner) !== getAddress(S.hot) || getAddress(cold) !== getAddress(S.cold)) { console.error('  ✗ Sanctum keys changed since the proof started'); process.exit(1); }
  console.log('   Sanctum   ' + sanctum + ' · ' + fe(await pub.getBalance({ address: sanctum })) + ' ETH');
  const wd = (amount) => ({ address: sanctum, abi: V, functionName: 'withdraw', args: [ZERO, S.hot, amount] });

  if (MODE === 'go') {
    // 2–3
    await step(hot, 'wdSmall', 'withdraw ' + fe(P(400)) + ' (4%) → paid now', wd(P(400)));
    const q1 = await recordQueue('first', await step(hot, 'wdBig', 'withdraw ' + fe(P(2000)) + ' (20%) → queued 6h', wd(P(2000))));
    console.log('   ' + ''.padEnd(44) + 'queue #' + q1.id + ' ready ' + pl(q1.readyAt));
    // 4–5
    const isG = await rd('isGuardian', [S.guardian]);
    if (!isG) { console.error('  ✗ guardian is not in the Sanctum guardian set'); process.exit(1); }
    if (!S.tx?.panic && Number(await rd('frozenUntil')) > await chainNow()) { console.error('  ✗ already frozen by someone else'); process.exit(1); }
    await step(guardW, 'panic', 'guardian panic() → frozen 24h', { address: sanctum, abi: V, functionName: 'panic' });
    if (!S.tx?.unfreeze) await proveRevert('wdFrozen', 'withdraw while frozen (eth_call)', { account: hot.account, ...wd(1n) }, 'frozen');
    else console.log('   ' + 'withdraw while frozen (eth_call)'.padEnd(44) + '(done) eth_call "' + (S.calls?.wdFrozen?.reason || 'frozen') + '"');
    // 6–7
    await step(coldW, 'unfreeze', 'cold unfreeze() → resumes, guardians muted 24h', { address: sanctum, abi: V, functionName: 'unfreeze' });
    await proveRevert('execVoided', 'execute voided queue #' + q1.id + ' (eth_call)', { account: hot.account, address: sanctum, abi: V, functionName: 'executeQueued', args: [BigInt(q1.id)] }, 'voided by panic');
    // 8–9: a panic voids everything queued at or before its timestamp, so the re-queue must land in a LATER second
    if (S.tx?.requeue?.status !== 'success') {
      const lp = Number(await rd('lastPanicAt'));
      for (let i = 0; (await chainNow()) <= lp; i++) {
        if (i > 60) { console.error('  ✗ chain time is not moving past the panic (anvil without --block-time?)'); process.exit(1); }
        await new Promise((r) => setTimeout(r, 2000));
      }
    }
    const q2 = await recordQueue('second', await step(hot, 'requeue', 're-queue ' + fe(P(2000)) + ' (20%) → queued 6h', wd(P(2000))));
    console.log('   ' + ''.padEnd(44) + 'queue #' + q2.id + ' ready ' + pl(q2.readyAt));
    await step(coldW, 'approve', 'cold approveQueued(#' + q2.id + ')', { address: sanctum, abi: V, functionName: 'approveQueued', args: [BigInt(q2.id)] });
    console.log('\n   next: from ' + pl(q2.readyAt) + ' run the follow-up (PK only): node scripts/prove-product.mjs follow');
  }

  if (MODE === 'follow') {
    const q2 = S.queue?.second;
    if (!q2 || S.tx?.approve?.status !== 'success') { console.error('  ✗ the re-queue (go) is not finished'); process.exit(1); }
    const now = await chainNow();
    if (S.tx?.execute?.status !== 'success' && now < q2.readyAt) {
      const left = q2.readyAt - now;
      console.log('   queue #' + q2.id + ' ready ' + pl(q2.readyAt) + ' · ' + Math.floor(left / 3600) + 'h ' + Math.floor((left % 3600) / 60) + 'm left. Re-run then.');
    } else {
      const fb0 = await pub.getBalance({ address: COLLECTOR });
      const x = await step(hot, 'execute', 'executeQueued(#' + q2.id + ') after 6h → paid', { address: sanctum, abi: V, functionName: 'executeQueued', args: [BigInt(q2.id)] });
      if (!S.fee) {
        const ev = logsOf(await receipt(x), V).find((e) => e.eventName === 'QueuedFee');
        S.fee = ev ? ev.args.fee.toString() : null; save();
        console.log('   ' + ''.padEnd(44) + '0.25% fee ' + (ev ? fe(ev.args.fee) : '?') + ' ETH → FeeCollector (was ' + fe(fb0) + ')');
      }
    }
  }
  return writeOut(chainId);
}

async function writeOut(chainId) {
  const sanctum = getAddress(S.sanctum);
  const rd = (fn, args) => pub.readContract({ address: sanctum, abi: V, functionName: fn, args });
  const [rules, frozen, qlen, bal, muted, cold] = await Promise.all([rd('rules'), rd('frozenUntil'), rd('queueLength'), pub.getBalance({ address: sanctum }), rd('guardianMutedUntil'), rd('cold')]);
  const dep = BigInt(S.deposit);
  const P = (bps) => dep * BigInt(bps) / 10000n;
  const q1 = S.queue?.first, q2 = S.queue?.second;
  const defs = [
    { key: 'create', label: 'Sanctum created by the live factory with ' + fe(dep) + ' ETH', expect: 'default rules: 5%/h, 10%/24h, queue above 10% for 6h; one guardian, separate cold key' },
    { key: 'wdSmall', label: 'Withdraw ' + fe(P(400)) + ' ETH (4%)', expect: 'inside the caps: paid at once' },
    { key: 'wdBig', label: 'Withdraw ' + fe(P(2000)) + ' ETH (20%)' + (q1 ? ': queue #' + q1.id + ', ready ' + utc(q1.readyAt) : ''), expect: 'above 10%: queued for 6 hours, nothing sent', queueId: q1?.id ?? null, readyAt: q1?.readyAt ?? null },
    { key: 'panic', label: 'Panic by the guardian', expect: 'frozen 24 hours, the queued transfer is voided' },
    { key: 'wdFrozen', label: 'Withdraw while frozen', expect: 'reverts "frozen"', call: true },
    { key: 'unfreeze', label: 'Unfreeze by the cold key', expect: 'outflows resume under the caps; guardians muted 24h' },
    { key: 'execVoided', label: 'Execute queue #' + (q1?.id ?? '?') + ' after the panic', expect: 'reverts "voided by panic": a freeze kills what was queued before it', call: true },
    { key: 'requeue', label: 'Withdraw ' + fe(P(2000)) + ' ETH (20%) again' + (q2 ? ': queue #' + q2.id + ', ready ' + utc(q2.readyAt) : ''), expect: 'queued for 6 hours', queueId: q2?.id ?? null, readyAt: q2?.readyAt ?? null },
    { key: 'approve', label: 'Cold key approves queue #' + (q2?.id ?? '?'), expect: 'queued inside the 24h guardian mute, so it needs the cold key\'s approval; the 6h delay still applies' },
    { key: 'execute', label: 'Execute queue #' + (q2?.id ?? '?') + ' after 6 hours', expect: 'paid in full minus the 0.25% queued-transfer fee' + (S.fee ? ' (' + fe(BigInt(S.fee)) + ' ETH to the FeeCollector)' : '') },
  ];
  const out = {
    chainId, target: 'product', factory: FACTORY, feeCollector: COLLECTOR, sanctum, hotKey: S.hot, signer: S.hot,
    cold: getAddress(cold), guardian: S.guardian,
    rules: { capBps: rules[0], dayCapBps: rules[1], delayBps: rules[2], delay: rules[3], queueDisabled: rules[2] === 10000 },
    steps: defs.map(({ call, ...s }) => call
      ? { ...s, call: true, tx: null, block: S.calls?.[s.key]?.block ?? null, reverted: S.calls?.[s.key]?.reason ?? null, provenAt: S.calls?.[s.key]?.at ?? null }
      : { ...s, tx: S.tx?.[s.key]?.status === 'success' ? S.tx[s.key].hash : null, block: S.tx?.[s.key]?.block ?? null,
        url: S.tx?.[s.key]?.status === 'success' ? SCAN + '/tx/' + S.tx[s.key].hash : null, skipped: S.tx?.[s.key]?.status !== 'success' }),
    queuedFeeWei: S.fee || null,
    frozenUntil: Number(frozen), guardianMutedUntil: Number(muted), queueLength: Number(qlen), balanceWei: bal.toString(),
    explorer: SCAN + '/address/' + sanctum, writtenAt: new Date().toISOString(),
  };
  mkdirSync(dirname(SITE_OUT), { recursive: true });
  writeFileSync(SITE_OUT, JSON.stringify(out, null, 2) + '\n');
  const done = out.steps.filter((s) => s.tx || s.reverted).length;
  console.log('\n   ✓ wrote ' + SITE_OUT + ' (' + done + '/' + out.steps.length + ' steps) · Basescan: ' + out.explorer);

  // verify command for the proof Sanctum (exact constructor args; other factory Sanctums then show as Similar Match)
  if (S.tx?.create?.status === 'success') {
    const code = await pub.getCode({ address: sanctum });
    const b = code.slice(2), n = b.length / 2, byte = (i) => parseInt(b.slice(2 * i, 2 * i + 2), 16);
    const patch = byte(n - 3), commits = { 24: 'e11b9ed9', 25: 'b61c2a91', 26: '8a97fa7a', 27: '40a35a09', 28: '7893614a', 29: 'ab55807c', 30: '73712a01' };
    const solc = process.env.SOLC_VERSION || (byte(n - 4) === 8 && commits[patch] ? 'v0.8.' + patch + '+commit.' + commits[patch] : null);
    const [bl, wr] = await Promise.all([pub.readContract({ address: FACTORY, abi: F, functionName: 'blacklist' }), pub.readContract({ address: FACTORY, abi: F, functionName: 'watcherRegistry' })]);
    const args = encodeAbiParameters(parseAbiParameters('address, address, address, address, address, address[], uint8, (uint16, uint16, uint16, uint32, bool)'),
      [S.hot, S.cold, bl, wr, COLLECTOR, [S.guardian], 1, [500, 1000, 1000, 21600, false]]);
    if (solc) console.log('   verify the proof Sanctum:\n   forge verify-contract --chain base --watch --compiler-version ' + solc + ' --evm-version ' + (patch >= 28 ? 'prague' : 'cancun')
      + ' --optimizer-runs 200 --constructor-args ' + args + ' ' + sanctum + ' src/Sanctum.sol:Sanctum\n');
  }
}

main().catch((e) => { console.error('\n  ✗ ' + (e.shortMessage || e.message)); process.exit(1); });
