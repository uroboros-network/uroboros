# Uroboros — Sanctum

A Sanctum is a wallet that a stolen hot key cannot empty.

Funds sit in a Sanctum, not in your hot wallet. The hot key can still spend, but only a little at a time:

- **Caps.** At most 5% of each asset per hour and 10% per rolling 24 hours leave at once (defaults).
- **Queue.** Anything bigger waits 6 hours in a queue that the hot key, the cold key or a guardian can stop.
- **Freeze.** The hot key, the cold key or any guardian you picked can freeze the Sanctum for 24 hours. A freeze voids everything queued before it. Only the cold key unfreezes.
- **Cold key.** Kept offline. It withdraws anything at once, rotates keys and changes rules. It is the master key.
- **Guardians.** Addresses you choose (0–5 on EVM, up to 3 on Solana). On EVM, a threshold of them can also start a 7-day cold-key recovery that the cold key can cancel (and that can be switched off).

Security comes from time and your own keys. No feature depends on a token price.

## Status

| Part | Where | State |
|---|---|---|
| Sanctum program (Solana) | `solana/` | Anchor program, live on Solana mainnet. Program id `C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj`. Token `7uomqM9JzWQZuRtrbPW2wNQNJCK9QSf39wdpMi7kpump` ($UROBOROS, Pump.fun). |
| Sanctum contracts (EVM) | `src/` | Code complete and tested; **not deployed**. Targets Base and Ethereum. |
| Raid the Sanctum (EVM) | `src/BountySanctum.sol`, `src/BountyCold.sol` | Code complete; not deployed. |
| Weekly challenges (EVM CTF) | `src/challenges/` | Four levels written; not deployed. See `CHALLENGES.md`. |

## Repo layout

```
src/                     EVM contracts (Solidity 0.8.28, evm prague)
  Sanctum.sol            the guarded vault: caps, queue, freeze, guardians, recovery, 0.25% fee on executed queued transfers
  SanctumFactory.sol     creates Sanctums with default or custom (tighten-only later) rules
  Sanctum7702.sol        EIP-7702 delegate: lets a hot EOA sweep into its Sanctum and trigger panic
  Subscription.sol       $5/month coverage ledger, ETH via Chainlink ETH/USD or USDC; never locks a user out
  FeeCollector.sol       immutable fee sink on Base; owner names one destination, once
  FeeBridge.sol          fee sink on Ethereum; bridges ETH fees to Base via the L1StandardBridge
  Blacklist.sol          known-drainer destinations (owner + oracles, two-step ownership)
  BountySanctum.sol      "Raid the Sanctum": a public hot key whose every allowed outflow returns to the vault
  BountyCold.sol         the raid vault's cold key: a locker that can only panic, unfreeze and set guardians
  challenges/            ChallengeRegistry, Challenge base, Level1–Level4 (public by design: find the bug)
test/                    Foundry tests (unit, fuzz, invariant, fork)
script/                  DeployProduct.s.sol (Base), DeploySanctumChain.s.sol (Ethereum), DeployRaid.s.sol (raid + challenges)
scripts/                 viem scripts: on-chain proof writers, raid indexer, challenge indexer
solana/                  Anchor program (programs/sanctum), JS client and LiteSVM tests
docs/audits/             internal audit and fix reports (AUDIT-1/2/3, STEP*)
CHALLENGES.md            rules of the weekly challenge ladder
```

## EVM: build and test

