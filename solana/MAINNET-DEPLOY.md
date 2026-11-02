# Sanctum on Solana mainnet: deploy runbook

Program id: **`C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj`** (compiled into the binary; the site client uses it).
Package: `solana-sanctum/dist/sanctum-mainnet.tgz` (prebuilt `sanctum.so`, `program-keypair.json`, IDL, scripts).
You only need the **Solana CLI** and **Node 18+**. No Rust, no Anchor.

| What | Value |
|---|---|
| `sanctum.so` size | **463,712 bytes** (opt-level "z", fat LTO, stripped; was 575,752 at opt 3) |
| sha256 `sanctum.so` | `0ba8a9e5aef16c0e8ecc853edb5b4f99a5e4480c0ba7781c233e665887b22139` |
| Program data rent (exact `--max-len 463712`, 463,757-byte account) | **2.3565358 SOL** (mainnet `getMinimumBalanceForRentExemption`, checked 2 Nov) |
| Program account rent (36 bytes) | 0.00083312 SOL |
| Fees (~470 write txs + deploy) | ~0.003 SOL (+ priority fee if you set one) |
| **Have in the deploy wallet** | **2.40 SOL** (2.36 ends up as program rent, the rest stays) |
| Upgrade authority | **your dev/deploy key. No multisig.** It can replace the program code at any time. Stated plainly on the site. |
| Protocol fee | none in v1 |
| Node rewards | none on-chain in v1 (next release); slashing = your deploy key, burns |

Deploy needs ~1× rent, not 2×: the CLI writes a buffer (2.3565 SOL), then the deploy moves it into the program
data in one instruction (measured on a local validator: a wallet with rent + 0.77 SOL deployed fine).
If a deploy dies halfway, the buffer keeps its SOL: get it back with `solana program close --buffers` (below).

---

## 0. One-time setup (skip what you have)

```bash
# Solana CLI (Agave). Then open a new terminal.
sh -c "$(curl -sSfL https://release.anza.xyz/stable/install)"
export PATH="$HOME/.local/share/solana/install/active_release/bin:$PATH"
solana --version   # tested with 4.3.2

# Unpack the package (adjust the path to where the tgz is)
mkdir -p ~/uroboros && tar xzf ~/Downloads/sanctum-mainnet.tgz -C ~/uroboros && cd ~/uroboros/sanctum-mainnet
npm install
shasum -a 256 sanctum.so   # must print 0ba8a9e5aef16c0e8ecc853edb5b4f99a5e4480c0ba7781c233e665887b22139
solana-keygen pubkey program-keypair.json   # must print C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj
```

Your deploy key must be a **keypair file** (never paste it anywhere). Below it is `~/.config/solana/uroboros-deploy.json`;
change the path if yours differs. To make one from a seed phrase you already have:
`solana-keygen recover 'prompt://?key=0/0' -o ~/.config/solana/uroboros-deploy.json` (asks for the phrase locally).

Set an RPC. The public endpoint works but rate-limits ~470 write transactions; a free Helius/Triton URL is faster:

```bash
export RPC=https://api.mainnet-beta.solana.com      # or your https://mainnet.helius-rpc.com/?api-key=...
export KEY=~/.config/solana/uroboros-deploy.json
solana balance --keypair $KEY --url $RPC           # need >= 2.40 SOL
```

## 1. Deploy (2–5 min)

```bash
cd ~/uroboros/sanctum-mainnet && solana program deploy sanctum.so \
  --program-id program-keypair.json \
  --keypair $KEY --upgrade-authority $KEY \
  --max-len 463712 \
  --with-compute-unit-price 50000 --max-sign-attempts 50 \
  --url $RPC
```

If it stops with "N write transactions failed", run the **same command again**; it resumes. If you give up instead,
recover the buffer SOL: `solana program close --buffers --keypair $KEY --url $RPC`.

## 2. Verify

```bash
solana program show C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj --url $RPC
#   Authority: <your deploy pubkey>   Data Length: 463712 (0x71360) bytes   Balance: 2.3565358 SOL
solana program dump C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj /tmp/onchain.so --url $RPC && shasum -a 256 /tmp/onchain.so
#   must print 0ba8a9e5aef16c0e8ecc853edb5b4f99a5e4480c0ba7781c233e665887b22139
```

