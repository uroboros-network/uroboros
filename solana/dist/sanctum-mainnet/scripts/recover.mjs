// Withdraw what the proof run left in its throwaway Sanctum, with the saved cold key (caps apply: run it again later
// for more; 5%/h, 10%/24h). Sends to --to (default: the payer address you give).
//   node scripts/recover.mjs --url <rpc> --keys proof-mainnet-beta.KEYS-SECRET.json --to <your wallet>
import { Connection, Keypair, PublicKey, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
import { readFileSync } from "node:fs";
import * as S from "../client/sanctum.js";
const arg = (k, d) => { const i = process.argv.indexOf("--" + k); return i < 0 ? d : process.argv[i + 1]; };
const conn = new Connection(arg("url", "https://api.mainnet-beta.solana.com"), "confirmed");
const k = JSON.parse(readFileSync(arg("keys"), "utf8"));
const cold = Keypair.fromSecretKey(Uint8Array.from(k.cold));
const sanctum = new PublicKey(k.sanctum), to = new PublicKey(arg("to"));
await S.ready();
const s = await S.fetchSanctum(conn, sanctum);
const bal = await S.vaultSolBalance(conn, sanctum);
const capAcc = await conn.getAccountInfo(S.pda.cap(sanctum));
const now = BigInt(Math.floor(Date.now() / 1000)) - 30n;
const room = S.capRoom(capAcc ? S.decodeCapState(capAcc.data) : null, s.rules, bal, now);
const amount = room > 1000n ? room - 1000n : 0n;
console.log(`vault ${bal} lamports, can send ${amount} now`);
if (amount === 0n) process.exit(0);
// the cold key pays the fee; top it up with ~0.001 SOL if needed
const sig = await sendAndConfirmTransaction(conn, new Transaction().add(S.coldWithdrawSol({ cold: cold.publicKey, sanctum, to, amount })), [cold]);
console.log("sent", sig);
