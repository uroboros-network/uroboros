# Uroboros — STEP3-FIXES-2 (recovery switch)

> Token-stack findings removed; this repo contains the Sanctum product only.

Date: 2 Nov 2026. Applies the decision on the recovery gap left open in STEP3-FIXES §3: **a recovery on/off switch in the Sanctum, switched off for good on the bounty Sanctum**. Token-stack items in the original report (treasury tranches, token deploy script, token rehearsal, site and launch-checklist work) are removed.

---

## 1. Recovery on/off switch (`src/Sanctum.sol`)
- `bool public recoveryOff` (default `false`: every personal Sanctum keeps guardian recovery on, unchanged).
- `setRecoveryOff(bool off)` — `onlyCold`, emits `RecoveryOffSet(off)`. Switching it **on** (`off = true`) cancels any running recovery and forgets every pending vote (`_clearRecovery()`: `proposedCold = 0`, `recoveryReadyAt = 0`, `recoveryEpoch++`); if a recovery was running it also emits `RecoveryCancelled(cold)`. Switching it back off (`false`) does not revive old votes (new epoch).
- `proposeCold` starts with `require(!recoveryOff, "recovery off")`. With no running recovery, `executeRecovery` reverts `"no recovery"`; `cancelRecovery` keeps its behaviour.
- Nothing else in `Sanctum.sol` changed (caps, queue, panic, guardians' freeze, rules, fee, events). NatSpec line added under "Recovery".

## 2. BountyCold (`src/BountyCold.sol`)
- Constructor: right after deploying the `BountySanctum` and checking the keys, `sanctum.setRecoveryOff(true)`. The Sanctum's `RecoveryOffSet(true)` is in the creation transaction.
- No function on BountyCold calls `setRecoveryOff` again, there is no generic call/fallback, and only the cold key (BountyCold) may call it on the Sanctum, so it can never be switched back on.
- **`cancelRecovery()` removed** (my choice): with recovery off a recovery can never start, so the public cancel was dead code that the site and indexer would keep explaining. Removing it also removes the "watcher must cancel within 7 days" duty from STEP3-FIXES §6. NatSpec updated (exposed: panic / unfreeze / setGuardians; absent list now includes `setRecoveryOff` and `cancelRecovery`).
- `src/BountySanctum.sol`: one NatSpec line updated (no code change).
- Deploy `STEP=bounty`: `require(sanctum.recoveryOff(), …)` after the wiring check; `STEP=status` prints `bountySanctum.recoveryOff`.
- **Result:** the step-3 residual (an uncancelled 7-day guardian recovery replacing BountyCold) is closed. The bounty's cold key is BountyCold forever; its guardians can only freeze.

## 3. Tests (`test/Audit3.t.sol`)
New `test_FIXED_recovery_off_*`:
- Personal Sanctum (`Audit3SanctumTest`): `_default_on_and_cold_only_switch` (default on; hot key, guardian and stranger get `"cold"`; cold switches on and off with events; back on → a recovery can run again), `_proposeCold_reverts` (every caller `"recovery off"`, no votes recorded, nothing to execute after 8 days, guardians still panic), `_switching_on_cancels_running_recovery` (running recovery at day 6 → `RecoveryCancelled` + `RecoveryOffSet`, readyAt/proposed cleared, epoch bumped, nothing executes at day 8; old votes do not count after switching back), `_switching_on_with_nothing_running` (only `RecoveryOffSet`, pending vote forgotten).
- Bounty (`Audit3BountyColdTest`): `_bounty_from_construction` (recoveryOff true, guardians revert, nothing to execute, a new guardian set does not turn it back, dev, guardian and robber get `"cold"` on `setRecoveryOff(false)`), `_bounty_gap_closed`, `_bounty_event_in_creation_tx` (`RecoveryOffSet(true)` emitted by the Sanctum in the BountyCold creation tx).
- Invariant extended: the BountyCold handler no longer models a watcher cancelling recoveries (warps up to 8 days at once), drops its `cancelRecovery` action and adds `tryRecovery` (every actor tries `setRecoveryOff(false)`, `executeRecovery`, `cancelRecovery` directly on the Sanctum; any success fails the run). `invariant_FIXED_M1_rules_and_keys_never_change` now also asserts `recoveryOff`, `recoveryReadyAt == 0`, `proposedCold == 0`; new `invariant_FIXED_recovery_off_bounty_never_back_on`. 256 runs × 500 calls each, 0 reverts.
- `test_FIXED_M1_no_fund_moving_selector_on_bountyCold`: 19 selectors now (adds `setRecoveryOff(false)`, `setRecoveryOff(true)`, `cancelRecovery()`).
- Removed (superseded): `test_FIXED_M1_guardian_recovery_cancellable_by_anyone`, `test_FIXED_M1_residual_uncancelled_recovery_replaces_cold`.
