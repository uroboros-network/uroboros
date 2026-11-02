# Uroboros — AUDIT-2 (step 2)

> Token-stack findings removed; this repo contains the Sanctum product only.

Date: 2 Nov 2026 · Original scope: the step-2 token launch stack plus `src/Subscription.sol` and `src/SanctumFactory.sol`. The token stack was abandoned and is not in this repo; every finding about it (H1, H1b, H2, M1–M3, L1, L1b, L3, I1–I5, I7–I9, the tokenomics, v4 accounting, gas and launch-script sections) has been removed. What remains are the findings on the Sanctum product contracts.

PoC: `test/Audit2.t.sol` (`Audit2SubscriptionTest`). It was written as a `_BUG_` test against the property the code should have, failed on the step-2 code, and passes since STEP2-FIXES (renamed `_FIXED_`).

---

## Findings (product)

### LOW

#### L2 — subscription trial is a flash check; `createWithRules` lets the $100 leave in the same block
- **Location:** `Subscription.register` 73-83; `SanctumFactory.createWithRules` 45-59; `Sanctum._checkRules` (caps up to 100%).
- **Issue:** Create with `capBps = dayCapBps = 10000`, fund $100, trial starts, `coldWithdraw` 100% immediately, repeat: one $100 note = unlimited 7-day trials. AUDIT-1 S1 "one trial per cold key / TVL for 24 h" is not implemented (STEP2 §7 says so). Worthless today (nobody pays for coverage of an empty Sanctum), relevant when WorkRewards/watchers read `coveredUntil`.
- **PoC:** `test_BUG_L2_trial_recycled_with_custom_rules`.
- **Fix:** `trialUsed[cold]` in `Subscription` (factory passes `cold`), or trial only for the factory's default rules, or both.
- **Status:** FIXED (STEP2-FIXES): the trial is granted only to Sanctums created with the factory's default rules; `createWithRules` registers without a trial. Re-checked in AUDIT-3 L3, which documents a remaining bypass.

### INFO

- **I6 — `Subscription.payUsdc`:** `PRICE_USDC = 5e6` is correct for Base USDC (6 decimals); `usdc` is immutable so the deploy must pass `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (now done by `script/DeployProduct.s.sol`); `_usdValueOfEth` 18-decimal maths checked.
