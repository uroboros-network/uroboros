# Uroboros — STEP2-FIXES (AUDIT-2 applied)

> Token-stack findings removed; this repo contains the Sanctum product only.

Date: 2 Nov 2026 · Applied the AUDIT-2 fixes. Only the product fix (L2, subscription trial) is kept here; the token-stack fixes (H1/H1b, H2, M1, M2, L1/L1b, I7, deploy script) concerned contracts that are not in this repo.

## Per finding

### L2 — trial (`src/Subscription.sol`, `src/SanctumFactory.sol`)
- `Subscription.register(sanctum, trialEligible)`: trial only if `trialEligible && usd(balance) ≥ $100`. The factory passes `true` from `create` (default rules) and `false` from `createWithRules` (shared `_create`). Custom-rules Sanctums are registered without a trial; the bounty Sanctum (custom rules) therefore gets no free week — the team buys its coverage with `pay()`.
- **Remaining limit (documented in `Subscription.sol`):** with the default rules 5%/h and 10%/24h of the deposit leave at once and the rest only through the 6 h queue, so one $100 note can still start a new trial roughly every 6 hours (≤ 4/day) instead of once per block. `trialUsed[cold]` was not added (a cold key is free to rotate; the capital lock is the real cost).
- `test_FIXED_L2_trial_only_for_default_rules`, `Subscription.t.sol` register test extended.

## Still open / disclose

- Trial recyclable once per ~6 h per $100 with default rules (L2 remainder); AUDIT-3 L3 later showed `coldSetRules` makes it once per tx. Coverage has no on-chain value until the watcher market ships.
