// raid-indexer · Uroboros (Base, 8453) · reads the BountySanctum's Attempt / TopUp events into site/raid.json
// STEP 4 design ("main vault = break-the-caps bounty"): the public hot key may only send to the bounty Sanctum itself,
// so every allowed probe cycles back and the prize never goes down. The leaderboard ranks PROBERS (ETH cycled,
// probes); the BREACH monitor lists every ETH `Sent` by the Sanctum to anything other than itself — on a healthy
// game that list is empty forever; a non-empty list means somebody broke the contracts (and keeps the ETH).
// Read-only: no key, no gas. Incremental: keeps `lastBlock` in the output and only scans new blocks on a rerun.
//
//   once:      node scripts/raid-indexer.mjs
//   loop:      while true; do node scripts/raid-indexer.mjs; sleep 60; done
//   on a server (cron, every 5 min): node scripts/raid-indexer.mjs
//   full rescan: RESCAN=1 node scripts/raid-indexer.mjs
//   rehearsal:   BASE_RPC=http://127.0.0.1:8546 ALLOW_FORK=1 DEPLOYMENT=deployments/rehearsal-raid.json \
//                  RAID_OUT=/tmp/raid.json node scripts/raid-indexer.mjs
//
// env: BASE_RPC=https://mainnet.base.org · DEPLOYMENT=deployments/base-raid.json · RAID_OUT=site/raid.json
//      START_BLOCK=<n> (default: the deployment's bountySeededBlock, else binary search on bountySeededAt — slow on an anvil fork)
//      CHUNK=2000 (blocks per eth_getLogs; public Base RPCs reject large ranges) · RESCAN=1 · ALLOW_FORK=1
import { createPublicClient, http, getAddress, parseAbi, formatEther } from 'viem';
import { base } from 'viem/chains';
import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'fs';
import { dirname } from 'path';

const RPC = process.env.BASE_RPC || 'https://mainnet.base.org';
const DEP = process.env.DEPLOYMENT || 'deployments/base-raid.json';
const OUT = process.env.RAID_OUT || 'site/raid.json';
const CHUNK = BigInt(process.env.CHUNK || 2000);
const ZERO = '0x0000000000000000000000000000000000000000';

if (!existsSync(DEP)) { console.error('  ✗ ' + DEP + ' not found (run STEP=bounty with script/DeployRaid.s.sol first)'); process.exit(1); }
const D = JSON.parse(readFileSync(DEP, 'utf8'));
if (!D.bounty) { console.error('  ✗ ' + DEP + ' has no "bounty"'); process.exit(1); }
const BOUNTY = getAddress(D.bounty);

const B = parseAbi([
  'function sanctum() view returns (address)', 'function prize() view returns (uint256)', 'function probeRoom() view returns (uint256)',
  'function attempts() view returns (uint256)', 'function totalCycled() view returns (uint256)', 'function lastAttemptAt() view returns (uint64)',
  'function cold() view returns (address)',
  'event Attempt(address indexed caller, uint256 amount, uint256 prize)',
  'event TopUp(address indexed from, uint256 amount, uint256 prize)',
]);
const V = parseAbi([
  'function frozenUntil() view returns (uint64)', 'function guardianMutedUntil() view returns (uint64)', 'function getGuardians() view returns (address[])',
  'function rules() view returns (uint16 capBps, uint16 dayCapBps, uint16 delayBps, uint32 delay, bool allowlistOn)',
  'function daySpentRolling(address) view returns (uint256)', 'function queueLength() view returns (uint256)',
    'event Panic(address by, uint64 until)', 'event Unfrozen(address by)', 'event Deposited(address token, uint256 amount)',
  'event Sent(address token, address to, uint256 amount)',
]);

const pub = createPublicClient({ chain: base, transport: http(RPC, { retryCount: 6, retryDelay: 1500 }), cacheTime: 0 });
const prev = !process.env.RESCAN && existsSync(OUT) ? JSON.parse(readFileSync(OUT, 'utf8')) : null;

/// first block whose timestamp ≥ ts (binary search, ~25 calls)
async function blockAt(ts, hi) {
  let lo = 0n;
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    const b = await pub.getBlock({ blockNumber: mid });
    if (Number(b.timestamp) < ts) lo = mid + 1n; else hi = mid;
  }
  return lo;
}

async function logs(address, abi, from, to) {
  const out = [];
  for (let a = from; a <= to; a += CHUNK) {
    const b = a + CHUNK - 1n > to ? to : a + CHUNK - 1n;
    const got = await pub.getContractEvents({ address, abi, fromBlock: a, toBlock: b });
    out.push(...got);
  }
  return out;
}

