// challenge-indexer · Uroboros (Base, 8453) · weekly Sanctum challenge ladder → site/challenges.json
// Reads the ChallengeRegistry (levels, prize, opensAt, solvedBy/solvedAt, leaderboard) and each level contract (live
// prize, ETH still inside, open/closed). Read-only: no key, no gas. Safe to run on a cron.
//
//   once:      node scripts/challenge-indexer.mjs
//   on a server (cron, every 5 min): node scripts/challenge-indexer.mjs
//   rehearsal: BASE_RPC=http://127.0.0.1:8546 ALLOW_FORK=1 DEPLOYMENT=deployments/rehearsal-raid.json \
//                CHALLENGES_OUT=/tmp/challenges.json node scripts/challenge-indexer.mjs
//
// env: BASE_RPC=https://mainnet.base.org · DEPLOYMENT=deployments/base-raid.json · CHALLENGES_OUT=site/challenges.json
//      CHUNK=2000 (blocks per eth_getLogs) · ALLOW_FORK=1 (anvil)
// Level names / difficulty come from CHALLENGES.md (public). Nothing about a level's flaw is ever written here.
import { createPublicClient, http, getAddress, parseAbi, formatEther } from 'viem';
import { base } from 'viem/chains';
import { readFileSync, existsSync, writeFileSync, mkdirSync } from 'fs';
import { dirname } from 'path';

const RPC = process.env.BASE_RPC || 'https://mainnet.base.org';
const DEP = process.env.DEPLOYMENT || 'deployments/base-raid.json';
const OUT = process.env.CHALLENGES_OUT || 'site/challenges.json';
const CHUNK = BigInt(process.env.CHUNK || 2000);
const ZERO = '0x0000000000000000000000000000000000000000';

// public metadata only (CHALLENGES.md): name + difficulty per level contract type
const META = { 1: { name: 'Gate', difficulty: 'easy' }, 2: { name: 'Cloister', difficulty: 'medium' }, 3: { name: 'Crypt', difficulty: 'medium-hard' }, 4: { name: 'Reliquary', difficulty: 'hard' } };

if (!existsSync(DEP)) { console.error('  ✗ ' + DEP + ' not found (run STEP=challenge with script/DeployRaid.s.sol first)'); process.exit(1); }
const D = JSON.parse(readFileSync(DEP, 'utf8'));
if (!D.challengeRegistry) { console.error('  ✗ ' + DEP + ' has no "challengeRegistry" (run STEP=challenge with script/DeployRaid.s.sol first)'); process.exit(1); }
const REG = getAddress(D.challengeRegistry);

const R = parseAbi([
  'function levelCount() view returns (uint256)',
  'function level(uint256 id) view returns ((address challenge, uint96 prize, uint64 opensAt, address solvedBy, uint64 solvedAt))',
  'function leaderboard() view returns (address[] who, uint256[] count, uint64[] first)',
  'function owner() view returns (address)',
  'event Solved(uint256 indexed id, address indexed solver, uint256 prize, uint64 solvedAt)',
  'event LevelAdded(uint256 indexed id, address indexed challenge, uint256 prize, uint64 opensAt)',
]);
const C = parseAbi(['function prize() view returns (uint256)', 'function opensAt() view returns (uint64)', 'function solvedBy() view returns (address)']);

const pub = createPublicClient({ chain: base, transport: http(RPC, { retryCount: 6, retryDelay: 1500 }), cacheTime: 0 });

async function logs(address, abi, from, to) {
  const out = [];
  for (let a = from; a <= to; a += CHUNK) {
    const b = a + CHUNK - 1n > to ? to : a + CHUNK - 1n;
    out.push(...await pub.getContractEvents({ address, abi, fromBlock: a, toBlock: b }));
  }
  return out;
}

/// Which LevelN a deployed level is: matched against the deployment file (challengeL1..challengeL4).
function levelType(addr) {
  for (let n = 1; n <= 4; n++) if (D['challengeL' + n] && getAddress(D['challengeL' + n]) === addr) return n;
  return null;
}

