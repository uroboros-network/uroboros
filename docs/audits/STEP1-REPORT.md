# Sanctum — Step 1 report

> Token-stack findings removed; this repo contains the Sanctum product only.

Date: 2 Nov 2026 · Scope: SPEC §7 step 1 only (`Sanctum`, guardians + recovery, `SanctumFactory`, `Sanctum7702`, `Subscription`). No deploy scripts, no site, no token.
Toolchain: forge 1.7.1, solc 0.8.28, evm `prague`, `lib/` = OpenZeppelin + forge-std.

Result (at the time, incl. 4 LPLocker tests since removed with the token stack): **`forge test` → 100 passed, 0 failed, 0 skipped** (11 suites, 4.3 s). No fork tests needed; nothing in step 1 touches a live chain.

## Contracts (`src/`)

| File | Lines | Status |
|---|---|---|
| `Sanctum.sol` | 467 | Caps, queue, panic + guardians, recovery, `watchersOn`, queued-transfer fee, `IWatcherRegistry`. |
| `SanctumFactory.sol` | 56 | `create(cold, guardians[], threshold)`, `createWithRules(...)`, default rules 5%/h · 10%/24h · queue >10% for 6h · no allowlist; immutable `blacklist`, `watcherRegistry` (may be 0), `feeRouter`, `subscription`; registers each Sanctum (trial start); `isSanctum`, `sanctumsOf`, `count`. |
| `Subscription.sol` | 100 | $5/month in ETH via a Chainlink AggregatorV3 (constructor arg; Base ETH/USD `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` at deploy), 14-day trial on `register` (factory only, one-shot `setFactory`), `coveredUntil` / `isCovered` views, `pay(sanctum, months)` payable with refund, 24h staleness + `answer > 0` check, forwards price to `feeRouter`. Never referenced by `Sanctum`. |
| `Sanctum7702.sol` | 91 | EIP-7702 delegate; namespace `sanctum.7702.storage`, slot `0xa03061a946d8080ed95c98169f3ff203def10761cbfa5ea84a832ad996cabe00` (ERC-7201, asserted in test and checked against `vm.load`). |
| `Blacklist.sol` | 29 | Owner + oracle flagged destinations. |

Base vault behaviour in `Sanctum.sol`: `withdraw` / `executeQueued` gating (done, voided-by-panic, needs-cold-approval, waiting, destination checks), `coldWithdraw`, `approveQueued`, `cancel`, `panic` 24h / sticky last-hour / 24h mute after cold unfreeze, `rulesReadyAt = 0` on panic, `proposeRules` / `applyRules` / `coldSetRules` tighten-only with `MIN_RULES_DELAY = 3 days`, `_spendWindow` fixed hourly window + rolling 24-bucket ring, `capRoom`, `daySpentRolling`, `_checkDestination`, `requireApproval` flag.

New in `Sanctum.sol`:
- Guardians: `guardians[]`, `isGuardian`, `MAX_GUARDIANS = 5`, `threshold`, `setGuardians(address[], uint8)` (cold; replaces the whole set; 0 = default threshold = 2 if ≥3 else all; rejects >5, zero address, duplicates, threshold > n or threshold ≠ 0 with an empty set), `GuardiansSet` event. Any guardian may `panic()` under the node rules; `GuardianPanic(sanctum, guardian)`.
- Recovery: `proposeCold(newCold)` by guardians, votes counted per `(recoveryEpoch, candidate)`, duplicate vote per guardian rejected, the `threshold`-th vote sets `proposedCold` and `recoveryReadyAt = now + 7 days` (`RECOVERY_DELAY`), `cancelRecovery()` cold any time, `executeRecovery()` anyone after the timer (emits `ColdSet` + `RecoveryExecuted`). One recovery active at a time (`"recovery active"`). `setGuardians` and `setCold` void a running recovery and forget all votes (epoch bump).
- `watchersOn` (cold, default false) + `IWatcherRegistry.isWatcher`; a watcher panic shares the guardian mute/last-hour rules and emits `WatcherPanic`. A guardian who is also a watcher is attributed as a guardian.
- Fee: `FEE_BPS = 25` constant, `feeRouter` immutable (non-zero required), applied only in `executeQueued`: `fee = amount * 25 / 10_000` sent first to `feeRouter` in the same asset (`Sent` + `QueuedFee` events), recipient gets `amount - fee`. `withdraw` (direct) and `coldWithdraw` pay nothing.