Then put the id in the site's `addresses.json` (the site turns on when the account is executable):
`{"cluster":"mainnet-beta","sanctumProgram":"C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj","upgradeAuthority":"<your deploy pubkey>","idl":"sanctum-idl.json"}`

## 3. Live proof with a small amount (~0.05 SOL total, most recoverable)

```bash
cd ~/uroboros/sanctum-mainnet && node scripts/proof.mjs --url $RPC --payer $KEY --sol 0.02 --out proof-mainnet.json
```

Runs: create → deposit 0.02 SOL → withdraw 4% (paid) → withdraw 20% (queued 6h) → guardian panic → frozen withdraw
fails → guardian can't stack → cold unfreeze → queued item voided → cancel (rent back) → re-queue → guardian muted →
cold panic + unfreeze_and_rotate → old hot key rejected. Writes `proof-mainnet.json` (signatures + explorer links)
and `proof-mainnet.KEYS-SECRET.json` (the throwaway keys; keep it local). About 0.015 SOL stays in the test vault behind
the caps; pull it back over the next day with
`node scripts/recover.mjs --url $RPC --keys proof-mainnet.KEYS-SECRET.json --to <your wallet>` (run it a few times;
5%/h, 10%/24h — that is the product working). The cold test key pays that fee: send it 0.001 SOL first if it is empty.

## 4. After the coin exists (23:00): open node staking (once, irreversible)

```bash
cd ~/uroboros/sanctum-mainnet && node scripts/init-staking.mjs --url $RPC --keypair $KEY \
  --mint <UROBOROS mint from pump.fun> --min <minimum stake in whole tokens> --cooldown-days 3
```

Must be signed by the upgrade authority (the program checks it). Mint, min stake and cooldown are fixed after this
(changing them needs a program upgrade). The mint's program (Token-2022 for Pump `create_v2`) is detected.
Team node on the VPS: `node scripts/node-register.mjs --url $RPC --keypair <node key> --amount <tokens>` then
`RPC_URL=$RPC NODE_KEYPAIR=<node key> STATUS_FILE=/var/lib/uroboros/watcher-status.json node watcher/watcher.mjs`
(`DRY_RUN=1` to watch without sending; `--once` for a single poll). The node key needs ~0.01 SOL for fees.

## 5. Optional: on-chain IDL (skip tonight)

The site ships its own IDL (`site/sanctum-idl.json`); explorers just show raw instructions without it. Anchor 1.x
stores IDLs through the Program Metadata program and needs the Anchor CLI:
`anchor idl init --filepath sanctum-idl.json C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj --provider.cluster $RPC --provider.wallet $KEY`

## Later: grow, recover, close

- Upgrade (same id): `solana program deploy new.so --program-id C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj --keypair $KEY --upgrade-authority $KEY --url $RPC`.
  If the new binary is bigger than 463,712 bytes, first `solana program extend C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj <extra bytes> --keypair $KEY --url $RPC` (costs rent for the extra bytes only).
- Leftover buffers from failed deploys/upgrades: `solana program close --buffers --keypair $KEY --url $RPC`.
- The 2.3565 SOL program rent is refundable with `solana program close C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj --recipient <wallet> --keypair $KEY --bypass-warning --url $RPC`.
  **This kills the program forever** (the id can never be redeployed) and strands every user's Sanctum. Only for a dead program.
- Making it immutable later: `solana program set-upgrade-authority C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj --final --keypair $KEY --url $RPC` (irreversible).

## What the deploy key can and cannot do (say this on the site)

- It **can** upgrade the program (replace the code), which is the master key over every Sanctum. Keep it offline, never sign
  durable-nonce transactions with it.
- It **can** slash watcher-node stakes (burns them). It has **no** instruction that touches a Sanctum: no admin freeze,
  blacklist or fee switch exists in this program.
- `program-keypair.json` only matters until the first deploy (whoever holds it can create the program at this address
  first). After step 1 it is useless; you can delete it.

## Honest limits (v1)

- Funds left in the hot wallet are not protected; only what is in the vault is.
- A freeze is time, not insurance: the cold key must act (rotate the hot key with `unfreeze_and_rotate`).
- Token-2022 mints with a PermanentDelegate extension can be drained by that delegate regardless of any vault
  (Pump coins don't have it). Transfer-fee mints: caps count the amount sent.
- Unaudited. Tests: 16 litesvm tests incl. a 400-step randomized run (worst 24h outflow 9.997% of the 10% cap),
  local-validator end-to-end proof, headless site-client test.