async function main() {
  const chainId = await pub.getChainId();
  if (chainId !== 8453 && !process.env.ALLOW_FORK) { console.error('  ✗ not Base (chainId ' + chainId + '); set ALLOW_FORK=1 for anvil'); process.exit(1); }
  const head = await pub.getBlockNumber();
  const now = Number((await pub.getBlock({ blockNumber: head })).timestamp);
  const n = Number(await pub.readContract({ address: REG, abi: R, functionName: 'levelCount' }));
  const levels = [];
  for (let id = 1; id <= n; id++) {
    const L = await pub.readContract({ address: REG, abi: R, functionName: 'level', args: [BigInt(id)] });
    const addr = getAddress(L.challenge);
    const [prize, bal] = await Promise.all([pub.readContract({ address: addr, abi: C, functionName: 'prize' }), pub.getBalance({ address: addr })]);
    const t = levelType(addr);
    const solved = L.solvedBy !== ZERO;
    levels.push({
      id, contract: addr, level: t, name: t ? META[t].name : null, difficulty: t ? META[t].difficulty : null,
      prizeWei: prize.toString(), prizeEth: formatEther(prize), balanceWei: bal.toString(), balanceEth: formatEther(bal),
      opensAt: Number(L.opensAt), open: now >= Number(L.opensAt), status: solved ? 'solved' : now >= Number(L.opensAt) ? 'open' : 'upcoming',
      solvedBy: solved ? getAddress(L.solvedBy) : null, solvedAt: solved ? Number(L.solvedAt) : null, prizeAtSolveWei: solved ? L.prize.toString() : null,
      explorer: 'https://basescan.org/address/' + addr + '#code',
    });
  }
  // solve txs (for links): from the registry's deploy block
  const from = D.challengeRegistryBlock ? BigInt(D.challengeRegistryBlock) : head > 200_000n ? head - 200_000n : 0n;
  const solvedEv = (await logs(REG, R, from, head)).filter((l) => l.eventName === 'Solved');
  for (const e of solvedEv) { const L = levels[Number(e.args.id) - 1]; if (L) L.solveTx = e.transactionHash; }

  const [who, count, first] = await pub.readContract({ address: REG, abi: R, functionName: 'leaderboard' });
  const leaderboard = who.map((w, i) => ({ solver: getAddress(w), solves: Number(count[i]), firstSolveAt: Number(first[i]),
    levels: levels.filter((l) => l.solvedBy === getAddress(w)).map((l) => l.id) }))
    .sort((a, b) => b.solves - a.solves || a.firstSolveAt - b.firstSolveAt)
    .map((r, i) => ({ rank: i + 1, ...r }));

  const out = {
    chainId, registry: REG, owner: getAddress(await pub.readContract({ address: REG, abi: R, functionName: 'owner' })),
    levels, leaderboard,
    totals: { levels: n, solved: levels.filter((l) => l.status === 'solved').length, open: levels.filter((l) => l.status === 'open').length,
      upcoming: levels.filter((l) => l.status === 'upcoming').length,
      prizeOpenWei: levels.filter((l) => l.status !== 'solved').reduce((s, l) => s + BigInt(l.balanceWei), 0n).toString() },
    solverOfRecord: 'tx.origin of the transaction that took the level below half its prize',
    lastBlock: Number(head), updatedAt: new Date().toISOString(),
  };
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, JSON.stringify(out, null, 2));
  for (const l of levels) console.log('   L' + l.id + ' ' + (l.name || '?') + ' · ' + l.status + ' · prize ' + l.prizeEth + ' ETH · inside ' + l.balanceEth + ' ETH' + (l.solvedBy ? ' · solved by ' + l.solvedBy : ''));
  console.log('   ' + leaderboard.length + ' solver(s) · ✓ wrote ' + OUT);
}
main().catch((e) => { console.error('\n  ✗ ' + (e.shortMessage || e.message)); process.exit(1); });
