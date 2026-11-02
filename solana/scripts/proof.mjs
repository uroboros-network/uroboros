// End-to-end proof against a live cluster.
//   node scripts/proof.mjs --url <rpc> --payer <keypair.json> [--sol 0.1] [--staking] [--out proof-<cluster>.json]
// create -> deposit -> withdraw 4% (paid now) -> withdraw 20% (queued) -> guardian panic -> frozen withdraw fails
// -> cold unfreeze -> re-queue (-> cancel, rent back). With --staking (devnet/local ONLY: it calls init_staking with a
// throwaway Token-2022 mint, which can only be done once per program): init_staking, register node, add stake,
// watcher panic is not exercised live (needs a 6h wait) — it is covered by tests/nodes.test.mjs.
// The payer key is read from a file and never printed. Fresh hot/cold/guardian keys are generated per run.
import { ComputeBudgetProgram, Connection, Keypair, PublicKey, SystemProgram, Transaction, sendAndConfirmTransaction, LAMPORTS_PER_SOL } from "@solana/web3.js";
import { readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import * as S from "../client/sanctum.js";

const arg = (k, d) => { const i = process.argv.indexOf("--" + k); return i < 0 ? d : (process.argv[i + 1] && !process.argv[i + 1].startsWith("--") ? process.argv[i + 1] : true); };
const url = arg("url", "http://127.0.0.1:8899");
const payer = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(String(arg("payer")).replace(/^~/, homedir()), "utf8"))));
const sol = Number(arg("sol", "0.1"));
const cluster = url.includes("devnet") ? "devnet" : url.includes("mainnet") ? "mainnet-beta" : "custom";
const out = arg("out", `proof-${cluster === "custom" ? "local" : cluster}.json`);
const conn = new Connection(url, "confirmed");
const explorer = (sig) => cluster === "custom"
  ? `https://explorer.solana.com/tx/${sig}?cluster=custom&customUrl=${encodeURIComponent(url)}`
  : `https://explorer.solana.com/tx/${sig}${cluster === "devnet" ? "?cluster=devnet" : ""}`;
const steps = [];
async function send(name, ixs, signers, note) {
  const tx = new Transaction().add(...ixs);
  const sig = await sendAndConfirmTransaction(conn, tx, signers, { commitment: "confirmed" });
  steps.push({ step: name, ok: true, signature: sig, explorer: explorer(sig), ...(note ? { note } : {}) });
  console.log(`ok   ${name}  ${sig}`);
  return sig;
}
let uniq = 200_000;
async function expectFail(name, ixs, signers, code) {
  // unique CU limit so the simulated tx never collides with an identical earlier signature
  const tx = new Transaction().add(ComputeBudgetProgram.setComputeUnitLimit({ units: uniq++ }), ...ixs);
  tx.feePayer = signers[0].publicKey;
  tx.recentBlockhash = (await conn.getLatestBlockhash()).blockhash;
  tx.sign(...signers);
  const sim = await conn.simulateTransaction(tx);
  const logs = (sim.value.logs || []).join("\n");
  const failed = !!sim.value.err && logs.includes(code);
  steps.push({ step: name, ok: failed, expectedError: code, simulatedError: JSON.stringify(sim.value.err), log: (sim.value.logs || []).find((l) => l.includes("Error Code")) || null });
  console.log(`${failed ? "ok  " : "FAIL"} ${name} (expected ${code})`);
  if (!failed) throw new Error(`${name}: expected ${code}\n${logs}`);
}

await S.ready();
const info = await conn.getAccountInfo(S.PROGRAM_ID);
if (!info || !info.executable) throw new Error(`program ${S.PROGRAM_ID.toBase58()} not deployed on ${url}`);
const hot = Keypair.generate(), cold = Keypair.generate(), guardian = Keypair.generate();
const fund = Math.round((sol + 0.02) * LAMPORTS_PER_SOL);
await send("fund test keys (hot, cold, guardian)", [
  SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: hot.publicKey, lamports: fund }),
  SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: cold.publicKey, lamports: 5_000_000 }),
  SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: guardian.publicKey, lamports: 5_000_000 }),
], [payer]);

