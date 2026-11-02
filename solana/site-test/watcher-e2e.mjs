// Sets up a Sanctum that qualifies for a watcher panic (watchers on, short delay, unapproved queue item), for watcher tests.
import { Connection, Keypair, SystemProgram, Transaction, sendAndConfirmTransaction } from "@solana/web3.js";
import { readFileSync } from "node:fs";
import * as S from "../client/sanctum.js";
const conn = new Connection(process.argv[2], "confirmed");
const payer = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(process.argv[3], "utf8"))));
await S.ready();
const hot = Keypair.generate(), cold = Keypair.generate();
const go = (ixs, s) => sendAndConfirmTransaction(conn, new Transaction().add(...ixs), s);
await go([SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: hot.publicKey, lamports: 2e8 }), SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: cold.publicKey, lamports: 1e7 })], [payer]);
const sanctum = S.pda.sanctum(hot.publicKey, 0n);
await go([S.create({ hot: hot.publicKey, cold: cold.publicKey }), S.depositSol({ depositor: hot.publicKey, sanctum, amount: 100_000_000n })], [hot]);
await go([S.setModes({ cold: cold.publicKey, sanctum, watchersOn: true, approvalMode: true }), S.coldSetRules({ cold: cold.publicKey, sanctum, rules: { ...S.DEFAULT_RULES, delaySecs: 600n } })], [cold]);
await go([S.withdrawSol({ hot: hot.publicKey, sanctum, to: hot.publicKey, amount: 20_000_000n, queueSeq: 0n })], [hot]);
console.log(sanctum.toBase58());
