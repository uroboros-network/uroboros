// One-time: open watcher-node staking for the real coin. Run right after the Pump.fun coin exists.
// Must be signed by the program's UPGRADE AUTHORITY (the deploy key). Can only ever run once per program.
//   node scripts/init-staking.mjs --url https://api.mainnet-beta.solana.com --keypair ~/.config/solana/uroboros-deploy.json \
//        --mint <UROBOROS mint> --min <whole tokens, e.g. 100000> [--cooldown-days 3]
import { Connection, Keypair, PublicKey, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import * as S from "../client/sanctum.js";
const arg = (k, d) => { const i = process.argv.indexOf("--" + k); return i < 0 ? d : process.argv[i + 1]; };
const path = (p) => p.replace(/^~/, homedir());
const conn = new Connection(arg("url", "https://api.mainnet-beta.solana.com"), "confirmed");
const admin = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(path(arg("keypair")), "utf8"))));
const mint = new PublicKey(arg("mint"));
const m = await conn.getAccountInfo(mint);
if (!m) throw new Error("mint not found");
const tokenProgram = m.owner;
const decimals = m.data[44];
const min = BigInt(arg("min")) * 10n ** BigInt(decimals);
const cooldown = BigInt(Math.round(Number(arg("cooldown-days", "3")) * 86400));
await S.ready();
if (await conn.getAccountInfo(S.pda.config())) throw new Error("staking already initialized");
console.log(`init_staking: mint ${mint.toBase58()} (${tokenProgram.toBase58()}, ${decimals} dp), min ${arg("min")} tokens, cooldown ${cooldown}s, admin ${admin.publicKey.toBase58()}`);
const sig = await sendAndConfirmTransaction(conn, new Transaction().add(S.initStaking({ admin: admin.publicKey, mint, minStake: min, cooldownSecs: cooldown, tokenProgram })), [admin]);
console.log("done:", sig);