## Tests (`test/`, 100 tests)

| File | Tests | Content |
|---|---|---|
| `Fixture.sol` | — | `MockAggregator` (8 dec), `MockWatcherRegistry`, `FeeSink`, `RejectingSink`, `MockERC20`; deploys Blacklist → FeeSink → feed → registry → Subscription → Factory → `setFactory`. |
| `SanctumCore.t.sol` | 16 + 2 inv | Tighten-only fuzz + per-field reasons, re-check after cold tightening, guardian **and** watcher sticky-freeze fuzz, owner/cold re-panic, panic voids queue fuzz, cold approvals in mute window, setter events, registry opt-out, cold-only setters, blacklist/allowlist destinations, `DirectPathInvariant` (rolling day cap, no queue execution). |
| `Caps.t.sol` | 15 | Factory defaults + `createWithRules`, daily cap sequence, day-cap tighten-only, cold-raised cap bound by day cap, queue skips caps (now minus fee), queue voided by panic, execute balance/single-use/role, 7% case, `capRoom` boundaries, `capRoom` never lies fuzz, over-cap queue voided, rolling no double-dip, hot cannot shorten delay, ERC-20 caps independent of ETH. |
| `Audit.t.sol` | 4 | Guardian cannot re-freeze after cold unfreeze, slow hot-key rule change + panic cancels, frozen blocks every outflow but not cold admin, sweep leaves gas reserve + NFT receipt (local `signAndAttachDelegation`, no fork). |
| `Guardians.t.sol` | 24 | Guardian panic attribution, no standing, keys-only Sanctum, 24h mute for the whole set, last-hour re-panic boundaries, attribution log stream; default thresholds, set bounds (max 5 / zero / duplicate / threshold, at factory and setter), whole-set replace + clear; recovery happy path 2-of-3 with events and old-cold lock-out, threshold enforcement, duplicate vote, voter/candidate checks, cancel forgets votes, cancel while frozen + guardian purge, one-active-at-a-time, set-change and `setCold` void recovery, all-of-one, timer fuzz; `watchersOn` gating + deregistration + off switch, no-registry no-op, watcher mute/last-hour, guardian-also-watcher attribution. |
| `Fee.t.sol` | 10 | Constant, exact ETH fee (0.1 ETH on 40 ETH) with event order, exact ERC-20 fee, fee conservation fuzz, floor-to-zero case, direct and cold withdrawals pay nothing (ETH + ERC-20), cold release still pays, rejecting router blocks only the ETH queue, fee router / factory constructor checks. |
| `Subscription.t.sol` | 13 | Trial at creation, factory-only idempotent register, one-shot `setFactory`, price from feed, pay extends from trial end and forwards ETH, refund, underpaid / months / zero-sanctum reverts, lapsed → from now, anyone pays for any address, stale/future/non-positive feed reverts `pay` but not coverage views, unpaid Sanctum keeps working, constructor checks, pay-math fuzz. |
| `Sanctum7702.t.sol` | 5 | ERC-7201 slot (formula vs constant vs `vm.load`, low byte 0), init rules, sweep reserve + ERC-20, `execute` only-self / only-vault / return data / failing call / panic through delegate, ERC-721/1155 receivers. |
| `Invariants.t.sol` | 7 inv | `CapsInvariant`: hot + cold direct paths on ETH and ERC-20 with deposits — rolling-24h outflow ≤ 10% per asset, in-window hourly outflow ≤ 5% per asset, queue never executed. `FreezeInvariant`: withdraws, cold withdraws, queue releases, approvals, owner/cold/guardian panics, unfreezes — outflow while `frozenUntil` is in the future is zero; no item queued at or before the last panic is ever released. `RecoveryInvariant`: random votes for two candidates, cancels, executes — an executed recovery is ≥ 7 days after its threshold vote; an active timer is always `start + 7 days`; cold is always a known key. |


## Interpretations (spec silent or ambiguous)