const sanctum = S.pda.sanctum(hot.publicKey, 0n);
await send("create", [S.create({ hot: hot.publicKey, cold: cold.publicKey, guardians: [guardian.publicKey] })], [hot]);
const amount = BigInt(Math.round(sol * LAMPORTS_PER_SOL));
await send(`deposit ${sol} SOL`, [S.depositSol({ depositor: hot.publicKey, sanctum, amount })], [hot]);
const seq = async () => (await S.fetchSanctum(conn, sanctum)).queueSeq;
const destBefore = await conn.getBalance(hot.publicKey);
await send("withdraw 4% (paid now)", [S.withdrawSol({ hot: hot.publicKey, sanctum, to: hot.publicKey, amount: (amount * 4n) / 100n, queueSeq: await seq() })], [hot]);
if ((await seq()) !== 0n) throw new Error("4% was queued");
const s1 = await seq();
await send("withdraw 20% (queued, 6h)", [S.withdrawSol({ hot: hot.publicKey, sanctum, to: hot.publicKey, amount: (amount * 20n) / 100n, queueSeq: s1 })], [hot]);
const q = S.decodeQueued((await conn.getAccountInfo(S.pda.queued(sanctum, s1))).data);
steps[steps.length - 1].queued = { seq: Number(q.seq), amount: q.amount.toString(), readyAt: new Date(Number(q.readyAt) * 1000).toISOString() };
await send("guardian panic (24h freeze, voids queue)", [S.panic({ signer: guardian.publicKey, sanctum })], [guardian]);
await expectFail("withdraw while frozen fails", [S.withdrawSol({ hot: hot.publicKey, sanctum, to: hot.publicKey, amount: 1000n, queueSeq: await seq() })], [hot], "Frozen");
await expectFail("guardian cannot stack a second freeze", [S.panic({ signer: guardian.publicKey, sanctum })], [guardian], "FrozenLastHourOnly");
await send("cold unfreeze (guardians + hot muted 24h)", [S.unfreeze({ cold: cold.publicKey, sanctum })], [cold]);
await expectFail("queued item voided by the panic", [S.executeQueuedSol({ signer: hot.publicKey, sanctum, seq: s1, payer: hot.publicKey, to: hot.publicKey })], [hot], "VoidedByPanic");
await send("cancel voided item (rent back)", [S.cancelQueued({ signer: hot.publicKey, sanctum, seq: s1, payer: hot.publicKey })], [hot]);
const s2 = await seq();
await send("re-queue 20%", [S.withdrawSol({ hot: hot.publicKey, sanctum, to: hot.publicKey, amount: (amount * 20n) / 100n, queueSeq: s2 })], [hot]);
await expectFail("guardian muted after unfreeze", [S.panic({ signer: guardian.publicKey, sanctum })], [guardian], "GuardianMuted");
const newHot = Keypair.generate();
await send("cold panic + unfreeze_and_rotate (new hot key)", [S.panic({ signer: cold.publicKey, sanctum }), S.unfreezeAndRotate({ cold: cold.publicKey, sanctum, newHot: newHot.publicKey })], [cold]);
await expectFail("old hot key rejected", [S.withdrawSol({ hot: hot.publicKey, sanctum, to: hot.publicKey, amount: 1000n, queueSeq: await seq() })], [hot], "Unauthorized");

let staking = null;
if (arg("staking", false) === true) {
  if (cluster === "mainnet-beta") throw new Error("--staking is for devnet/local only (init_staking can run once; on mainnet use scripts/init-staking.mjs with the real mint)");
  const { createInitializeMint2Instruction, createAssociatedTokenAccountIdempotentInstruction, createMintToInstruction, TOKEN_2022_PROGRAM_ID, getAssociatedTokenAddressSync } = await import("@solana/spl-token");
  const mint = Keypair.generate();
  const rent = await conn.getMinimumBalanceForRentExemption(82);
  const opAta = getAssociatedTokenAddressSync(mint.publicKey, payer.publicKey, false, TOKEN_2022_PROGRAM_ID);
  await send("create test Token-2022 mint + mint 10M", [
    SystemProgram.createAccount({ fromPubkey: payer.publicKey, newAccountPubkey: mint.publicKey, lamports: rent, space: 82, programId: TOKEN_2022_PROGRAM_ID }),
    createInitializeMint2Instruction(mint.publicKey, 6, payer.publicKey, null, TOKEN_2022_PROGRAM_ID),
    createAssociatedTokenAccountIdempotentInstruction(payer.publicKey, opAta, payer.publicKey, mint.publicKey, TOKEN_2022_PROGRAM_ID),
    createMintToInstruction(mint.publicKey, opAta, payer.publicKey, 10_000_000_000_000n, [], TOKEN_2022_PROGRAM_ID),
  ], [payer, mint]);
  await send("init_staking (upgrade authority, min 1M, cooldown 3d)", [S.initStaking({ admin: payer.publicKey, mint: mint.publicKey, minStake: 1_000_000_000_000n, cooldownSecs: 259200n })], [payer]);
  await send("register node (1M staked)", [S.registerNode({ operator: payer.publicKey, mint: mint.publicKey, amount: 1_000_000_000_000n })], [payer]);
  await send("add stake (+0.5M)", [S.addStake({ operator: payer.publicKey, mint: mint.publicKey, amount: 500_000_000_000n })], [payer]);
  const node = S.decodeNode((await conn.getAccountInfo(S.pda.node(payer.publicKey))).data);
  staking = { mint: mint.publicKey.toBase58(), config: S.pda.config().toBase58(), node: S.pda.node(payer.publicKey).toBase58(), stake: node.stake.toString() };
}

const result = {
  cluster, rpc: url.replace(/api-key=[^&]+/, "api-key=***"), programId: S.PROGRAM_ID.toBase58(), at: new Date().toISOString(),
  sanctum: sanctum.toBase58(), vault: S.pda.vault(sanctum).toBase58(),
  keys: { hot: hot.publicKey.toBase58(), cold: cold.publicKey.toBase58(), guardian: guardian.publicKey.toBase58(), rotatedHot: newHot.publicKey.toBase58() },
  steps, staking, allOk: steps.every((s) => s.ok),
};
writeFileSync(out, JSON.stringify(result, null, 2));
// The throwaway keys hold what is left in the vault: save them next to the proof (local file, never commit/share it)
// so the cold key can withdraw the rest later (5%/h, 10%/24h) with scripts/recover.mjs.
const keyOut = out.replace(/\.json$/, "") + ".KEYS-SECRET.json";
writeFileSync(keyOut, JSON.stringify({ sanctum: sanctum.toBase58(), hot: Array.from(newHot.secretKey), cold: Array.from(cold.secretKey), guardian: Array.from(guardian.secretKey) }), { mode: 0o600 });
console.log(`throwaway keys saved to ${keyOut} (needed to recover the remaining vault balance)`);
console.log(`\n${result.allOk ? "ALL OK" : "SOME STEPS FAILED"} -> ${out}`);
// leftover: the vault keeps ~76% of the deposit (caps + queue protect it); the test cold key can drain it slowly.
