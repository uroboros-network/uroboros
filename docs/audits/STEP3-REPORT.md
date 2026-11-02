# Uroboros — Step 3 report

> Token-stack findings removed; this repo contains the Sanctum product only.

Date: 2 Nov 2026 · Scope: SPEC §7 step 3 (`BountySanctum` + leaderboard indexer + proof writer + deploy stage). No site HTML (raid.html is §7b / step 6), no Blacklist v2, no watcher market.
Result:
- **`forge test` (product suites) → 124 passed, 0 failed** (step-1 suites + `BountyTest` 21). `BountyTest` alone: 21 passed.
- The bounty deploy stage was rehearsed on an anvil Base fork: dry run, broadcast, re-run ("No transactions to broadcast"); both viem scripts run against it end to end. Rehearsal state files deleted.

## Contracts

| File | Lines | What |
|---|---|---|
| `src/BountySanctum.sol` | 122 | Constructor `(factory, cold, guardians[], threshold)` payable: calls `SanctumFactory.createWithRules{value}` with `capBps 100 · dayCapBps 200 · delayBps 10000 · delay 24h · allowlist off`; the contract becomes the Sanctum's hot key, msg.value is the first prize; asserts `owner == this && cold == _cold`. `withdraw(token, to, amount)` (anyone): `to != this`, `amount > 0`, not frozen, **`amount ≤ sanctum.capRoom(token)` else revert `"over cap"`**, then `sanctum.withdraw` and `require(id == max)` ("queued", unreachable); updates `lastAttemptAt`, `attempts`, `totalPaid` (ETH only); emits `Attempt(robber indexed, token, to, amount, paid)` (paid == amount always). Views `prize()` (Sanctum ETH balance), `leakPerDay()` / `leakPerHour()` (read live `rules()` so admin tightening shows), `raidableNow()` (0 while frozen, else `capRoom(ETH)`). `topUp()` payable + `receive()` forward to the Sanctum and emit `TopUp(from, amount, prizeAfter)`; the key holds no ETH. `sweep(token)` → current `sanctum.cold()`. Not exposed: `executeQueued` (nothing can ever be queued through this key), `panic`, `cancel`, rules, keys. |
| `src/Sanctum.sol` | 470 | **One change, see finding 2:** rolling-day ring widened from 24 to 25 hourly buckets (`HourSlot[25]`, `h % 25`, `sl.hour + 25 > h`). Everything else untouched. |

## Finding 1 — `delayBps = 10000` does NOT disable the queue on its own

`Sanctum.withdraw` queues when `amount * 10_000 > bal * rules.delayBps || amount > capRoom(token)`. With `delayBps = 10000` the first clause is impossible (`amount ≤ bal` is already required), **but the second clause still queues anything above the hourly/daily room**, so a raw Sanctum with the §3.2 rules would park every over-cap raid in the queue (shown directly in `test_sanctum_alone_would_queue_above_caps`: `withdraw(capRoom + 1)` on the Sanctum returns queue id 0). Fix chosen: **BountySanctum-level guard** (`require(amount <= capRoom)` → `"over cap"`), plus `require(id == type(uint256).max)` as a belt-and-braces invariant, plus **no `executeQueued` passthrough** so even a queued item could never be released through the public key (the only other keys that can release are the cold key = admin). Not changed at the factory/Sanctum level: for a user's own Sanctum "never a dead end, always queue" is the product behaviour (SPEC §3.1) and the hot key proposing `delayBps` changes is tighten-only anyway. `rules.delay` is set to 24h (SPEC says "irrelevant"; it is, since nothing queues; 24h chosen so that if the admin ever rotated the hot key to an EOA the default would still be conservative).

## Finding 2 — the "rolling 24h" ring was 23–24 hours (fixed in `Sanctum.sol`)

