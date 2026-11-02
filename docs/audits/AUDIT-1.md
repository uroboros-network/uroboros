# Sanctum — Audit 1: mechanics vs the Nov 2026 meta

> Token-stack findings removed; this repo contains the Sanctum product only.

Date: 2 Nov 2026 · Scope: the v1 product spec (draft 1), before any code was written. ETH used for USD maths: ~$2,790. The token named in this draft (SNCTM) and its launch mechanics were later dropped; only the product findings are kept.

---

## 0. Verdict (product)

1. The security design (time + user keys, token pays for work) is right for a $100k–$1M cap and is the strongest part of the spec. Keep it.
2. The watcher market as written is **farmable by the owner against himself** with ~zero cost: one Sanctum + one $50 watcher bond, and the owner is the judge. This is the #1 fix (A1).

---

## A. Ranked spec changes (product)

### A1. Watcher rewards are self-farmable (owner = judge = beneficiary) — CRITICAL

**Problem.** `confirmFreeze` is decided by the Sanctum's own cold key and pays the watcher $10 ETH from the shared Reward Pool + 200 SNCTM minted. The same person can own the Sanctum, the watcher key and the cold key. Cost per confirmed freeze: one `panic()` + one `confirmFreeze()` on Base (≈$0.02 gas) + a $50 bond that is never slashed because the owner never rejects. Cap: one freeze per Sanctum per 24h (sticky freeze). `factory.create` is free and unlimited, so a farmer with 250 Sanctums hits the full **50,000 SNCTM/day** mint cap and pulls **$2,500/day** from the pool until the pool is empty — the pool is funded at ~$25–35/day in the spec's own §8 scenario, so honest watchers get nothing from day one. Reputation (+1 per confirm) is farmed the same way → the farmer reaches rep ≥ 10 in 10 days and becomes a **Blacklist oracle** (§3.3) and a **BountySanctum guardian** (§3.2, "top 2 watchers by reputation").

