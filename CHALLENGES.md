# Uroboros — weekly Sanctum challenges (CTF ladder)

Status: built and tested 2 Nov 2026. Not deployed. Contracts: `src/challenges/`. Deploy: `STEP=challenge` in the standalone `script/DeployRaid.s.sol` (needs nothing but ETH; no token, no FeeRouter). Site data: `scripts/challenge-indexer.mjs` → `site/challenges.json`.

Two games run side by side:

1. **The main vault (Raid the Sanctum, SPEC §3.2).** A real bounty Sanctum with a public hot key, made by the product SanctumFactory and funded with ETH. Anyone can use the key, but every outflow it allows goes back into the vault. The prize only grows. The only way to get ETH out to your own address is to break the contracts. Whoever does keeps it, plus an off-chain team bounty for a public post-mortem.
2. **The weekly challenges (this file).** Small, separate vaults, each with its own ETH prize and a deliberately planted flaw. One new level a week. The first to drain one takes its prize and goes on the on-chain leaderboard.

## Levels

| # | Name | Difficulty | Contract |
|---|---|---|---|
| 1 | Gate | easy | `src/challenges/Level1.sol` |
| 2 | Cloister | medium | `src/challenges/Level2.sol` |
| 3 | Crypt | medium-hard | `src/challenges/Level3.sol` |
| 4 | Reliquary | hard | `src/challenges/Level4.sol` |

Each level is a small Sanctum-style bank: players open their own vaults, deposit, withdraw under caps, use cold keys, queues or signatures. Vault 0 is the house vault, which holds the prize. Using the level as intended only ever moves your own money. A planted flaw lets you move the house's money.

## Rules

1. **Verified source, no hints.** Every level is verified on Basescan before it opens. The source, names and comments do not point at the flaw. Nobody on the team gives hints, confirms guesses or comments on approaches while a level is open.
2. **Opening time.** A level opens at its `opensAt` (unix time, on chain and on the site). Before then every vault function reverts `"closed"`. One level opens per week.
3. **What counts as a solve.** A level is solved the moment its ETH balance falls **below half of its prize** (`prize` = the ETH the team put into the house account). Only ETH that leaves through the level's own payments counts. In practice this means taking more than half of the house money, net of anything you deposited yourself. The level checks this after every payment it makes, and then:
   - records `solvedBy` and `solvedAt` in the level;
   - calls `ChallengeRegistry.recordSolve`, which stores the level's solver and time and adds 1 to the solver's count on the leaderboard (`solves`, `firstSolveAt`).
4. **Solver of record = `tx.origin`.** The address credited is the EOA that sent the transaction that crossed the half-prize line, even if you used your own attack contract. With EIP-7702 the EOA is still `tx.origin`.
5. **First drain wins.** A level is solved once. You keep whatever ETH you took out. No contract pays anything extra, claws anything back, or lets the team take the remainder. Any ETH left in a solved level stays there.
6. **No team exit.** Levels have no owner, no admin and no withdrawal for the team. An unsolved prize stays in its level until someone solves it.
7. **Isolation.** Levels share nothing with the protocol: no funds, no approvals, no calls into any protocol contract or the bounty Sanctum. A level's only outside call is the write-only `recordSolve` to the registry. If that call ever fails, the level still records the solve itself.
8. **Prize funding.** The team sends each level's prize as plain ETH in the level's creation transaction (`PRIZE_WEI`). Anyone can add to an unsolved level with `fund()`. No protocol contract streams fees into levels.
9. **Leaderboard.** `ChallengeRegistry.leaderboard()` returns every solver with their solve count and first-solve time. The site ranks by solves (high to low), then by first-solve time (earlier first).
10. **Scope.** Only the level contract is in scope. Attacks on Base, the RPC, the sequencer, other players' keys or the site do not count and are not welcome.

## Front-running (read before you send a solve)

A solve is a transaction anyone can copy once they see it: same calls, their address instead of yours. Here is what is and is not true on Base:

- **Base has no public peer-to-peer mempool like Ethereum mainnet.** Transactions go to the sequencer, and the sequencer does not gossip them to the public. Generalized front-running bots that watch the public mempool on Ethereum mostly have nothing to watch on Base.
- **That is not the same as private.** Your transaction is visible to the RPC provider you send it through, and to anything that provider shares or exposes. If a solve depends on a setup transaction followed by a drain, the setup is public on chain as soon as it lands, and anyone reading the chain can finish the job first. After any solve, the method is public too.
- **What we recommend.** Send through an RPC you trust, or straight to Base's official endpoint. Put the whole exploit in **one atomic transaction** from your own contract, so there is nothing to copy between steps. Where your wallet offers a private or protected submission for Base, use it. *Flashbots Protect* is an Ethereum-mainnet service. We have not verified any Flashbots-branded protection on Base, so do not count on it there.
- If someone copies your solve, the registry credits whoever's transaction crossed the line first. We cannot judge or reverse that on chain.

## Operations (team)

- Deploy one level (dry run first without `--broadcast`):
  `STEP=challenge LEVEL=1 PRIZE_WEI=100000000000000000 OPENS_AT=<unix ts> forge script script/DeployRaid.s.sol --rpc-url https://mainnet.base.org --account dev --broadcast` (state in `deployments/base-raid.json`).
  The first run also deploys the `ChallengeRegistry` (owner = deployer, or `CHALLENGE_OWNER`; two-step hand-over). The run is resumable: a level that is already deployed is only registered, never deployed twice.
- Verify: `STEP=verify` prints the Basescan commands for the registry and every deployed level.
- Indexer: `node scripts/challenge-indexer.mjs` writes `site/challenges.json` (levels, prize, inside, open/upcoming/solved, solver, solve tx, leaderboard).
- **The solutions are private.** Tests that prove every level is solvable are kept out of this repository and are published only after the level they solve has been solved on chain. Hints are never given while a level is open.
