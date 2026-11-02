// Headless test of site/sanctum-client.js using the site's vendored web3 IIFE, against a live RPC (local validator).
//   node site-test/site-client.test.mjs --url http://127.0.0.1:8899 --payer keys/local-deployer.json --mint <staking mint>
import { readFileSync } from "node:fs";
import vm from "node:vm";
globalThis.window = globalThis;
vm.runInThisContext(readFileSync(new URL("../../site/vendor/web3.iife.min.js", import.meta.url), "utf8"));
const W3 = globalThis.solanaWeb3;
const C = (await import("../../site/sanctum-client.js")).default;
const { createInitializeMint2Instruction, createAssociatedTokenAccountIdempotentInstruction, createMintToInstruction, TOKEN_2022_PROGRAM_ID, getAssociatedTokenAddressSync } = await import("@solana/spl-token");
const arg = (k, d) => { const i = process.argv.indexOf("--" + k); return i < 0 ? d : process.argv[i + 1]; };
const conn = new W3.Connection(arg("url", "http://127.0.0.1:8899"), "confirmed");
const payer = W3.Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(arg("payer"), "utf8"))));
const send = async (ixs, signers, label) => {
  const tx = new W3.Transaction().add(...ixs);
  const sig = await W3.sendAndConfirmTransaction(conn, tx, signers, { commitment: "confirmed" });
  console.log("ok  ", label, sig.slice(0, 16));
  return sig;
};
const expectFail = async (p, code, label) => { try { await p(); } catch (e) { const m = String(e.message) + String(e.logs || ""); if (m.includes(code) || (e.transactionLogs || []).join().includes(code)) { console.log("ok  ", label, "(" + code + ")"); return; } throw e; } throw new Error(label + ": expected " + code); };
const assert = (c, m) => { if (!c) throw new Error("ASSERT " + m); };

const hot = W3.Keypair.generate(), cold = W3.Keypair.generate(), g = W3.Keypair.generate();
await send([W3.SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: hot.publicKey, lamports: 3e9 }), W3.SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: cold.publicKey, lamports: 1e8 })], [payer], "fund");
await C.findSanctums(conn, hot.publicKey); // sets conn
const r = await C.ix.create({ hot: hot.publicKey, cold: cold.publicKey, guardians: [g.publicKey] });
await send(r.instructions, [hot], "create");
const S = r.sanctum;
const found = await C.findSanctums(conn, hot.publicKey);
assert(found.length === 1 && found[0].role === "hot", "findSanctums hot");
assert((await C.findSanctums(conn, g.publicKey))[0].role === "guardian", "findSanctums guardian");
await send(await C.ix.deposit({ sanctum: S, from: hot.publicKey, mint: null, amount: 1_000_000_000n }), [hot], "deposit 1 SOL");
let D = await C.fetchSanctum(conn, S.toBase58());
assert(D.assets[0].amount === 1_000_000_000n && D.assets[0].sendsNow === 50_000_000n, "sendsNow 5%");
const dest = W3.Keypair.generate().publicKey;
await send(await C.ix.withdraw({ sanctum: S, hot: hot.publicKey, mint: null, to: dest, amount: 50_000_000n }), [hot], "withdraw 5% paid");
assert((await conn.getBalance(dest)) === 50_000_000, "paid");
await send(await C.ix.withdraw({ sanctum: S, hot: hot.publicKey, mint: null, to: dest, amount: 200_000_000n }), [hot], "withdraw 20% queued");
D = await C.fetchSanctum(conn, S.toBase58());
assert(D.queue.length === 1 && D.queue[0].amount === 200_000_000n && !D.queue[0].voided, "queue listed");
await send(await C.ix.approve({ sanctum: S, cold: cold.publicKey, seq: 0 }), [cold], "approve");
await send(await C.ix.setWatchers({ sanctum: S, cold: cold.publicKey, on: true }), [cold], "watchers on (forces approval mode)");
D = await C.fetchSanctum(conn, S.toBase58());
assert(D.watchersOn && D.approvalMode, "modes");
await send(await C.ix.setApprovalMode({ sanctum: S, cold: cold.publicKey, on: false }), [cold], "approval off (watchers off too)");
D = await C.fetchSanctum(conn, S.toBase58());
assert(!D.watchersOn && !D.approvalMode, "modes off");