Requires [Foundry](https://book.getfoundry.sh/). Libraries are git submodules (`lib/forge-std` v1.17.0, `lib/openzeppelin-contracts` v5.1.0).

```sh
git clone --recursive <this repo>
cd <repo>
# if you cloned without --recursive:
git submodule update --init --recursive

forge build
forge test
```

`forge test`: **184 passed, 0 failed, 1 skipped** (22 suites; the skip is the Ethereum fork suite without `ETH_RPC`). Fork suites are skipped unless their RPC is set:

```sh
ETH_RPC=https://ethereum-rpc.publicnode.com forge test --match-contract EthForkTest
```

Longer fuzz runs:

```sh
FOUNDRY_FUZZ_RUNS=3000 forge test --match-test testFuzz_A3
```

Off-chain scripts (Node 20+): `npm install`, then `npm run prove`, `npm run raid`, `npm run challenges`. Private keys are only read from the environment (`PK=...`) and never stored.

### Deploy (not done yet)

```sh
# Base: Blacklist, FeeCollector, Subscription, SanctumFactory, Sanctum7702
STEP=deploy forge script script/DeployProduct.s.sol --rpc-url $BASE_RPC --account <keystore>          # dry run
STEP=deploy forge script script/DeployProduct.s.sol --rpc-url $BASE_RPC --account <keystore> --broadcast

# Ethereum: FeeBridge + the same product stack (FEE_ROUTER_BASE and TOKEN_SINK are required)
STEP=sanctum-chain FEE_ROUTER_BASE=0x... TOKEN_SINK=0x... forge script script/DeploySanctumChain.s.sol --rpc-url $ETH_RPC --account <keystore>

# Raid vault and challenge levels on Base (reads deployments/base-product.json)
STEP=bounty forge script script/DeployRaid.s.sol --rpc-url $BASE_RPC --account <keystore>
```

Every script is resumable and writes its addresses to `deployments/*.json`. `STEP=verify` prints the explorer verification commands.

## Solana: build and test

Requires Rust, the Solana CLI (Agave) and Anchor 1.2.2.

```sh
cd solana
anchor build            # builds target/deploy/sanctum.so
npm install
npm test                # LiteSVM tests against the built program
```

Solana tests (`npm test`, LiteSVM): **16 passed, 0 failed**.

The Solana program is a port of the EVM Sanctum's behaviour (not its code): SOL and SPL / Token-2022 vault per Sanctum, hourly and rolling-24h caps, a queue with delay, panic and cold-only unfreeze, guardians, tighten-only rule changes with a 3-day delay, and an opt-in watcher-node module (nodes stake a token; a node may only freeze a live, unapproved queue item in its final hour). v1 has no protocol fee, no guardian recovery and no admin hook on Sanctums.

## Audits

These are **internal** reviews, written while the code was built. There is no third-party audit.

- [AUDIT-1](docs/audits/AUDIT-1.md) — mechanism review of the spec
- [AUDIT-2](docs/audits/AUDIT-2.md) — step-2 review (product part)
- [AUDIT-3](docs/audits/AUDIT-3.md) — pre-launch review: rolling-24h proof, bounty key, trial gate
- Fix and build reports: [STEP1](docs/audits/STEP1-REPORT.md), [STEP2](docs/audits/STEP2-REPORT.md), [STEP2-FIXES](docs/audits/STEP2-FIXES.md), [STEP3](docs/audits/STEP3-REPORT.md), [STEP3-FIXES](docs/audits/STEP3-FIXES.md), [STEP3-FIXES-2](docs/audits/STEP3-FIXES-2.md), [STEP4](docs/audits/STEP4-REPORT.md)

The reports cover an earlier, larger codebase. Sections about a token launch stack that was dropped have been removed; test counts quoted inside them are historical.

## Security notes

- **Not audited by a third party.** Use small amounts.
- **Solana upgrade authority is a single dev key.** The program can be upgraded by that key. It will move to a multisig; until then, treat the program as upgradeable by one person.
- **The cold key is the master key.** Whoever holds it can unfreeze, change every rule and withdraw everything in one transaction. Guardians cannot stop a stolen cold key. Keep it offline.
- **The hourly cap is a fixed window**, so close to two hourly caps can leave within seconds across a window boundary (up to 9.75% on the defaults). The binding guarantee is the rolling 24-hour cap.
- **Guardians can keep freezing.** Guardians acting together can renew a freeze and, on EVM, keep re-proposing a recovery after every cancel. Remove them with the cold key.
- `Sanctum7702` cannot stop a compromised EOA key from re-delegating to something else.
- Found a bug? The raid vault is the public test: if you can get ETH out of it, you keep it. For anything else, open an issue or contact the team privately before disclosing.

## License

MIT