The 48h robber simulation (`test_48h_two_robbers_interleaved_and_random_steps`, independent wall-clock ledger) extracted **2.3% of the base inside a strict 24h window**. Cause: `daySpentRolling` summed buckets with `sl.hour + 24 > h`, i.e. the current hour bucket plus the **23** before it. An outflow at hh:59 dropped out of the window 23h01m later; the worst alignment (raid at the last second of a bucket, raid again when the fixed hourly window reopens, raid again when the first bucket drops) lets **3 hourly caps = 3% leave within one wall-clock day** on a 1%/2% Sanctum (15% on the 5%/10% defaults). The code comment even said `(h-24, h]`, which the code did not do.

Fix: ring of **25** buckets, condition `sl.hour + 25 > h` → every outflow counts for **at least 24h** (24–25h depending on where in its hour it happened; conservative in the safe direction). Cost: one more storage slot per asset, one more iteration in `daySpentRolling`/`capRoom` (~2.1k gas). Two step-1 `Caps.t.sol` tests encoded the old aging (`t0 + 24 hours` → room reopens) and were moved to `t0 + 25 hours` with a comment; `CapsInvariant` / `DirectPathInvariant` measure in buckets and were unaffected. Regression test: `test_rolling_24h_is_strict_wall_clock`. **This changes behaviour of every user Sanctum (slightly tighter) — flag for the AUDIT-2 loop and the spec; if declined, revert the three hunks in `Sanctum.sol` and the two Caps test lines, and reword the bounty's rule to "2% per 24 bucket-hours (≤ 3% in any wall-clock day)".**

Related, documented not changed: the **hourly cap is a fixed window** that starts at the first spend, so two hourly caps can land seconds apart across a window boundary (1% at 00:59:59 and 1% at 01:00:00 after a 00:00:00 window start). The site's leak meter must quote the **daily** figure as the binding guarantee; `leakPerHour()` is informational.

## Tests — `test/Bounty.t.sol` (21, incl. 1 fuzz)

Independent ledger in the test (`outTs[]/outAmt[]`, strict wall-clock windows, `_try` asserts after every paid raid: rolling-24h outflow ≤ 2% × (prize now + outflow in window), single payout ≤ 1% of the prize it came from, failed raid pays nothing, `queueLength == 0` always).

- Wiring: rules 100/200/10000/24h/off, `watchersOn` false, 3 guardians / threshold 2, prize = seed, key holds 0, `leakPerDay/Hour`, `raidableNow`; constructor `addr` checks, >5 guardians rejected, 0 guardians allowed.
- Finding 1: raw Sanctum queues above caps; key reverts `"over cap"` at room+1, 10%, 100%, `uint256.max`; `"amount"` at 0; `"to"` for self; exactly `capRoom` pays; `executeQueued` selector absent; robber cannot `panic`/`cancel`/`proposeRules` through the key or on the Sanctum.
- 48h scripts: hourly max every hour (total ≈ 3–4% over 48h, > 3%, < 4% + dust), 50 tiny bursts per hour, cross-boundary double windows (24 × 2h), two robbers with random amounts/steps over 48h (paid iff inside room), deposits every 5h + top-ups every 7h for 48h, **fuzz** (16 raids × random amount up to 3× room × random gap ≤ 3h × robber).
- Finding 2 regression (strict wall-clock 24h).
- Freeze: guardian panic → `"frozen"` every hour for 24h (both tiny and full amounts), `raidableNow()` 0, resumes exactly at +24h; cold unfreeze resumes at once and mutes guardians (`"muted"`), cold itself can re-panic; cold can tighten (0.5%/1%) and the meter follows.
- Top-up via `topUp()` and plain transfer, `TopUp` event with prize-after, `"value"` on 0; FeeRouter-style push straight to the Sanctum; `Attempt` event + counters; `to` may be the robber; ERC-20 prize capped too and not counted in `totalPaid`; sweep to cold incl. after `setCold`.

## Deploy

The bounty deploy stage now lives in `script/DeployRaid.s.sol` (`STEP=bounty`, STEP 4), standalone on the product stack.

