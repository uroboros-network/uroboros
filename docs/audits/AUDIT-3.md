# Uroboros — AUDIT-3 (pre-launch, after step 3)

> Token-stack findings removed; this repo contains the Sanctum product only.

Date: 2 Nov 2026 · Original scope: all of `src/` as one system, including the token launch stack that was later abandoned. This copy keeps only what concerns the Sanctum product (Sanctum, SanctumFactory, Sanctum7702, Subscription, Blacklist, BountySanctum). Removed: AUDIT-2 token fixes re-verification, M2 (fee splits), L5 (token deploy script), I4–I9, I12–I13, the token/fee disclosures and the token-stack rehearsal. PoCs and proofs: `test/Audit3.t.sol` (a finding test asserts the behaviour that existed at audit time, a `_verify_` test pins a fix or a proof; tests for findings fixed later were flipped to `_FIXED_`).

`FOUNDRY_FUZZ_RUNS=3000 forge test --match-test testFuzz_A3` → 2 × 3000 runs green (rolling-24h strict-window proof, §2).

---

## 0. Verdict (product)

The 25-bucket rolling day is a real strict-24h bound: proven on paper (§2) and by a 6,000-run fuzz that checks every window ending at every payout. No High findings. No path moves value without the guard/CEI it needs.

What remained at audit time was **trust and wording**, not broken maths: the bounty's cold key (then a dev EOA) was not "tighten-only" — it could take the whole prize in one block, and the contract's own NatSpec said otherwise (M1); and a griefer could lock the raid game and fake the leaderboard by raiding into the Sanctum itself (L1).

