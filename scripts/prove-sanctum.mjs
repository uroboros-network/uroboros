// prove-sanctum · Uroboros (Base, 8453) · put the Sanctum rules on chain in public, with real transactions anyone can check.
// Resumable step runner; writes site/proof.json.
//
//   look (sends nothing, prints the plan):
//     node scripts/prove-sanctum.mjs
//   send (PK from env, never stored; resumable — each signed tx is saved before broadcast):
//     PK=0x<dev private key> node scripts/prove-sanctum.mjs go
//   with a second key so the freeze is a real GUARDIAN panic (otherwise the cold key panics):
//     PK=0x<dev key> GUARDIAN_PK=0x<guardian key> node scripts/prove-sanctum.mjs go
//   rehearsal on an anvil Base fork:
//     anvil --fork-url https://mainnet.base.org --port 8546 &
//     BASE_RPC=http://127.0.0.1:8546 ALLOW_FORK=1 DEPLOYMENT=deployments/rehearsal-raid.json \
//        PK=<fresh `cast wallet new` key, funded with anvil_setBalance; never an anvil default key> node scripts/prove-sanctum.mjs go
//
// TARGET=bounty (default) — proves the live "Raid the Sanctum" key from deployments/base-raid.json (bounty, bountySanctum; script/DeployRaid.s.sol):
//   1. topUp DEPOSIT_ETH (default 0.01)              → prize grows (Deposited on the Sanctum, TopUp on the key)
//   2. withdraw capRoom to the signer                 → REVERTS "to" (STEP 4: the only destination is the bounty Sanctum)
//      — proven by eth_call, no gas; a reverting tx cannot be mined on purpose, so this step has no tx hash
//   3. withdraw capRoom (≤ 1% of the prize) to the bounty Sanctum → inside the caps: leaves and comes straight back
//      (prize unchanged, cap room consumed — the probe a thief would make, with nothing to keep)
//   3b. withdraw capRoom + 1 wei                      → REVERTS "over cap" (queue disabled: nothing is ever parked)
//   4. panic()                                        → guardian (GUARDIAN_PK, must be in the Sanctum's guardian set) or cold (PK)
//   5. eth_call withdraw while frozen                 → REVERTS "frozen"
//   6. unfreeze() by the cold key (PK = the cold, or the BountyCold owner → sent via BountyCold) → game resumes (guardians muted 24h). UNFREEZE=0 skips it.
// TARGET=fresh — creates a proof Sanctum with the DEFAULT rules (5%/h, 10%/24h, queue >10% for 6h) from PK (= hot
//   and cold), deposits, withdraws 4% (paid), 20% (QUEUED), panics (voids the queue), proves "frozen", unfreezes.
//
// env: BASE_RPC=https://mainnet.base.org · DEPLOYMENT=deployments/base-raid.json · PROOF_STATE=deployments/proof-state.json
//      PROOF_SITE=site/proof.json · DEPOSIT_ETH=0.01 · TARGET=bounty|fresh · UNFREEZE=1 · ALLOW_FORK=1 (anvil)
import { createWalletClient, createPublicClient, http, getAddress, parseAbi, parseEther, formatEther, decodeEventLog, encodeFunctionData, keccak256 } from 'viem';
import { base } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';
import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'fs';
import { dirname } from 'path';

const RPC = process.env.BASE_RPC || 'https://mainnet.base.org';
const GO = (process.argv[2] || '').toLowerCase() === 'go';
const TARGET = (process.env.TARGET || 'bounty').toLowerCase();
const DEP = process.env.DEPLOYMENT || 'deployments/base-raid.json';
const STATE = process.env.PROOF_STATE || 'deployments/proof-state.json';
const SITE_OUT = process.env.PROOF_SITE || 'site/proof.json';
const DEPOSIT = parseEther(process.env.DEPOSIT_ETH || '0.01');
const UNFREEZE = process.env.UNFREEZE !== '0';
const ZERO = '0x0000000000000000000000000000000000000000';