// Token-2022
const mint = W3.Keypair.generate();
const hotAta = getAssociatedTokenAddressSync(mint.publicKey, hot.publicKey, false, TOKEN_2022_PROGRAM_ID);
await send([
  W3.SystemProgram.createAccount({ fromPubkey: payer.publicKey, newAccountPubkey: mint.publicKey, lamports: await conn.getMinimumBalanceForRentExemption(82), space: 82, programId: TOKEN_2022_PROGRAM_ID }),
  createInitializeMint2Instruction(mint.publicKey, 6, payer.publicKey, null, TOKEN_2022_PROGRAM_ID),
  createAssociatedTokenAccountIdempotentInstruction(payer.publicKey, hotAta, hot.publicKey, mint.publicKey, TOKEN_2022_PROGRAM_ID),
  createMintToInstruction(mint.publicKey, hotAta, payer.publicKey, 1_000_000_000n, [], TOKEN_2022_PROGRAM_ID),
], [payer, mint], "Token-2022 mint");
await send(await C.ix.deposit({ sanctum: S, from: hot.publicKey, mint: mint.publicKey, amount: 1_000_000_000n }), [hot], "deposit Token-2022");
D = await C.fetchSanctum(conn, S.toBase58());
const tok = D.assets.find((a) => a.mint === mint.publicKey.toBase58());
assert(tok && tok.amount === 1_000_000_000n && tok.decimals === 6 && tok.sendsNow === 50_000_000n, "token asset");
const tdest = W3.Keypair.generate().publicKey;
await send(await C.ix.withdraw({ sanctum: S, hot: hot.publicKey, mint: mint.publicKey, to: tdest, amount: 50_000_000n }), [hot], "withdraw token to wallet (ATA created)");
const tb = await conn.getTokenAccountBalance(getAssociatedTokenAddressSync(mint.publicKey, tdest, false, TOKEN_2022_PROGRAM_ID));
assert(tb.value.amount === "50000000", "token paid");
await send(await C.ix.withdraw({ sanctum: S, hot: hot.publicKey, mint: mint.publicKey, to: tdest, amount: 300_000_000n }), [hot], "withdraw token 30% queued");
D = await C.fetchSanctum(conn, S.toBase58());
assert(D.queue.length === 2 && D.queue[1].mint === mint.publicKey.toBase58() && D.queue[1].decimals === 6, "token queued");
await send(await C.ix.cancel({ sanctum: S, signer: hot.publicKey, seq: D.queue[1].seq }), [hot], "cancel token queue item");

// panic / rotate
await send(await C.ix.panic({ sanctum: S, signer: g.publicKey }), [payer, g], "guardian panic");
D = await C.fetchSanctum(conn, S.toBase58());
assert(D.frozenUntil > Date.now() / 1000 && D.queue[0].voided, "frozen + voided");
await expectFail(async () => send(await C.ix.withdraw({ sanctum: S, hot: hot.publicKey, mint: null, to: dest, amount: 1000n }), [hot], "x"), "Frozen", "withdraw while frozen");
const nh = W3.Keypair.generate();
await send(await C.ix.unfreezeAndRotate({ sanctum: S, cold: cold.publicKey, newHot: nh.publicKey }), [cold], "unfreezeAndRotate");
D = await C.fetchSanctum(conn, S.toBase58());
assert(D.hot === nh.publicKey.toBase58() && D.frozenUntil === 0, "rotated");
await send(await C.ix.cancel({ sanctum: S, signer: cold.publicKey, seq: 0 }), [cold], "cancel voided item");

// node
const smint = arg("mint");
if (smint) {
  const before = await C.node.fetch(conn, payer.publicKey);
  await send(await C.node.ix.stake({ owner: payer.publicKey, amount: 100_000_000_000n }), [payer], "node stake +100k");
  const after = await C.node.fetch(conn, payer.publicKey);
  assert(after.stake === before.stake + 100_000_000_000n && after.registered && after.decimals === 6, "node stake");
  const op = W3.Keypair.generate();
  await send([W3.SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: op.publicKey, lamports: 1e8 }),
    createAssociatedTokenAccountIdempotentInstruction(payer.publicKey, getAssociatedTokenAddressSync(new W3.PublicKey(smint), op.publicKey, false, TOKEN_2022_PROGRAM_ID), op.publicKey, new W3.PublicKey(smint), TOKEN_2022_PROGRAM_ID),
    createMintToInstruction(new W3.PublicKey(smint), getAssociatedTokenAddressSync(new W3.PublicKey(smint), op.publicKey, false, TOKEN_2022_PROGRAM_ID), payer.publicKey, 2_000_000_000_000n, [], TOKEN_2022_PROGRAM_ID)], [payer], "fund operator");
  await send(await C.node.ix.register({ owner: op.publicKey }), [op], "node register (min stake)");
  await send(await C.node.ix.unstake({ owner: op.publicKey, amount: 1n }), [op], "node unstake (cooldown starts)");
  const n2 = await C.node.fetch(conn, op.publicKey);
  assert(n2.unstakeReadyAt > 0 && !n2.active, "unstaking");
}
console.log("\nSITE CLIENT: ALL OK");