async function main() {
  const chainId = await pub.getChainId();
  if (chainId !== 8453 && !process.env.ALLOW_FORK) { console.error('  ✗ not Base (chainId ' + chainId + '); set ALLOW_FORK=1 for anvil'); process.exit(1); }
  const head = await pub.getBlockNumber();
  const sanctum = getAddress(D.bountySanctum || await pub.readContract({ address: BOUNTY, abi: B, functionName: 'sanctum' }));

  let from;
  if (prev?.lastBlock != null && prev.bounty === BOUNTY) from = BigInt(prev.lastBlock) + 1n;
  else if (process.env.START_BLOCK) from = BigInt(process.env.START_BLOCK);
  else if (D.bountySeededBlock) from = BigInt(D.bountySeededBlock);
  else if (D.bountySeededAt) from = await blockAt(Number(D.bountySeededAt) - 60, head);
  else from = head > 500_000n ? head - 500_000n : 0n;
  if (from > head) from = head + 1n;

  const events = prev?.bounty === BOUNTY ? prev.events || [] : [];
  const freezes = prev?.bounty === BOUNTY ? prev.freezes || [] : [];
  const exits = prev?.bounty === BOUNTY ? prev.breach?.exits || [] : [];
  if (from <= head) {
    const blockTs = new Map();
    const ts = async (n) => { const k = n.toString(); if (!blockTs.has(k)) blockTs.set(k, Number((await pub.getBlock({ blockNumber: n })).timestamp)); return blockTs.get(k); };
    const got = await logs(BOUNTY, B, from, head);
    for (const l of got) {
      const t = await ts(l.blockNumber);
      if (l.eventName === 'Attempt') events.push({ kind: 'probe', caller: getAddress(l.args.caller), amount: l.args.amount.toString(), prizeAfter: l.args.prize.toString(), block: Number(l.blockNumber), tx: l.transactionHash, time: t });
      else if (l.eventName === 'TopUp') events.push({ kind: 'topUp', from: getAddress(l.args.from), amount: l.args.amount.toString(), prizeAfter: l.args.prize.toString(), block: Number(l.blockNumber), tx: l.transactionHash, time: t });
    }
    const fz = await logs(sanctum, V, from, head);
    for (const l of fz) {
      if (l.eventName === 'Panic') freezes.push({ kind: 'panic', by: getAddress(l.args.by), until: Number(l.args.until), block: Number(l.blockNumber), tx: l.transactionHash, time: await ts(l.blockNumber) });
      else if (l.eventName === 'Unfrozen') freezes.push({ kind: 'unfreeze', by: getAddress(l.args.by), block: Number(l.blockNumber), tx: l.transactionHash, time: await ts(l.blockNumber) });
      else if (l.eventName === 'Deposited' && l.args.token === ZERO) events.push({ kind: 'deposit', amount: l.args.amount.toString(), block: Number(l.blockNumber), tx: l.transactionHash, time: await ts(l.blockNumber) });
      else if (l.eventName === 'Sent' && l.args.token === ZERO && getAddress(l.args.to) !== sanctum) exits.push({ to: getAddress(l.args.to), amount: l.args.amount.toString(), block: Number(l.blockNumber), tx: l.transactionHash, time: await ts(l.blockNumber) });
    }
    console.log('   scanned blocks ' + from + '…' + head + ' · ' + got.length + ' key events · ' + fz.length + ' sanctum events');
  } else console.log('   up to date at block ' + head);
  events.sort((a, b) => a.block - b.block || (a.tx < b.tx ? -1 : 1));
  freezes.sort((a, b) => a.block - b.block);
  // dedupe by tx+kind+robber+amount (a rescan over an overlapping range must not double count)
  const seen = new Set(); const uniq = [];
  // one row per tx for top-ups (a topUp through the key also emits Deposited) and none for a probe's own return leg
  const topUpTx = new Set(events.filter((e) => e.kind === 'topUp').map((e) => e.tx));
  const probeTx = new Set(events.filter((e) => e.kind === 'probe').map((e) => e.tx));
  for (const e of events) {
    if (e.kind === 'deposit' && (topUpTx.has(e.tx) || probeTx.has(e.tx))) continue;
    const k = [e.kind, e.tx, e.caller || e.from || '', e.amount].join('|'); if (!seen.has(k)) { seen.add(k); uniq.push(e); }
  }
  const exitSeen = new Set(); const exitsU = exits.filter((x) => { const k = x.tx + '|' + x.to + '|' + x.amount; if (exitSeen.has(k)) return false; exitSeen.add(k); return true; });

  // leaderboard: probers (ETH cycled through the public key, all of it returned)
  const board = new Map();
  for (const e of uniq) {
    if (e.kind !== 'probe') continue;
    const r = board.get(e.caller) || { caller: e.caller, cycledWei: 0n, probes: 0, first: e.time, last: e.time, lastTx: e.tx };
    r.cycledWei += BigInt(e.amount); r.probes += 1; r.last = e.time; r.lastTx = e.tx;
    board.set(e.caller, r);
  }
  const leaderboard = [...board.values()].sort((a, b) => b.probes - a.probes || (b.cycledWei > a.cycledWei ? 1 : b.cycledWei < a.cycledWei ? -1 : 0))
    .map((r, i) => ({ rank: i + 1, caller: r.caller, probes: r.probes, cycledWei: r.cycledWei.toString(), cycledEth: formatEther(r.cycledWei), first: r.first, last: r.last, lastTx: r.lastTx }));

  const [prize, probeRoom, attempts, totalCycled, lastAttemptAt, cold] = await Promise.all(
    ['prize', 'probeRoom', 'attempts', 'totalCycled', 'lastAttemptAt', 'cold'].map((f) => pub.readContract({ address: BOUNTY, abi: B, functionName: f })));
  const [frozenUntil, mutedUntil, guardians, rules, spent24, qlen] = await Promise.all([
    pub.readContract({ address: sanctum, abi: V, functionName: 'frozenUntil' }), pub.readContract({ address: sanctum, abi: V, functionName: 'guardianMutedUntil' }),
    pub.readContract({ address: sanctum, abi: V, functionName: 'getGuardians' }), pub.readContract({ address: sanctum, abi: V, functionName: 'rules' }),
    pub.readContract({ address: sanctum, abi: V, functionName: 'daySpentRolling', args: [ZERO] }), pub.readContract({ address: sanctum, abi: V, functionName: 'queueLength' }),
  ]);
  const indexedCycled = uniq.filter((e) => e.kind === 'probe').reduce((s, e) => s + BigInt(e.amount), 0n);
  const prizeHigh = [BigInt(prev?.bounty === BOUNTY ? prev.prizeHighWei || 0 : 0), prize, ...uniq.filter((e) => e.prizeAfter).map((e) => BigInt(e.prizeAfter))].reduce((a, b) => (b > a ? b : a), 0n);
  const exitedWei = exitsU.reduce((s, x) => s + BigInt(x.amount), 0n);
  const out = {
    chainId, bounty: BOUNTY, sanctum, cold: getAddress(cold), guardians: guardians.map(getAddress),
    rules: { capBps: rules[0], dayCapBps: rules[1], delayBps: rules[2], delay: rules[3], queueDisabled: rules[2] === 10000, onlyDestination: sanctum },
    prizeWei: prize.toString(), prizeEth: formatEther(prize), prizeHighWei: prizeHigh.toString(),
    probeRoomWei: probeRoom.toString(), probeRoomEth: formatEther(probeRoom), spent24hWei: spent24.toString(),
    frozenUntil: Number(frozenUntil), frozen: Number(frozenUntil) * 1000 > Date.now(), guardianMutedUntil: Number(mutedUntil), queueLength: Number(qlen),
    breach: { broken: exitsU.length > 0 || prize < prizeHigh, exits: exitsU, exitedWei: exitedWei.toString(), exitedEth: formatEther(exitedWei), prizeBelowHigh: prize < prizeHigh },
    totals: { probes: Number(attempts), cycledWei: totalCycled.toString(), cycledEth: formatEther(totalCycled), probers: leaderboard.length, lastAttemptAt: Number(lastAttemptAt),
      indexedCycledWei: indexedCycled.toString(), consistent: indexedCycled === totalCycled && uniq.filter((e) => e.kind === 'probe').length === Number(attempts) },
    leaderboard, recent: uniq.filter((e) => e.kind === 'probe').slice(-50).reverse(), topUps: uniq.filter((e) => e.kind === 'topUp' || e.kind === 'deposit').slice(-50).reverse(), freezes: freezes.slice(-50).reverse(),
    events: uniq, lastBlock: Number(head), explorer: 'https://basescan.org/address/' + BOUNTY, updatedAt: new Date().toISOString(),
  };
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, JSON.stringify(out, null, 2));
  console.log('   prize ' + formatEther(prize) + ' ETH · probe room now ' + formatEther(probeRoom) + ' · ' + attempts + ' probes by ' + leaderboard.length + ' callers, ' + formatEther(totalCycled) + ' ETH cycled (all returned)' + (out.frozen ? ' · FROZEN until ' + new Date(Number(frozenUntil) * 1000).toISOString() : '') + (out.totals.consistent ? '' : ' · ⚠ indexed events ≠ contract counters (START_BLOCK too late? run RESCAN=1)'));
  if (out.breach.broken) console.log('   ‼ BREACH: ' + exitsU.length + ' ETH exit(s) from the bounty Sanctum, ' + formatEther(exitedWei) + ' ETH' + (out.breach.prizeBelowHigh ? ' · prize below its high-water mark' : '') + ' — the game was broken; check the txs');
  for (const r of leaderboard.slice(0, 10)) console.log('   #' + r.rank + ' ' + r.caller + ' ' + r.probes + ' probe' + (r.probes === 1 ? '' : 's') + ', ' + r.cycledEth + ' ETH cycled');
  console.log('   ✓ wrote ' + OUT);
}
main().catch((e) => { console.error('\n  ✗ ' + (e.shortMessage || e.message)); process.exit(1); });