if (!existsSync(DEP)) { console.error('  ✗ ' + DEP + ' not found (run script/DeployRaid.s.sol STEP=bounty first)'); process.exit(1); }
const D = JSON.parse(readFileSync(DEP, 'utf8'));
const need = (k) => { if (!D[k]) { console.error('  ✗ ' + DEP + ' has no "' + k + '"'); process.exit(1); } return getAddress(D[k]); };

const B = parseAbi([
  'function withdraw(address token, address to, uint256 amount) returns (uint256 paid)',
  'function topUp() payable', 'function prize() view returns (uint256)', 'function probeRoom() view returns (uint256)',
  'function totalCycled() view returns (uint256)', 'function sanctum() view returns (address)', 'function cold() view returns (address)',
  'event Attempt(address indexed caller, uint256 amount, uint256 prize)',
  'event TopUp(address indexed from, uint256 amount, uint256 prize)',
]);
const F = parseAbi(['function create(address cold, address[] guardians, uint8 threshold) payable returns (address)',
  'event SanctumCreated(address sanctum, address owner, address cold, address[] guardians, uint8 threshold)']);
const V = parseAbi([
  'function withdraw(address token, address to, uint256 amount) returns (uint256)', 'function panic()', 'function unfreeze()',
  'function frozenUntil() view returns (uint64)', 'function queueLength() view returns (uint256)', 'function capRoom(address) view returns (uint256)',
  'function owner() view returns (address)', 'function cold() view returns (address)', 'function isGuardian(address) view returns (bool)',
  'function guardianMutedUntil() view returns (uint64)',
  'function rules() view returns (uint16 capBps, uint16 dayCapBps, uint16 delayBps, uint32 delay, bool allowlistOn)',
  'event QueuedTransfer(uint256 id, address token, address to, uint256 amount, uint64 readyAt)', 'event Sent(address token, address to, uint256 amount)',
  'event Panic(address by, uint64 until)', 'event GuardianPanic(address sanctum, address guardian)', 'event Unfrozen(address by)',
]);

const transport = http(RPC, { retryCount: 6, retryDelay: 1500 });
const pub = createPublicClient({ chain: base, transport, cacheTime: 0 });
const S = existsSync(STATE) ? JSON.parse(readFileSync(STATE, 'utf8')) : {};
const save = () => { mkdirSync(dirname(STATE), { recursive: true }); writeFileSync(STATE, JSON.stringify(S, null, 2)); };
const fe = (w) => Number(formatEther(w)).toLocaleString('en-US', { maximumFractionDigits: 6 });
const pl = (t) => new Date(Number(t) * 1000).toLocaleString('en-GB', { timeZone: 'Europe/Warsaw' }) + ' Poland';
const reasonOf = (e) => {
  for (let c = e; c; c = c.cause) { if (typeof c.reason === 'string' && c.reason) return c.reason; if (c.data?.errorName && c.data.errorName !== 'Error') return c.data.errorName; }
  const m = [e.shortMessage, e.details, e.message].filter(Boolean).join('\n');
  const r = m.match(/reverted with the following reason:\s*([^\n]+)/) || m.match(/reason:\s*([^\n]+)/) || m.match(/execution reverted:?\s*([^\n]+)/);
  return r ? r[1].trim() : m.split('\n')[0].slice(0, 120);
};

/// idempotent send: the signed tx is saved before broadcast, so a crash or timeout never double-sends
async function step(w, key, label, req) {
  S.tx = S.tx || {};
  if (S.tx[key]?.status === 'success') { console.log('   ' + label.padEnd(34) + '(done) ' + S.tx[key].hash); return S.tx[key]; }
  let hash = S.tx[key]?.hash;
  if (hash) {
    const rc = await pub.getTransactionReceipt({ hash }).catch(() => null);
    if (!rc) { try { await pub.sendRawTransaction({ serializedTransaction: S.tx[key].raw }); } catch (e) { if (!/known|already|nonce too low/i.test(e.message)) throw e; } }
  } else {
    await pub.simulateContract({ account: w.account, ...req });
    const data = encodeFunctionData({ abi: req.abi, functionName: req.functionName, args: req.args || [] });
    const gas = (await pub.estimateGas({ account: w.account.address, to: req.address, data, value: req.value })) * 13n / 10n;
    const raw = await w.signTransaction(await w.prepareTransactionRequest({ to: req.address, data, gas, value: req.value }));
    hash = keccak256(raw);
    S.tx[key] = { hash, raw, from: w.account.address }; save();
    await pub.sendRawTransaction({ serializedTransaction: raw });
  }
  process.stdout.write('   ' + label.padEnd(34) + hash.slice(0, 14) + '… ');
  const rc = await pub.waitForTransactionReceipt({ hash, timeout: 600_000 });
  if (rc.status !== 'success') { console.log('✗ reverted'); process.exit(1); }
  S.tx[key] = { hash, status: 'success', block: Number(rc.blockNumber), from: S.tx[key].from }; save();
  console.log('ok');
  return { ...S.tx[key], rc };
}