1. **One recovery at a time.** SPEC §3.1 does not say what happens when guardians vote for two candidates. Votes are counted per candidate; once a candidate reaches `threshold` the timer runs and no more votes are accepted until cancel/execute. Reasoning: letting a second candidate reset the first would hand one rogue guardian a veto; letting two run in parallel makes "cancel" ambiguous.
2. **Votes are forgotten on `setGuardians` and `setCold`** (epoch bump). A removed guardian's vote must not keep counting; a cold key that rotates itself is proof the cold key is alive, so a pending recovery against it is voided.
3. **Recovery executes even while frozen.** The new cold key then unfreezes. Freezing does not block admin paths.
4. **`proposeCold` rejects `newCold == cold`** (a no-op recovery would only burn the 7 days) and `address(0)`.
5. **Threshold argument 0 = default** at both factory and setter; an explicit value in `1..n` is honoured, so a user may ask for 1-of-5 or 5-of-5.
6. **Fee rounding:** floor; a queued transfer under 400 wei pays no fee. Recipient + router always sum to the gross amount (fuzzed).
7. **Fee is paid when the cold key releases the queue too** — spec says "any executed queued transfer".
8. **`feeRouter` must be non-zero** at construction; the factory also requires non-zero `feeRouter` and `subscription`. `watcherRegistry` may be zero (spec).
9. **Subscription registration permission:** `register` is factory-only, bound once by the deployer via `setFactory` (deploy order: Subscription → Factory → `setFactory`). A direct `new Sanctum(...)` gets no trial but anyone may still `pay` for it. `pay` is open to any payer for any address (a friend or DAO can cover a Sanctum).
10. **Month = 30 days, max 120 months per call, price quoted at the payment block** (no TWAP). Staleness bound is `updatedAt ≤ now` and `now − updatedAt ≤ 24h`; exactly 24h old is accepted.
11. **Guardians and watchers share one mute window** (`guardianMutedUntil`), matching §3.4 "same sticky/mute rules as guardians".
12. **"Chainlink pricing lib"** (SPEC §7 step 1): pricing is a 4-line formula inside `Subscription` (`PRICE_USD × 10^dec / answer`). With one consumer a library would be ceremony; when `WatcherRegistry` (step 5) needs the same maths, lift it into `lib/UsdPrice.sol` then.
13. **"7702 sweep on a Base fork"** (SPEC §7 step 1 gate): tested locally with `vm.signAndAttachDelegation` under `prague`; the task said no fork tests in step 1. A Base-fork run of `Sanctum7702Test` belongs in the step 2 rehearsal.

## Spec inconsistencies found

- SPEC §8 still prices subscriptions at "$2" while §3.1 and §9.3 say $5. Code uses $5 (`PRICE_USD = 5e18`).
- `AUDIT-1.md` (a spec-level audit that appeared in the folder during this step, "no code reviewed") proposes changes that touch step 1 and are **not** in the approved SPEC, so they were not implemented: S5 auto-freeze while a recovery is pending and any cold tx implicitly cancelling it; S1/A11 trial only for Sanctums with ≥ $100 TVL, 7 days, one per cold key, USDC payment option, annual plan. Each is a small change to `Sanctum.sol` / `Subscription.sol` if approved; all would need new tests and the `RecoveryInvariant` handler updated (cold `setCold` already cancels).

## Known limits (honest, for the site later)

- A fee router that rejects ETH blocks ETH queue releases on every Sanctum pointing at it (tested). The fee destination must be a plain payable contract with no revert path on receive; ERC-20 releases are unaffected; `coldWithdraw` under caps always works.
- Two colluding guardians at threshold 2 can keep re-proposing a cold key after each cancel. The cold key's defence is `setGuardians` (shrink the set); a lost cold key plus colluding guardians is a lost Sanctum. A hot key keeps its capped 10%/day during the 7-day timer unless someone panics.
- Watchers are gated only by `IWatcherRegistry.isWatcher`; the registry's own economics (bond, slash, reputation) are step 5. `requireApproval` is advisory.
- Subscription is a ledger only; coverage has no on-chain effect until the watcher market reads it (step 5).
- `Sanctum7702` cannot stop a compromised key from re-delegating (inherent EIP-7702 limit).
- Lint: forge emits `block-timestamp` / `unsafe-typecast` notes (casts are bounded: `uint64` timestamps, `uint192` amounts per hour bucket).
