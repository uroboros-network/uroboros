# Uroboros — STEP 4 report (Ethereum chain stage, raid redesign, weekly challenges)

> Token-stack findings removed; this repo contains the Sanctum product only.

Date: 2 Nov 2026. The bounty Sanctum and the challenges deploy with the standalone `script/DeployRaid.s.sol` (`STEP=bounty|challenge|verify|status`): it reads `factory` from `deployments/base-product.json`, writes `deployments/base-raid.json`, and is funded with plain ETH. The bounty Sanctum's fee router is the product `FeeCollector`. Token-stack work in the original report (staking, emission schedule, token rehearsals) is removed.

---

## 1. Ethereum chain stage

**(a) Ethereum chain stage: complete. Audited, kept as is.**
- `src/FeeBridge.sol`: storage-free `receive()`. `bridge()` (anyone, ≥ `minBridge` 0.02 ETH) calls `L1StandardBridge.depositETHTo(feeRouterOnBase, 200000, "")`. `forwardToken()` sends ERC-20 fees to the immutable `tokenSink`. No owner.
- `script/DeploySanctumChain.s.sol` (`STEP=sanctum-chain|verify|status`): FeeBridge → Blacklist → Subscription(feed, FeeBridge, USDC) → SanctumFactory(no watcher registry) → setFactory → Sanctum7702. Resumable, writes `deployments/<chainId>.json`.
- Checked on Ethereum mainnet with `cast` (block 26,326,462): `0x5f4e…8419` `description()` = "ETH / USD", 8 decimals, live answer; `0xA0b8…eB48` = USDC, 6 decimals; `0x3154…2C35` has code, `version()` 2.8.0, `OTHER_BRIDGE()` = `0x4200…0010` (Base's L2StandardBridge).
- Tests: `FeeBridgeTest` (6, incl. a fuzz on the threshold and a 2300-gas payer) and `EthForkTest`. The fork test runs the real script stage twice (the second run changes nothing). A Sanctum queued transfer puts its 0.25% fee in FeeBridge. Subscription ETH lands in FeeBridge. **A real `bridge()`** emits `ETHDepositInitiated(feeBridge → Base fee destination)` on the L1StandardBridge, the ETH is locked in Base's OptimismPortal, and `TransactionDeposited` fires.

## 2. Raid redesign — main vault = break-the-caps bounty

`src/BountySanctum.sol`:
- `withdraw(token, to, amount)` (same selector) now requires `token == ETH` **and `to == address(sanctum)`**. That is the only destination; anything else reverts `"to"`. The amount goes out through the real `Sanctum.withdraw` (caps, freeze, blacklist) and comes straight back. Over the room → `"over cap"`; frozen → `"frozen"`. After the call the key checks `sanctum.balance >= before` (`"leak"`).
- Event: `Attempt(address indexed caller, uint256 amount, uint256 prize)` (was `Attempt(robber, token, to, amount, paid)`). Counters: `attempts`, `totalCycled` (was `totalPaid`), `lastAttemptAt`. View `probeRoom()` (was `raidableNow()`); `leakPerDay()` / `leakPerHour()` removed (the leak is zero by design). `prize()`, `topUp()`, `receive()`, `sweep()`, `TopUp`, `Swept` are unchanged.
- NatSpec and SPEC §3.2: no legitimate exit for anyone, the team included (cold = BountyCold: panic / unfreeze / setGuardians, recovery off). Whoever gets ETH out keeps it. There is also an **off-chain** team bounty for a public post-mortem, stated as a promise with no on-chain payout. The prize grows from plain ETH top-ups.
- Cap nuance (in SPEC §3.2): the rolling-day room is 2% of (balance + 24 h outflow) minus that outflow. Because probes return, up to ~2.04%/day can cycle (1% per hourly window). None of it leaves.
- `BountyCold` unchanged.
- Tests: `test/Bounty.t.sol` rewritten (18 tests: every other destination refused, plus a fuzz over any `to`; over cap / amount; events and counters; probes use the real caps; a 48 h hammer leaves the prize unchanged; random-probe fuzz; freeze / unfreeze / tighten; top-ups; sweep; ETH only). **New invariant suite `BountyRaidInvariantTest`** (3 invariants, 256 runs × 500 calls). 7 actors (dev / BountyCold owner, stranger, robber, 3 guardians, Safe) make random calls: probes to the Sanctum / own wallet / key / locker, token probes, top-ups (key and direct), every BountyCold function including ownership hand-overs, guardian panics, 12 privileged Sanctum entry points called directly, sweeps, and time. Always: the prize never decreases (checked after every action), prize == seed + top-ups exactly, no actor ever receives ETH from the game, nothing is queued, keys and rules are fixed. `Audit3` bounty tests were adapted (the AUDIT-3 L1 self-loop test became `test_STEP4_L1_self_loop_is_the_only_destination`; the BountyCold invariant ledger is now prize == seed + top-ups).
- Scripts: `scripts/raid-indexer.mjs` uses the new ABI and adds a **breach monitor** (every ETH `Sent` by the bounty Sanctum to anything but itself, plus a high-water check on the prize). `scripts/prove-sanctum.mjs` (bounty target): topUp → eth_call withdraw to own wallet (`"to"`) → probe of the cap room to the Sanctum (cycles back) → `"over cap"` → panic → `"frozen"` → unfreeze.

## 3. Weekly challenge Sanctums (CTF ladder)

New `src/challenges/`:
- `ChallengeRegistry` (Ownable2Step, owner = dev): `addLevel(challenge)` (owner; the level must name this registry and be unsolved) records (id, contract, prize, opensAt, solvedBy, solvedAt). `recordSolve(solver)` can be called only by a registered level, once. `solves[addr]`, `firstSolveAt[addr]`, `solvers[]`, `leaderboard()`, `syncPrize(id)`, `level(id)`, `levelCount()`. It never holds ETH.
- `Challenge` (abstract base): holds the prize in the house account, `opensAt` (everything reverts `"closed"` before), `fund()` for anyone until solved. Every payment goes through `_pay`. **Solve = the level's ETH balance drops below half its prize**, i.e. more than half the house money is out, net of the solver's own deposits. The solver of record is **`tx.origin`** (documented). The base records the solve in the level and calls `registry.recordSolve`, once. No owner, no team withdrawal, no approvals, no other external calls.
- Levels (name, difficulty only; each is a self-contained Sanctum-style bank with its house vault holding the prize):

| # | Name | Difficulty |
|---|---|---|
| 1 | Gate | easy |
| 2 | Cloister | medium |
| 3 | Crypt | medium-hard |
| 4 | Reliquary | hard |

  The source contains no hints and no flaw-revealing names or comments.
- **Isolation:** no shared funds, no approvals, no reference to any protocol contract. The only outside call is `recordSolve`.
- **Found in the rehearsal and fixed:** the first base swallowed a failing `recordSolve` with try/catch. On the anvil fork, a gas-estimated solve tx gave the inner call too little gas (63/64 rule). The level marked itself solved and the registry recorded nothing. Fix: `RECORD_GAS = 250_000`. `_checkSolved` requires that much gas left and passes it explicitly, so a solve either records in both places or reverts (`"gas"`). Proven by a private test that sweeps gas limits from 40k to 420k.
- Tests for the levels (honest paths and solutions) are private and are not in this repository; they will be published after each level is solved on chain. The registry and the challenge base are also exercised by `test/DeployRaid.t.sol` and `test/Review_EVM.t.sol` (with a mock level).
- Deploy: `STEP=challenge LEVEL=n PRIZE_WEI=… OPENS_AT=…` (`script/DeployRaid.s.sol`; the first run deploys the registry, owner `CHALLENGE_OWNER` or the deployer). It is resumable: an existing level is only registered. `STEP=verify` prints the registry and level commands. `STEP=status` lists the levels.
- Indexer: `scripts/challenge-indexer.mjs` → `site/challenges.json` (`npm run challenges`).
- `CHALLENGES.md`: rules (verified source, no hints, opening time, solve definition, `tx.origin`, first drain wins, no team exit, isolation, prize funding, leaderboard, scope) and an honest front-running section. Base has no public P2P mempool, but txs are visible to your RPC provider. Multi-tx solves are copyable after the first tx lands. Recommendation: one atomic tx from your own contract through a trusted RPC. Flashbots Protect is an Ethereum-mainnet service, and I did not verify any Flashbots protection on Base.

## 4. Rehearsal: raid stages on the product stack
Anvil Base fork (block 53,413,849), fresh `cast wallet new` deployer / solver / prober (deployer code 0x, nonce 0). `DeployProduct.s.sol STEP=deploy` into a scratch `deployments/rehearsal-product.json` (the real `base-product.json` was not touched) → FeeCollector + factory. `DeployRaid.s.sol`: missing product file → `PRODUCT_FILE missing: run script/DeployProduct.s.sol first`; `STEP=bounty` → BountyCold / BountySanctum / Sanctum, prize 0.5, recoveryOff true, **Sanctum `feeRouter()` = the FeeCollector**; re-run: no transactions. Probes: `"to"`, `"over cap"`, room cycles back (prize 0.5, cycled 0.005), dev `coldWithdraw` `"cold"`, BountyCold panic → `"frozen"` → unfreeze. `STEP=challenge LEVEL=1` (0.1 ETH, +10 min) → registry + L1 registered; re-run: `level already deployed`, no txs. Solve path checked: `"closed"` before open, then a solve recorded in the level, the registry and the leaderboard. Indexers: L1 Gate solved; 1 probe, `breach.broken false`. `STEP=verify` prints 5 commands. All rehearsal files, broadcast/cache dirs and keys deleted; anvil stopped.

## 5. Facts for the raid page

**Calls.**
- Probe: `withdraw(address token, address to, uint256 amount)` on `deployments.bounty`, with `token = 0x0000000000000000000000000000000000000000`, `to = deployments.bountySanctum` and `amount ≤ probeRoom()`. Returns `amount`. Example: `cast send <bounty> 'withdraw(address,address,uint256)' 0x0000000000000000000000000000000000000000 <bountySanctum> <probeRoom> --rpc-url https://mainnet.base.org`.
- Revert strings: `"eth only"` (token ≠ 0x0), `"to"` (any destination but the Sanctum), `"amount"` (0), `"frozen"`, `"over cap"` (above `probeRoom`), `"queued"` (never expected), `"leak"` (balance went down; never expected).
- Views on the key: `prize()` (ETH in the Sanctum; only grows), `probeRoom()` (what a probe can cycle now: hourly + daily room, 0 while frozen), `attempts()`, `totalCycled()`, `lastAttemptAt()`, `sanctum()`, `cold()` (= BountyCold), `factory()`. **Removed:** `leakPerDay()`, `leakPerHour()`, `raidableNow()`, `totalPaid()`.
- Events: `Attempt(address indexed caller, uint256 amount, uint256 prize)` (new signature), `TopUp(address indexed from, uint256 amount, uint256 prize)`, `Swept(address token, address to, uint256 amount)`.
- Sanctum rules (unchanged): 1%/hour (fixed hourly window), 2% per rolling 24 h of (balance + 24 h outflow), queue off, allowlist off, watchers off, recovery off. Because the balance does not shrink, about 2.04% of the prize can cycle per rolling day.