Status since: M1 fixed by `BountyCold` (the bounty's cold key is a locker that can only panic, unfreeze and set guardians; recovery is off for good; STEP3-FIXES, STEP3-FIXES-2). L1 and L2 fixed in `BountySanctum` (only destination is the bounty Sanctum, ETH only; STEP 4 redesign). L4 fixed (`Ownable2Step` on Blacklist).

---

## 1. Value paths — checked in code

| Item | What the code does | Checked how | Status |
|---|---|---|---|
| Every ETH-pushing path (system-wide) | Sanctum `_send` from `withdraw`/`coldWithdraw` (window/bucket state written before the call) and `executeQueued` (`done = true` before both sends; fee goes to the fee collector whose `receive` is storage-only) · Subscription `pay` (ledger before router + refund) · BountySanctum `_topUp` (forward only) · Sanctum7702 `sweep` (to the vault). | Read + `test_A3_L2_fake_token_events_and_reentry_respect_caps` (a token's `transfer` re-enters the bounty key mid-withdraw: exactly one ETH room paid, the second re-entrant raid fails). | ✓ no unguarded value path. BountySanctum updates its counters after the external call (cosmetic only). |
| L2 trial | `createWithRules` → no trial. | `test_A3_L3_trial_recycled_same_block_via_coldSetRules` — **bypassed** (L3). | ✗ (no value at stake until the watcher market) |

---

## 2. Sanctum rolling 24h (25 buckets) — proof and worst cases

**Claim.** For any strict window W = (T, T+24h], outflow through the capped paths (`withdraw` direct, `coldWithdraw`) in W ≤ `dayCapBps` × (balance at T + deposits in W).

**Proof.** An outflow at time t sits in bucket H = ⌊t/3600⌋ and is counted while `H + 25 > h_now`, i.e. until h_now = H+25, which is ≥ t + 24h + (3600 − t mod 3600) > t + 24h. So at any payout at time E ∈ W, every earlier payout in W is inside `spent24`, plus possibly older ones (O_pre ≥ 0). The check is `spent24 + a ≤ (bal + spent24)·d` with bal = B_T − O_in + D_in (balance before the send). Substituting: O_in + a ≤ (B_T + D_in)·d − O_pre·(1−d) ≤ (B_T + D_in)·d, since d ≤ 1. ∎ (Queued releases and the queue fee do not touch buckets — they are the delayed, cancellable path.)

**Test.** `testFuzz_A3_verify_rolling24h_strict_window_default` (5/10) and `..._bounty_rules` (1/2): 40 steps per run, time steps aimed at hour boundaries (−1 s, exact, +1 s), short hops and gaps up to 3 h, random deposits 1–21 ETH, raid sizes 0–149% of `capRoom` (over-cap must revert, inside must pay); after every payout the test checks **every** window ending now that starts at now−24h or at any event inside it, against an independent ledger. 3,000 runs each: no violation.

**Fixed hourly window (documented, kept).** The hourly window starts at the first spend after expiry, so two hourly caps can land one second apart. A sliding 60-min interval can touch at most two windows (window k+2 starts ≥ 2 h after window k).

| Rules | Worst 1 h (two caps 1 s apart) | Then | Worst strict 24 h | PoC |
|---|---|---|---|---|
| Default 5%/h · 10%/24h | 5% + 4.75% = **9.75%** | 0.25% more in the next hour, then nothing until the buckets age out (24–25 h) | **10%** of (balance at window start + deposits) | `test_A3_I1_hourly_double_raid_default_quantified` |
| Bounty 1%/h · 2%/24h | 1% + 0.99% = **1.99%** (0.00995 ETH of 0.5) | 0.01% next hour | **2%** of (prize at window start + top-ups) | `test_A3_I1_hourly_double_raid_bounty_quantified` |

So on a default Sanctum a stolen hot key gets ~10% within seconds and nothing more for ~24 h — the 1-hour cap does not buy reaction time; the daily cap and the queue do. Over 48 h the bound is ≤ 2 × daily (≈ 19% default, ≈ 4% bounty, compounding on the shrinking balance).

---

## 3. Findings (product)

Severity = impact × likelihood at launch size (0.5 ETH bounty).

### MEDIUM

#### M1 — Bounty cold key (dev EOA) can loosen the rules and take the whole prize in one block; the code says it can only tighten
- **Where:** `Sanctum.coldSetRules` (`Sanctum.sol:366-371`, no tighten-only check, applies at once), `coldWithdraw`, `setOwner`; `BountySanctum.sol:21` NatSpec "cold = admin can only tighten them further"; STEP3-REPORT limits "or tighten rules".
- **Issue:** `coldSetRules(100%, 100%, …)` + `coldWithdraw(prize)` empties the bounty in one block, including every fee top-up. The same key can `setOwner` (hijack the public hot key) or `unfreeze` a guardian freeze first. This is the spec's trust model (cold = admin), but the verified source will tell readers the opposite, and the "raid" prize is custodial: the 10% bounty share of fees flows into a vault one EOA can empty.
- **PoC:** `test_A3_M1_bounty_cold_loosens_rules_and_takes_prize_in_one_block` (3.5 ETH prize → 0 in one prank block).
- **Fix:** before deploy, correct the NatSpec ("the cold key (admin) can change or loosen the rules, rotate the key and withdraw the prize at any time"). Optional hardening: bounty cold = the Safe (not the dev EOA) from day 0 — `BOUNTY_COLD` env already exists. Disclose (§5).
- **Status:** FIXED — bounty cold key = `BountyCold` (`src/BountyCold.sol`).

### LOW

#### L1 — Self-loop raid (`to = sanctum`) burns the cap room, locks honest raiders out, and fakes the leaderboard
- **Where:** `BountySanctum.withdraw` checks `to != address(this)` but not `to != address(sanctum)`.
- **Issue:** sending the raid back into the Sanctum spends hourly/daily room without moving the prize. One griefer, a few txs per hour (cents on Base), keeps `raidableNow()` at 0 for everyone else indefinitely, and `totalPaid` / `Attempt` / the indexer's leaderboard count it as loot. (Self-loops do not lower the balance, so each re-opens 2% of itself as day room; the griefer mops it up in a few calls.)
- **PoC:** `test_A3_L1_self_loop_raid_burns_caps_and_fakes_leaderboard` — 24 h of self-loops: prize unchanged, `totalPaid` ≈ 0.0102 ETH "extracted", honest `withdraw(1 gwei)` → "over cap" every hour.
- **Fix (BountySanctum is not deployed yet — do it):** `require(to != address(this) && to != address(sanctum), "to");`. Indexer: ignore `to == sanctum` regardless.

#### L2 — Arbitrary "token" addresses: fake `Attempt` / `Sent` amounts and inflated `attempts`
- **Where:** `BountySanctum.withdraw(token, …)` accepts any address; `Sanctum.capRoom/withdraw` call its `balanceOf`/`transfer`.
- **Issue:** a contract returning `balanceOf = 1e30` and a no-op `transfer` produces `Attempt(robber, fake, …, 1e28, 1e28)` and `Sent` events and bumps `attempts`. Its `transfer` can re-enter the key; the ETH caps still hold (verified). No value at risk; the leaderboard/feed is.
- **PoC:** `test_A3_L2_fake_token_events_and_reentry_respect_caps`.
- **Fix:** in BountySanctum `require(token == ETH)` (the spec's prize is ETH; stray ERC-20s already go to `sweep`), or count `attempts` only for ETH. Indexer: rank and display ETH only.

#### L3 — Trial gate bypassed: one $100 deposit gets a fresh 7-day trial every tx (AUDIT-2 L2 fix incomplete)
- **Where:** `SanctumFactory.create` (trialEligible = true) + `Sanctum.coldSetRules` (instant loosening) + `coldWithdraw`.
- **Issue:** create with default rules and $120 → trial; same block: cold loosens to 100% and withdraws everything; repeat. The comment in `Subscription.sol` ("one trial per ~6 h") is wrong — it is one per tx.
- **PoC:** `test_A3_L3_trial_recycled_same_block_via_coldSetRules` (5 trials, $120, one block).
- **Fix:** not needed for launch (coverage has no on-chain value until step 5). Before the watcher market: `trialUsed[creator]` and/or watchers/WorkRewards read TVL at freeze time with a minimum age, never `coveredUntil` alone. Fix the comment.

#### L4 — Single-step `Ownable` on Blacklist
- **Issue:** a hand-over `transferOwnership` is irreversible on a typo or a wrong-chain address.
- **Fix:** `Ownable2Step`. **Status:** FIXED (`test_FIXED_L4_blacklist_two_step_ownership`).

### INFO

- **I1 — hourly fixed window** quantified in §2 (default 9.75%/1 s, bounty 1.99%/1 s; daily caps exact).
- **I2 — the cold key is the master key on every Sanctum.** A stolen cold key unfreezes, loosens and withdraws everything in one tx; guardians are then muted 24 h and could not have stopped it. `test_A3_I2_stolen_cold_key_drains_frozen_sanctum_in_one_tx`. (Spec-consistent; must be on the site.)
- **I3 — admin-chosen guardians can freeze the bounty indefinitely** (re-panic in the last hour, rotating): `test_A3_I3_guardians_can_freeze_bounty_indefinitely` (6 days at 0). Only the cold key unfreezes (and that mutes the guardians 24 h).
- **I10 — recovery leaves the old hot key in place** (`test_A3_verify_recovery_executes_while_frozen_hot_key_survives`); the new cold key must `setOwner`. Recovery executes while frozen (spec). Colluding guardians can re-propose after every cancel; the cold key must answer within each 7-day timer, then shrink the set (`test_A3_verify_colluding_guardians_loop_until_set_shrinks`). `watchersOn` with a zero registry is a no-op ("standing") — verified.
- **I11 — no-queue property holds even if the admin sets `delayBps < capBps`**: the raid reverts "queued" and the push is rolled back (`test_A3_verify_no_queue_even_with_low_delayBps`). No `executeQueued` passthrough exists. `topUp`/`receive` forward at once; `sweep` sends ERC-20s to the *current* cold key; force-sent ETH (selfdestruct) would be stuck in the key (negligible).

---

## 4. Cross-contract notes

- **Subscription → fee collector:** `pay` sends ETH to a storage-only `receive` that never reverts ✓; `payUsdc` transfers USDC to it.
- **Factory → Subscription:** `register` is factory-only, one-shot `setFactory` by the Subscription deployer; the deploy script binds it. Bounty Sanctum registered without trial (`coveredUntil = 0`) ✓.
- **address(0)/no-code assumptions:** Sanctum blacklist 0 = off ✓; factory `watcherRegistry` 0 ✓; Subscription/Factory constructors reject 0 where it matters ✓.

---

## 5. Site disclosures — exact sentences (product)

**Sanctum (every user vault)**
1. "A stolen hot key can move at most 5% per hour and 10% per rolling 24 hours of each asset; anything larger waits 6 hours in a queue your cold key can cancel."
2. "The hourly limit is a fixed one-hour window, so up to 9.75% can leave within a few seconds across a window boundary. The binding guarantee is 10% per rolling 24 hours."
3. "Your cold key is the master key. Whoever holds it can unfreeze, change every rule and withdraw everything in a single transaction. Guardians cannot stop a stolen cold key. Keep it offline."
4. "Guardians can freeze your Sanctum for 24 hours and, by threshold vote, start a 7-day cold-key recovery that your cold key can cancel. Guardians acting together can keep proposing again after each cancel. If that happens, remove them with your cold key."
5. "After a recovery the old hot key is still set. The new cold key must replace it."
6. "Queued transfers pay a 0.25% fee to the fee collector. Direct capped withdrawals and cold-key withdrawals are free."
7. "The free trial is a bookkeeping entry only. It gives no protection on chain, and coverage has no on-chain effect until the watcher market launches."

**Raid the Sanctum (bounty)**
8. "The prize sits in a real Sanctum: 1% per hour and 2% per rolling 24 hours can be raided by anyone. Up to 1.99% can go in two transactions a few seconds apart. Anything above the caps reverts. Nothing is ever queued."
9. "The bounty's cold key is the team's admin key (`<address>`). It can change or loosen the rules, replace the public key and withdraw the whole prize at any time. Every such action is an on-chain event and is listed here."
10. "The admin-chosen guardians (`<addresses>`) can freeze the game for 24 hours at a time and can renew the freeze. While it is frozen nobody can raid."
12. "Raids are first come, first served. Bots will compete for each hour's room."
13. "Leaderboard: ETH raids to outside addresses only." (and L1/L2 fixed or filtered in the indexer)
22. "No external audit. The bounty Sanctum is the live test."
