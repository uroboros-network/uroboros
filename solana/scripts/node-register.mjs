// Register (or add to) a watcher node stake from a keypair file (for the team node on the VPS).
//   node scripts/node-register.mjs --url <rpc> --keypair /path/node.json --amount <whole tokens>
import { Connection, Keypair, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import * as S from "../client/sanctum.js";
const arg = (k, d) => { const i = process.argv.indexOf("--" + k); return i < 0 ? d : process.argv[i + 1]; };
const conn = new Connection(arg("url", "https://api.mainnet-beta.solana.com"), "confirmed");
const op = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(arg("keypair").replace(/^~/, homedir()), "utf8"))));
await S.ready();
const cfgAcc = await conn.getAccountInfo(S.pda.config());
if (!cfgAcc) throw new Error("staking not initialized yet");
const cfg = S.decodeConfig(cfgAcc.data);
const dec = (await conn.getAccountInfo(cfg.mint)).data[44];
const amount = BigInt(arg("amount")) * 10n ** BigInt(dec);
const exists = !!(await conn.getAccountInfo(S.pda.node(op.publicKey)));
const ix = exists ? S.addStake({ operator: op.publicKey, mint: cfg.mint, amount, tokenProgram: cfg.tokenProgram })
  : S.registerNode({ operator: op.publicKey, mint: cfg.mint, amount, tokenProgram: cfg.tokenProgram });
const sig = await sendAndConfirmTransaction(conn, new Transaction().add(ix), [op]);
console.log(exists ? "stake added" : "node registered", op.publicKey.toBase58(), sig);
