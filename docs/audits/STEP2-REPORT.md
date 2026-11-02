# Uroboros — Step 2 report

> Token-stack findings removed; this repo contains the Sanctum product only.

Date: 2 Nov 2026 · Step 2 built the (since abandoned) token launch stack plus a step-1 cleanup of the product contracts (trial, USDC). Only the product part is kept here.

## Contracts (`src/`, product changes)

| File | Lines | What |
|---|---|---|
| `Subscription.sol` | 149 | Step-1 cleanup: `TRIAL` 7 d, trial only if the Sanctum holds ≥ `TRIAL_MIN_USD` $100 of ETH at registration (feed stale/invalid ⇒ no trial, never a revert), `registered` map; `payUsdc(sanctum, months)` at `PRICE_USDC` 5e6/month via `safeTransferFrom` to `feeRouter`; immutable `usdc`. |
| `SanctumFactory.sol` | 62 | `create` / `createWithRules` now `payable`: msg.value is forwarded to the new Sanctum **before** `Subscription.register`, so "first deposit + trial" is one tx. |

## Tests (`test/`, product)

| File | Tests | Content |
|---|---|---|
| `Subscription.t.sol` | 16 (+3) | Trial only when funded ≥ $100 at creation (0.04 ETH at $3000 yes, 0.03 no, the first wei that values to ≥ $100 yes, funding after registration no); stale/zero feed ⇒ no trial, creation still succeeds; USDC payment incl. no-oracle, allowance, event; constructor checks for `usdc`, `TRIAL` 7 d. |
| step-1 suites | 87 | Unchanged except `Fixture`: `_sanctum()` deposits 100 ETH in the creation tx (payable `create`) instead of `vm.deal` after; `_emptySanctum()` added. |

## Interpretations (spec silent or ambiguous)

1. **Trial check happens once, at registration**, on the Sanctum's ETH balance only (ERC-20 holdings are not priced). Hence `factory.create` is payable; a Sanctum funded a block later gets no trial (AUDIT-1 S1 wanted exactly that: no free coverage for empty Sanctums). "One trial per cold key" (S1) is not implemented — the balance gate makes farming cost ≥ $100 of locked-up capital per trial; left for the audit loop.
2. **USDC is a separate `payUsdc`**, not a parameter on `pay()` — payable + ERC-20 in one function would need a currency switch and a refund path that differs per currency. Same ledger, same `MONTH`, no oracle for USDC.

Later change: AUDIT-2 L2 restricted the trial to Sanctums created with the factory's default rules (see STEP2-FIXES).