## Scripts (`scripts/`, viem 2.57, `package.json` + `node_modules` added to the project; `.gitignore` added)

`prove-sanctum.mjs` (241 l.) — step runner (signed tx saved before broadcast, resumable, `(done)` on rerun). `PK` from env (never stored), optional `GUARDIAN_PK`; chain 8453 enforced unless `ALLOW_FORK=1`; addresses from `DEPLOYMENT=deployments/base-raid.json`. `TARGET=bounty` (default): `topUp 0.01` → `withdraw capRoom` (paid) → `withdraw capRoom+1` **proven by `eth_call`** (`"over cap"`; a reverting tx cannot be mined on purpose, so this step carries block + reason, no hash) → `panic()` by guardian or cold → `eth_call` `"frozen"` → `unfreeze()` by cold (`UNFREEZE=0` to skip; note it mutes the bounty's guardians for 24h). `TARGET=fresh`: a new default-rules Sanctum (hot = cold = signer): 4% paid, 20% queued, panic voids, frozen, unfreeze. Writes `site/proof.json`.
```
node scripts/prove-sanctum.mjs                                   # look
PK=0x… GUARDIAN_PK=0x… node scripts/prove-sanctum.mjs go         # send
```
`raid-indexer.mjs` (149 l.) — read-only; `Attempt`/`TopUp` from the key and `Panic`/`Unfrozen`/`Deposited(ETH)` from the Sanctum, from `bountySeededBlock` (or `START_BLOCK`), `CHUNK=2000` blocks per `eth_getLogs`, incremental via `lastBlock` in the output, `RESCAN=1` for a full pass. Writes `site/raid.json`: live prize / leakPerDay / leakPerHour / raidableNow / spent24h / frozen / muted / rules / guardians, `totals` (contract counters + a `consistent` flag vs indexed events), `leaderboard` (ETH raids: rank, robber, extracted, attempts, first/last, lastTx, distinct destinations), `recent` 50 raids, `topUps`, `freezes`, full `events`.
```
node scripts/raid-indexer.mjs        # e.g. from cron every 5 min
```
Rehearsal note: anvil forks hang on `eth_getLogs` for pre-fork blocks (upstream proxy) — pass `START_BLOCK=<fork block>` there; irrelevant on mainnet Base.

## Interpretations

1. **Queue off = revert at the key, not at the factory** (finding 1): keeps `Sanctum`/`SanctumFactory` semantics for users intact.
2. **`totalPaid` counts ETH only**; ERC-20 raids are in events / `recent` but not ranked (the prize is ETH).
3. **`Attempt.paid` field kept** (task wording) even though it always equals `amount` — the site can read `paid` directly; queued/frozen attempts do not exist as events because they revert.
4. **`receive()` added to the key**: a payable destination that forwards is strictly more robust for FeeRouter pushes and for people who send ETH to the wrong address; `to != this` keeps raids from looping back.
5. **No guardians allowed at creation** (admin can `setGuardians` later from the cold key) so the deploy stage never blocks on an unset `BOUNTY_GUARDIANS`.
6. **Proof on the live bounty by default** (task sequence = bounty semantics); `TARGET=fresh` keeps a default-rules proof (queue shown) for the §7b proof section.
7. **Over-cap and frozen reverts proven by `eth_call`**; `proof.json` marks those steps `call: true`.

## Known limits (for the site)

- Fixed hourly window ⇒ up to two hourly caps can leave within seconds across a window boundary; the daily rolling cap (now ≥ 24h) is the guarantee to publish.
- Running the proof's `unfreeze` on the live bounty mutes its guardians for 24h — do it right after seeding, before announcing the raid.
- `leakPerDay()` is 2% of the *current* prize; the exact daily room is `(prize + spent24h) × 2% − spent24h` (`raidableNow()` / `capRoom`).
- The cold key (admin) can still `coldWithdraw` under the caps, rotate the hot key, or tighten rules — all on-chain events, all visible; the site should list them.