/// a revert proven by eth_call (no gas, nothing mined): recorded with block number + reason instead of a hash
async function proveRevert(key, label, req, want) {
  let reason = 'did not revert';
  try { await pub.simulateContract(req); } catch (e) { reason = reasonOf(e); }
  const ok = new RegExp(want, 'i').test(reason);
  console.log('   ' + label.padEnd(34) + (ok ? 'reverted: "' + want + '" ✓' : '✗ ' + reason));
  if (!ok) process.exit(1);
  S.calls = S.calls || {};
  S.calls[key] = { reverted: true, reason: want, block: Number(await pub.getBlockNumber()), at: new Date().toISOString(), args: req.args.map(String) };
  save();
}

async function main() {
  const chainId = await pub.getChainId();
  if (chainId !== 8453 && !process.env.ALLOW_FORK) { console.error('  ✗ not Base (chainId ' + chainId + '); set ALLOW_FORK=1 for anvil'); process.exit(1); }
  console.log('\n🐍  Uroboros · Sanctum proof on Base · target ' + TARGET);

  let acct = null, guardian = null, w = null, gw = null;
  if (GO) {
    if (!process.env.PK) { console.error('  ✗ set PK=0x… (dev key: hot/cold of the proof)'); process.exit(1); }
    acct = privateKeyToAccount(process.env.PK);
    w = createWalletClient({ account: acct, chain: base, transport });
    if (process.env.GUARDIAN_PK) { guardian = privateKeyToAccount(process.env.GUARDIAN_PK); gw = createWalletClient({ account: guardian, chain: base, transport }); }
    const eth = await pub.getBalance({ address: acct.address });
    console.log('   signer    ' + acct.address + ' · ' + Number(formatEther(eth)).toFixed(5) + ' ETH' + (guardian ? '\n   guardian  ' + guardian.address : ''));
    if (eth < DEPOSIT + parseEther('0.001')) { console.error('  ✗ needs DEPOSIT (' + fe(DEPOSIT) + ') + gas'); process.exit(1); }
    if (S.signer && getAddress(S.signer) !== acct.address) { console.error('  ✗ this proof was started by ' + S.signer + ', use that key or delete ' + STATE); process.exit(1); }
    if (S.target && S.target !== TARGET) { console.error('  ✗ ' + STATE + ' is a ' + S.target + ' proof; delete it or set TARGET=' + S.target); process.exit(1); }
    S.signer = acct.address; S.target = TARGET; S.chainId = chainId; save();
  }

  // ---- resolve the Sanctum under proof
  let sanctum, key = null, steps = [];
  if (TARGET === 'bounty') {
    key = need('bounty'); sanctum = getAddress(await pub.readContract({ address: key, abi: B, functionName: 'sanctum' }));
    if (D.bountySanctum && getAddress(D.bountySanctum) !== sanctum) { console.error('  ✗ bounty.sanctum() ≠ deployments bountySanctum'); process.exit(1); }
  } else if (TARGET === 'fresh') {
    const factory = need('factory');
    if (!S.sanctum) {
      console.log('   factory   ' + factory + ' · creating a proof Sanctum (hot = cold = signer, default rules) with ' + fe(DEPOSIT) + ' ETH');
      if (!GO) { console.log('\n   look-only. Send with: PK=0x… node scripts/prove-sanctum.mjs go\n'); return; }
      const guardians = guardian ? [guardian.address] : [];
      const c = await step(w, 'create', 'create proof Sanctum (+deposit)', { address: factory, abi: F, functionName: 'create', args: [acct.address, guardians, 0], value: DEPOSIT });
      const rc = c.rc || await pub.getTransactionReceipt({ hash: c.hash });
      for (const l of rc.logs) { try { const e = decodeEventLog({ abi: F, ...l }); if (e.eventName === 'SanctumCreated') S.sanctum = getAddress(e.args.sanctum); } catch {} }
      if (!S.sanctum) { console.error('  ✗ SanctumCreated not found'); process.exit(1); }
      save();
    }
    sanctum = getAddress(S.sanctum);
  } else { console.error('  ✗ TARGET must be bounty|fresh'); process.exit(1); }

  const [rules, owner, cold, frozen0, room0, bal0] = await Promise.all([
    pub.readContract({ address: sanctum, abi: V, functionName: 'rules' }), pub.readContract({ address: sanctum, abi: V, functionName: 'owner' }),
    pub.readContract({ address: sanctum, abi: V, functionName: 'cold' }), pub.readContract({ address: sanctum, abi: V, functionName: 'frozenUntil' }),
    pub.readContract({ address: sanctum, abi: V, functionName: 'capRoom', args: [ZERO] }), pub.getBalance({ address: sanctum }),
  ]);
  console.log('   Sanctum   ' + sanctum + ' · ' + fe(bal0) + ' ETH · cap room now ' + fe(room0) + ' ETH' + (key ? '\n   hot key   ' + key + ' (BountySanctum: anyone may call withdraw)' : ''));
  console.log('   rules     ' + rules[0] / 100 + '%/h · ' + rules[1] / 100 + '%/24h · ' + (rules[2] === 10000 ? 'queue OFF (above the caps reverts)' : 'queue above ' + rules[2] / 100 + '% for ' + rules[3] / 3600 + 'h'));
  // AUDIT-3 M1: on the bounty the cold key is the BountyCold locker; its owner panics/unfreezes THROUGH it.
  const viaLocker = TARGET === 'bounty' && D.bountyCold && getAddress(D.bountyCold) === getAddress(cold);
  const coldCtl = viaLocker ? getAddress(await pub.readContract({ address: cold, abi: parseAbi(['function owner() view returns (address)']), functionName: 'owner' })) : getAddress(cold);
  const coldAddr = viaLocker ? getAddress(cold) : sanctum; // where the cold key's panic()/unfreeze() is sent
  const canCold = coldCtl === acct.address;
  console.log('   cold      ' + cold + (viaLocker ? ' (BountyCold locker, owner ' + coldCtl + ')' : '') + (GO && canCold ? ' (signer controls it: can unfreeze)' : GO ? ' ⚠ signer does not control it: step 6 (unfreeze) will be skipped' : ''));
  if (Number(frozen0) * 1000 > Date.now() && !S.tx?.panic) console.log('   ⚠ already frozen until ' + pl(frozen0) + ' — the proof will wait for the cold key to unfreeze first');
  if (key && getAddress(owner) !== key) { console.error('  ✗ the Sanctum\'s hot key is not the BountySanctum (cold rotated it)'); process.exit(1); }
  if (GO && guardian) {
    const isG = await pub.readContract({ address: sanctum, abi: V, functionName: 'isGuardian', args: [guardian.address] });
    if (!isG) { console.error('  ✗ GUARDIAN_PK ' + guardian.address + ' is not a guardian of this Sanctum (cold: sanctum.setGuardians)'); process.exit(1); }
  }
  if (!GO) {
    console.log('\n   plan: ' + (TARGET === 'bounty' ? 'topUp ' + fe(DEPOSIT) + ' → eth_call withdraw to the signer ("to") → withdraw capRoom to the Sanctum (cycles back) → withdraw capRoom+1 (eth_call: "over cap") → panic → eth_call withdraw ("frozen") → unfreeze'
      : 'withdraw 4% (paid) → withdraw 20% (queued 6h) → panic (voids queue) → eth_call withdraw ("frozen") → unfreeze'));
    console.log('   look-only. Send with: PK=0x… node scripts/prove-sanctum.mjs go\n'); return;
  }

  // STEP 4: on the bounty the only destination is the bounty Sanctum itself (every allowed outflow cycles back)
  const to = TARGET === 'bounty' ? sanctum : acct.address;
  const wdAbi = key ? B : V, wdAddr = key ? key : sanctum;
  const wd = (amount, dest = to) => ({ address: wdAddr, abi: wdAbi, functionName: 'withdraw', args: [ZERO, dest, amount] });
  if (TARGET === 'bounty') {
    await step(w, 'deposit', 'topUp ' + fe(DEPOSIT) + ' ETH → prize', { address: key, abi: B, functionName: 'topUp', value: DEPOSIT });
    if (!S.amounts) { const room = await pub.readContract({ address: sanctum, abi: V, functionName: 'capRoom', args: [ZERO] }); if (room === 0n) { console.error('  ✗ cap room is 0 right now (hour/day used up) — rerun in an hour'); process.exit(1); } S.amounts = { wdOk: room.toString() }; save(); }
    const ok = BigInt(S.amounts.wdOk);
    if (!S.calls?.wdSelf) await proveRevert('wdSelf', 'withdraw to own wallet → revert', { account: acct, ...wd(ok, acct.address) }, 'to');
    else console.log('   ' + 'withdraw to own wallet → revert'.padEnd(34) + '(done) eth_call "to"');
    await step(w, 'wdOk', 'probe ' + fe(ok) + ' → cycles back', wd(ok));
    if (!S.calls?.wdOver) {
      const room = await pub.readContract({ address: sanctum, abi: V, functionName: 'capRoom', args: [ZERO] });
      await proveRevert('wdOver', 'withdraw cap room + 1 wei → revert', { account: acct, ...wd(room + 1n) }, 'over cap');
    } else console.log('   ' + 'withdraw cap room + 1 wei → revert'.padEnd(34) + '(done) eth_call "over cap"');
  } else {
    const P = (bps) => DEPOSIT * BigInt(bps) / 10000n;
    await step(w, 'wdSmall', 'withdraw ' + fe(P(400)) + ' (4%) → paid', wd(P(400)));
    await step(w, 'wdBig', 'withdraw ' + fe(P(2000)) + ' (20%) → queued 6h', wd(P(2000)));
  }

  // freeze: guardian if we have one, else the cold key (= signer on a bounty, owner/cold on fresh)
  const frozenNow = Number(await pub.readContract({ address: sanctum, abi: V, functionName: 'frozenUntil' })) * 1000 > Date.now();
  if (!S.tx?.panic && frozenNow) { console.error('  ✗ Sanctum is already frozen by someone else; wait for the cold key to unfreeze, then rerun'); process.exit(1); }
  S.panicBy = S.panicBy || (guardian ? 'guardian' : 'cold');
  await step(S.panicBy === 'guardian' ? gw : w, 'panic', 'panic() by ' + S.panicBy + ' → frozen 24h', { address: S.panicBy === 'guardian' ? sanctum : coldAddr, abi: V, functionName: 'panic' });
  if (!S.calls?.wdFrozen) await proveRevert('wdFrozen', 'withdraw while frozen → revert', { account: acct, ...wd(1n) }, 'frozen');
  else console.log('   ' + 'withdraw while frozen → revert'.padEnd(34) + '(done) eth_call "frozen"');

  if (UNFREEZE && canCold) await step(w, 'unfreeze', 'unfreeze() by cold → game resumes', { address: coldAddr, abi: V, functionName: 'unfreeze' });
  else console.log('   unfreeze skipped (' + (UNFREEZE ? 'signer does not control the cold key' : 'UNFREEZE=0') + ')');

  // ---- the live numbers the site re-reads
  const [frozen, qlen, bal, muted] = await Promise.all([
    pub.readContract({ address: sanctum, abi: V, functionName: 'frozenUntil' }), pub.readContract({ address: sanctum, abi: V, functionName: 'queueLength' }),
    pub.getBalance({ address: sanctum }), pub.readContract({ address: sanctum, abi: V, functionName: 'guardianMutedUntil' }),
  ]);
  console.log('\n   Sanctum holds ' + fe(bal) + ' ETH · queue ' + qlen + ' · ' + (Number(frozen) * 1000 > Date.now() ? 'frozen until ' + pl(frozen) : 'not frozen') + (Number(muted) * 1000 > Date.now() ? ' · guardians muted until ' + pl(muted) : ''));

  const scan = 'https://basescan.org/tx/';
  const defs = TARGET === 'bounty' ? [
    { key: 'deposit', label: 'Top up ' + fe(DEPOSIT) + ' ETH', expect: 'prize grows; ETH sits in the Sanctum, never in the key contract' },
    { key: 'wdSelf', label: 'Withdraw ' + fe(BigInt(S.amounts.wdOk)) + ' ETH to the caller', expect: 'reverts "to" — the only allowed destination is the bounty Sanctum itself', call: true },
    { key: 'wdOk', label: 'Probe ' + fe(BigInt(S.amounts.wdOk)) + ' ETH (the cap room, ≤ 1%) to the Sanctum', expect: 'inside the hourly and daily caps: leaves and comes straight back, prize unchanged' },
    { key: 'wdOver', label: 'Withdraw cap room + 1 wei', expect: 'reverts "over cap" — the queue is off, nothing is parked', call: true },
    { key: 'panic', label: 'Panic by ' + S.panicBy, expect: 'frozen 24 hours' },
    { key: 'wdFrozen', label: 'Withdraw while frozen', expect: 'reverts "frozen"', call: true },
    { key: 'unfreeze', label: 'Unfreeze by the cold key', expect: 'game resumes; guardians muted 24h' },
  ] : [
    { key: 'create', label: 'Sanctum created with ' + fe(DEPOSIT) + ' ETH', expect: 'default rules: 5%/h, 10%/24h, queue above 10% for 6h' },
    { key: 'wdSmall', label: 'Withdraw 4%', expect: 'inside the caps: paid at once' },
    { key: 'wdBig', label: 'Withdraw 20%', expect: 'above 10%: queued for 6 hours, nothing sent' },
    { key: 'panic', label: 'Panic by ' + S.panicBy, expect: 'frozen 24 hours, queued transfer voided' },
    { key: 'wdFrozen', label: 'Withdraw while frozen', expect: 'reverts "frozen"', call: true },
    { key: 'unfreeze', label: 'Unfreeze by the cold key', expect: 'outflows resume under the caps; guardians muted 24h' },
  ];
  const out = {
    chainId, target: TARGET, sanctum, hotKey: key || S.signer, signer: S.signer, cold: getAddress(cold), guardian: guardian?.address || null,
    rules: { capBps: rules[0], dayCapBps: rules[1], delayBps: rules[2], delay: rules[3], queueDisabled: rules[2] === 10000 },
    steps: defs.map((s) => s.call
      ? { ...s, tx: null, block: S.calls?.[s.key]?.block ?? null, reverted: S.calls?.[s.key]?.reason ?? null, provenAt: S.calls?.[s.key]?.at ?? null }
      : { ...s, tx: S.tx?.[s.key]?.hash ?? null, block: S.tx?.[s.key]?.block ?? null, url: S.tx?.[s.key]?.hash ? scan + S.tx[s.key].hash : null, skipped: !S.tx?.[s.key] }),
    frozenUntil: Number(frozen), guardianMutedUntil: Number(muted), queueLength: Number(qlen), balanceWei: bal.toString(),
    explorer: 'https://basescan.org/address/' + sanctum, writtenAt: new Date().toISOString(),
  };
  mkdirSync(dirname(SITE_OUT), { recursive: true });
  writeFileSync(SITE_OUT, JSON.stringify(out, null, 2));
  console.log('\n   ✓ wrote ' + SITE_OUT + ' · redeploy the site to publish it\n   Basescan: ' + out.explorer + '\n');
}
main().catch((e) => { console.error('\n  ✗ ' + (e.shortMessage || e.message)); process.exit(1); });