**Evidence.** Every per-outcome reward scheme that lets the payer and payee be the same entity has been farmed: Forta moved to staking (100 FORT/bot, 2,500 FORT/pool) and SLA-score slashing precisely because unverifiable alerts were spammed ([Gate/Forta](https://www.gate.com/blog/102049/forta-onchain-real-time-security-ai-firewall-fort-tokenomics-decentralized-security-monitoring-blockchain-risk-detection-web3-security-layer)); bounty platforms gate payouts with expert triage, $250 stakes per report (Sherlock) or KYC (Immunefi) rather than letting the reporter self-validate ([Sherlock 2026](https://sherlock.xyz/post/best-web3-bug-bounties-in-2026-the-highest-paying-programs-on-every-platform)); DePIN networks only got sybil resistance when the farmer had to put capital or hardware at risk per identity ([SquirrelVPN DePIN sybil](https://squirrelvpn.com/blog/sybil-attack-resistance-in-depin-architectures)).

**Change (all five together).**
1. **ETH alert reward comes from the Sanctum's own prepaid coverage, not the shared pool.** Each Sanctum has a `coverageBalance` = 60% of its own subscription payments. `confirmFreeze` pays `min($10, coverageBalance)` from that balance. The shared Reward Pool pays ETH only for (a) bounty-Sanctum freezes and (b) canary-sourced flags, both of which the team adjudicates. Self-farming becomes net negative: pay $5 to recover ≤ $3.
2. **SNCTM mint requires objective on-chain evidence, not just a confirm:** the panic must land while a `queued` transfer ≥ 10% of balance exists OR within 1h of a withdraw that hit the hourly/daily cap; the Sanctum must be ≥ 30 days old, have ≥ $500 TVL (Chainlink-priced ETH + an allowlisted token set) for ≥ 7 consecutive days, and have paid ≥ 1 full month of subscription; max **1 SNCTM-rewarded freeze per Sanctum per 30 days**.
3. **Scale the SNCTM reward with value protected:** `reward = min(200, TVL_usd / 50)` SNCTM (so 200 SNCTM needs $10k TVL frozen). Sybil cost becomes capital, like Forta/DePIN stake.
4. **Reputation only counts freezes that passed rule 2 on a Sanctum whose cold key ≠ the watcher's registering address and that is not among the watcher's own created Sanctums** (the factory records creator). Still gameable with two wallets, so additionally: oracle rights (Blacklist flag) need rep ≥ 25 **and** registration ≥ 90 days **and** admin ratification for the first 180 days of the protocol.
5. **Uptime pool:** drop the fixed "$30/day" headline (unfunded at launch volumes) and pay uptime only to watchers with ≥ 1 rule-2 confirmed freeze in the trailing 30 days or that are in the top-10 reputation set.

**Impact.** Sustainability: the Reward Pool can no longer be drained by one actor; emissions stay tied to real protection. larpcheck: no change at launch (watchers ship later) but prevents the "emissions went to one wallet" chart that has killed node-reward schemes before.

### A11. Subscription price and currency vs comparables — LOW-MEDIUM

**Problem.** $5/month per Sanctum in ETH.

**Evidence.** Revoke.cash Premium $99/yr for 10 wallets (**$0.83/wallet/mo**), Ultimate $199/yr (**$1.66/wallet/mo**, includes auto-revoke + gas budget), paid in **USDC on Base** among others ([Revoke](https://revoke.cash/blog/2026/introducing-revoke-premium-and-ultimate)); Webacy Pro **$10/mo**, unlimited wallets, Starter free ([Webacy](https://webacy.com/pricing)); Pocket Universe free extension + per-tx paid coverage up to $30k, 200k users ([Pocket Universe](https://www.pocketuniverse.app/)); Harpie (Coinbase-backed on-chain firewall) **shut down Mar 2025** ([The Block](https://www.theblock.co/news/business/2025-03-27-coinbase-web3-security-shop-harpie-announces-shutdown-348421)) — the consumer on-chain-firewall segment has one dead body already.

**Change.** $5/mo stays defensible as a per-vault (not per-wallet) price, but: (1) accept **USDC on Base** as well as ETH (Revoke's choice; removes the Chainlink dependency for payers); (2) annual $39 (≈$3.25/mo) to match Revoke's annual-only model; (3) trial 14 days → **7 days and only for Sanctums with ≥ $100 TVL** (trial farming otherwise gives free watcher coverage to empty Sanctums — see B2). The 0.25% queued-transfer fee is fine but expect ≈0 revenue: 10%/day of balance is free via caps and `coldWithdraw` is free, so only urgent large hot-key moves pay.

**Impact.** Benchmarked pricing on the site ("$5/mo vs Webacy $10, Revoke Ultimate $1.66/wallet") is a larpcheck-neutral, conversion-positive line.

## B. Attack and farming vectors, with mitigations

### B1. Watcher market

| # | Vector | Mechanics / cost | Mitigation |
|---|---|---|---|
| W1 | **Owner farms own watcher** (confirm self-dealing) | 1 Sanctum + $50 bond; `panic` + `confirmFreeze` daily → $10 + 200 SNCTM + rep +1; 250 Sanctums = full 50k/day mint cap + $2,500/day from the pool; ~$0.02 gas each. Pool is ~$35/day → drained in hours. | A1 rules 1–4: reward from the Sanctum's own coverage balance; evidence-gated and TVL-scaled mint; 1 reward/Sanctum/30d; rep excludes own-created Sanctums. |
| W2 | **Reputation → oracle/guardian capture** | Rep ≥ 10 in 10 days via W1 → `Blacklist.flag` rights → flag Uniswap Universal Router / USDC as "drainer" → every `Firewall7702` user's approvals to it revert; or become BountySanctum guardian and freeze the showcase daily. | Watcher flags are **proposals** with a 24h challenge window, need 3 distinct watchers ≥ rep 25 ≥ 90 days or admin; hard allowlist of never-flaggable addresses (routers, Permit2, major tokens); BountySanctum guardians chosen by admin only in v1. |
| W3 | **Mass freeze griefing** | One $50 bond can `panic` every `watchersOn` Sanctum in one tx (24h freeze each); slashing is per rejection (50%), so after 2 rejections the bond is gone but N Sanctums were frozen. | Per-panic collateral: each open panic locks $25 of bond; max 2 unsettled panics per watcher; bond scales `$50 × 2^(open panics)`. Owners' choice: `watchersOn` can carry a `minRep` (default 5). |
| W4 | **Uptime sybil** | 10 identities × $50 = $500 bond, 3 heartbeats/day each (~$0.01) → all of a $30/day pool when alone = 2,190% APR. | A1 rule 5 + A9: uptime only for watchers with a rule-2 freeze in 30d or top-10 rep; pool = 50% of inflow. |
| W5 | **Collusive reject** (owner slashes an honest watcher) | Owner sets `watchersOn`, waits for a legitimate panic on a self-staged "attack", rejects → takes 50% of the watcher's bond ($25). Repeatable with new Sanctums. | Slash goes **to the Reward Pool, not the owner** (removes the incentive); a Sanctum that rejects twice loses `watchersOn` for 90 days; reject requires the owner to have ≥ 30 days of paid subscription. |
| W6 | **Oracle staleness** | USD-priced bond/reward via Chainlink; stale or sequencer-down price → bond under-collateralised or $10 overpaid. | Staleness check (2× heartbeat), Base L2 sequencer uptime feed check, clamp reward to ±20% of last-good value. |

### B2. Subscription and Sanctum fees

| # | Vector | Mitigation |
|---|---|---|
| S1 | **Trial farming:** unlimited free Sanctums × 14 days = free watcher coverage and (with W1) rewards. | Trial only when TVL ≥ $100 for 24h; 7 days; one trial per cold key. |
| S2 | **Fee avoidance:** 0.25% on `executeQueued` is avoided by 10%/day capped withdrawals or `coldWithdraw`. | Accept (it is a convenience fee); do not forecast revenue from it. |
| S3 | **Non-ETH queued fee assets** → FeeRouter holds random tokens; keeper swap is sandwichable / can be fed a honeypot token. | Fee only on allowlisted assets (ETH/WETH/USDC/cbBTC); others: fee waived (or taken but parked, no swap). |
| S4 | **Price in USD, pay in ETH:** payer front-runs a Chainlink update to pay 0.15% less. | Irrelevant at $5; ignore. |
| S5 | **Guardian recovery abuse:** 2-of-3 guardians `proposeCold` while the hot key keeps draining caps during the 7-day timer; or lost-cold user's guardians collude. | During a pending recovery the Sanctum auto-enters **freeze** (no outflow) until executed or cancelled; any cold-key tx cancels the proposal implicitly; show pending recoveries in the UI and to watchers. |

### B3. Bounty Sanctum

| # | Vector | Mitigation |
|---|---|---|
| R1 | **Legal faucet:** caps 5%/h, 10%/24h on 0.5 ETH = 0.05 ETH/day taken by anyone for ~$0.01 gas; after 30 days 0.5 × 0.9³⁰ ≈ 0.021 ETH; weekly top-up (10% of fees ≈ 0.09 ETH/mo at 1 ETH/day volume) does not keep up. Visitors see a prize that only goes down. | Tighten the bounty Sanctum's own caps (owner may tighten-only): **1%/h, 2%/24h** → 2%/day leak; frame the number on `raid.html` as a *leak meter* ("caps let out X, attackers got nothing above it"), not a prize; "win" = any outflow above caps. |
| R2 | **Permanent freeze:** anyone queues a >10% transfer → watchers/guardians panic → 24h frozen; repeat daily → the showcase is frozen 24/7 and shows no activity. | Bounty Sanctum ships with **queue disabled** (`maxQueue = 0`, only caps) in v1; watchers on it earn only when a freeze stops a queued transfer (impossible) → so the bounty Sanctum reward (300 SNCTM) is dropped or paid only for the team-adjudicated "cap breach" event. |
| R3 | **Robber = watcher collusion:** queue → own panic → admin confirms → 300 SNCTM + $10 daily. | Follows from R2; if the queue is kept, cap bounty-Sanctum rewards to 1/week and admin-only confirm. |
| R4 | **Guardian capture** (top-2 watchers by rep) | Admin-chosen guardians in v1 (W2). |

---

## D. Do not change (already right vs the meta)

1. **Time + user keys, not stake**, for security; token pays for work. This is the exact lesson Forta learned the expensive way and it is what makes the product honest at $100k.
5. **USD-priced, ETH-settled** bonds/rewards/subscriptions via Chainlink — correct for a token that will move 10x either way.
6. **Sanctum never locks out its own user for non-payment.** Keep this sentence on the site verbatim.
10. **Honest limits §10** — add one line: "Watcher rewards are paid from the subscription of the Sanctum they protected; the shared pool pays only for the bounty Sanctum and canaries."
12. **Guardians 0–5 with cold-only unfreeze and 7-day M-of-N recovery** — standard social-recovery shape; only add the auto-freeze during pending recovery (S5).

---

## E. Sources

Market / launch meta
- TrustSwap — Best launchpads on Base (fee table: Clanker 20% of LP fees on 1–3%; Zora 1%; Virtuals 1% 70/30; Flaunch 0.1% creation): https://trustswap.com/base/best-launchpads
- TrustSwap — Clanker vs Zora vs Flaunch vs own contract (Team Finance does not lock v4 on Base): https://trustswap.com/base/clanker-vs-zora-vs-flaunch
- Clanker v4 announcement (static 1%/2% example, 20% protocol fee, 2-block MEV delay, vault ≥7 d, audits Macro/Cantina): https://paragraph.com/@dish/introducing-clanker-v4
- DefiLlama — Clanker fees ($271k/30d, $16.6k/7d, $90.5M cumulative): https://defillama.com/protocol/clanker
- Blocmates — Flaunch (30-min fixed price, 0.25% max buy, PBW 0.1 ETH, FLAY vesting + $75M gate): https://www.blocmates.com/articles/flaunch-redefining-launchpads-with-fixed-price-fair-launch
- Alea Research — Flaunch ($600k+ to creators): https://alearesearch.substack.com/p/flaunch-no-fee-pumpfun-alternative
- Yellow — Doppler hosts >90% of Base pool launches, >40k/day: https://yellow.com/news/doppler-which-hosts-90-of-base-token-launches-moves-into-solana-with-a-native-rebuild
- The Defiant — Armstrong: Base content coins "didn't work" (Jul 2026): https://thedefiant.io/news/blockchains/coinbase-ceo-says-base-s-content-coins-didn-t-work
- Ricosworks — 11.5M tokens, 79% dead after day 1, 1.5% trading in week 5, Pump 1.70% all-in (Nov 2026): https://github.com/Ricosworks1/blockchain-payment-flow-analysis/releases/tag/market-update-memecoin-factory-79pct-day-one-death-rate-nov-2026
- Bitget — 8 mistakes that kill token launches 2026 (6–12 m cliff, 2–4 y vest, >25% team red flag): https://www.bitget.com/news/detail/12560605802866
- Hooklist PR #8418 — V4LaunchHook on Base (exact-output revert, external LP blocked, permanent full-range on graduation): https://github.com/Uniswap/hooklist/pull/8418

Scanners / larpcheck
- larpcheck.app (site unreachable at audit time; features from public posts: holder-analysis memory, insider crews, EVM support, token-gated plans): http://larpcheck.app/ · https://x.com/Larpcheckbot
- MetaMask eth-phishing-detect issue #305556 (larpcheck.app false-positive listing): https://github.com/MetaMask/eth-phishing-detect/issues/305556
- DEXTools — 2026 rug checklist thresholds (top holder <5/5–15/>15%, top-10 <20/20–40/>40%, dev <2/2–5/>5%, lock <30 d suspicious, 6–12 m legit, <$10k thin): https://www.dextools.io/news/early-crypto-scam-signals
- DEXTools — tax bands (green 0, yellow <5%, red >10% or modifiable; Token Sniffer <70/<50): https://www.dextools.io/news/how-to-check-buy-and-sell-tax-before-buying-a-token-2026
- GoPlus — SafeToken Locker for Uni v4 (Base `0x4F26fa33bCE395d50671CbC8C7a5D3c55a95519e`): https://docs.gopluslabs.io/page/goplus-safetoken-locker-for-uni-v4

Wallet security comparables
- Revoke.cash — Premium $99/yr, Ultimate $199/yr, 10 wallets, USDC on Base: https://revoke.cash/blog/2026/introducing-revoke-premium-and-ultimate · Q2 update: https://revoke.cash/blog/2026/update-q2
- Webacy pricing — Pro $10/mo: https://webacy.com/pricing
- Pocket Universe — free + per-tx coverage up to $30k, 200k users: https://www.pocketuniverse.app/
- The Block — Harpie shuts down (Mar 2025): https://www.theblock.co/news/business/2025-03-27-coinbase-web3-security-shop-harpie-announces-shutdown-348421
- Hypernative — Binance $6.3B 7702 drain timeline (50 authorizations, sweeper, $3B frozen): https://www.hypernative.io/insights/blog/inside-the-largest-crypto-theft-of-all-time-the-6-3b-binance-hot-wallet-drain
- CoinDesk — how EIP-7702 was used in the Binance hack: https://www.coindesk.com/tech/2026/10/30/here-s-how-one-ethereum-permission-let-an-attacker-drain-usd2-5-billion-from-binance
- Shattered — 2026 7702 drainer losses, CrimeEnjoyor sweeper, wallet responses: https://shattered.io/eip-7702-wallet-drainer-1-54-million-2026/
- Gate — Forta tokenomics (100 FORT/bot, 2,500 FORT/pool, SLA slashing, ~$10.7M cap): https://www.gate.com/blog/102049/forta-onchain-real-time-security-ai-firewall-fort-tokenomics-decentralized-security-monitoring-blockchain-risk-detection-web3-security-layer

Uniswap v4 hooks
- Trail of Bits — Building secure v4 hooks (Jul 2026): https://blog.trailofbits.com/2026/07/30/building-secure-uniswap-v4-hooks/
- Zealynx — 4 hook exploit patterns (Cork, Angstrom, LiquidityPenaltyHook, donate): https://www.zealynx.io/research/protocol-deep-dives/uniswap-v4-hook-attacks
- Composable Security — liquidity theft via hook fee: https://composable-security.com/blog/uniswap-v4-liquidity-theft-via-hook-fee/
- OpenZeppelin — 6 questions before writing a v4 hook: https://www.openzeppelin.com/news/6-questions-to-ask-before-writing-a-uniswap-v4-hook
- Uniswap — Routing for hooked pools (returns-delta/dynamicFees → manual allowlist; "extractive" refused): https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools
- Uniswap — hook allowlist submission requirements: https://developers.uniswap.org/hook-allowlist
- Uniswap — v4 deployments (Base addresses): https://developers.uniswap.org/docs/protocols/v4/deployments.md
- Cyfrin CodeHawks — TokenLaunchHook fee-collection finding (afterSwap `take` pattern): https://codehawks.cyfrin.io/c/2026-01-vanguard/s/175

Tokenomics / value accrual
- Tokenomist — $19B buyback meta, 11 tokens, only BNB and RAY net-deflationary: https://tokenomist.ai/research/buyback-and-burn-explained-what-they-are-who-is-doing-them-and-whether-they-actually-work
- CryptoDaily — Uniswap fee switch: burns without volume are cosmetic: https://cryptodaily.co.uk/2026/05/uniswap-fee-switch-aftermath-token-burns-volume
- crypto.news — token buybacks hit record $638M in 2026: https://crypto.news/crypto-token-buybacks-hit-record-638m-in-2026/

Work-for-reward / sybil precedents
- Sherlock — 2026 bounty programmes (Sherlock $250 stake per report, Immunefi KYC, median payout ~$2k): https://sherlock.xyz/post/best-web3-bug-bounties-in-2026-the-highest-paying-programs-on-every-platform
- SquirrelVPN — sybil resistance in DePIN (stake, hardware-bound keys, reputation): https://squirrelvpn.com/blog/sybil-attack-resistance-in-depin-architectures
- Chainscore — why social recovery depends on sybil resistance: https://www.chainscorelabs.com/blog/decentralized-identity-did-and-reputation/identity-recovery-and-key-management/why-social-recoverys-success-depends-on-sybil-resistance
