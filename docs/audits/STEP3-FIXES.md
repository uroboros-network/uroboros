# Uroboros — STEP3-FIXES (AUDIT-3 applied)

> Token-stack findings removed; this repo contains the Sanctum product only.

Date: 2 Nov 2026 · Applies AUDIT-3 L1, L2, M1 (wording + decision: BountyCold locker) and L4. Token-stack items (M2 fee destinations, L5 token deploy script, FeeRouter/MinterProxy ownership) are not part of this repo and were removed from this report. Not changed: L3 (trial gate, deferred to before the watcher market), `Sanctum.sol`, `SanctumFactory.sol`.

---

## 1. BountySanctum — L1, L2, M1 wording (`src/BountySanctum.sol`)
- `withdraw`: `require(token == ETH, "eth only")` first (before any call to `token`), then `require(to != address(this) && to != address(sanctum), "to")`. ABI unchanged (`withdraw(address token, address to, uint256 amount)`, `Attempt` event unchanged) so `scripts/*.mjs` and the indexer keep working; `totalPaid` now counts every raid (all ETH). `sweep` unchanged (stray ERC-20s → current `sanctum.cold()`).
- NatSpec: the "cold = admin can only tighten" claim is gone. It now says plainly that whoever holds the cold key can change/loosen rules, withdraw the whole prize, replace the hot key, unfreeze and change guardians; and that in production the cold key is `BountyCold` (§3), where none of that is reachable.
- Tests: `Audit3` `test_A3_L1_*` / `test_A3_L2_*` (PoCs) → `test_FIXED_L1_self_loop_raid_rejected`, `test_FIXED_L2_fake_token_rejected_eth_only` (no events, no attempts, token never called, room intact), `test_FIXED_L2_sweep_still_sends_stray_erc20_to_cold`. `Bounty.t.sol`: `test_erc20_prize_is_capped_too` → `test_erc20_raids_rejected_eth_only`; `test_cold_can_tighten_but_not_loosen_the_game` renamed `test_cold_can_tighten_the_game` (the old name claimed something the code never enforced). `test_A3_M1_*` kept: it now documents why an EOA cold key is unacceptable.

## 2. L4 — two-step ownership (`src/Blacklist.sol`)
- `Ownable` → `Ownable2Step` (OZ, same constructor `Ownable(owner)`). `transferOwnership` only nominates; the nominee must `acceptOwnership()`.
- Test: `test_FIXED_L4_blacklist_two_step_ownership` (nomination moves nothing, typo re-nominated, wrong nominee cannot accept, old owner keeps rights until acceptance and loses them after).

## 3. M1 — bounty cold key = locker (`src/BountyCold.sol`, new, 55 lines)
- `BountyCold is Ownable2Step`. Its **constructor deploys the `BountySanctum`** with `cold = address(this)` (so the Sanctum's cold key is the locker from the first block, no bind step, no unbound window) and forwards `msg.value` as the prize; asserts `sanctum.cold() == this && sanctum.owner() == bounty`.
- Exposed: `panic`, `unfreeze`, `setGuardians` (onlyOwner; owner = dev key → Safe, two-step). **Added beyond the brief:** `cancelRecovery()` callable by **anyone** — without it, guardians (which the owner chooses) could vote a new cold key and, after 7 days, that key would have full cold powers. `renounceOwnership` reverts (an ownerless locker could never end a freeze).
- Absent (no generic call/delegatecall, no fallback, no receive): `withdraw`, `coldWithdraw`, `coldSetRules`, `proposeRules`/`applyRules`, `setAllowlist`, `setOwner`, `setCold`, `setBlacklist`, `setWatcherRegistry`/`setWatchersOn`, `setRequireApproval`, `approveQueued`, `executeQueued`, `cancel`.
- Tests (`Audit3BountyColdTest`):
  - `invariant_FIXED_M1_prize_leaves_only_through_raids` and `invariant_FIXED_M1_rules_and_keys_never_change` — 256 runs × 500 calls each over random sequences of every BountyCold function (owner and strangers), ownership hand-overs, guardian panics and recovery votes, top-ups, raids, time, and direct attempts at `coldWithdraw`/`coldSetRules`/`setOwner`/`setCold`/`withdraw` on the Sanctum by every actor. Always: prize == seed + top-ups − raids, queue empty, rules 100/200/10000/24h/off, hot key = BountySanctum, cold = BountyCold, blacklist and watchers unchanged, no pending rule change, locker and key hold 0 ETH.
  - `test_FIXED_M1_no_fund_moving_selector_on_bountyCold` (16 Sanctum selectors + a generic `execute` sent to BountyCold by its owner: all revert; ETH send reverts), `_owner_powers_are_freeze_and_guardians_only`, `_guardian_recovery_cancellable_by_anyone`, `_bountyCold_two_step_and_no_renounce`, `_wiring_cold_is_locker`, `_sweep_lands_in_bountyCold`.
  - **Residual, pinned not hidden:** `test_FIXED_M1_residual_uncancelled_recovery_replaces_cold` — a guardian recovery nobody cancels for 7 days replaces BountyCold. The invariant handler models a watcher cancelling in time. Closing this fully needs a `Sanctum` change (e.g. no recovery when the cold key is a contract) — out of scope; for now the indexer cron should call `BountyCold.cancelRecovery()` whenever `RecoveryStarted` fires on the bounty Sanctum.
  - Other limits: the owner can freeze the game indefinitely (renewed cold panic); ERC-20s swept from the key land in BountyCold and stay there (no exit by design).
- Deploy: `script/DeployRaid.s.sol` `STEP=bounty` deploys `BountyCold{value: BOUNTY_WEI}(owner, factory, guardians, threshold)`. `scripts/prove-sanctum.mjs`: when the bounty's cold key is BountyCold, the cold-key panic/unfreeze steps are sent through BountyCold by its owner.
