// Uroboros watcher node (Node 22, ESM). Polls the Sanctum program for Sanctums with watchers_on and fires
// watcher_panic on any live, unapproved queue item in its final hour. The program re-checks every condition, so a
// wrong call just fails (costs a fee) — it can never freeze a Sanctum that does not qualify.
//
//   RPC_URL=https://... NODE_KEYPAIR=/path/node.json [STATUS_FILE=./watcher-status.json] [POLL_SECS=30] [DRY_RUN=1] \
//     node watcher/watcher.mjs
//
// The node key must be registered with an active stake (register_node). Keep a little SOL on it for fees.
// getProgramAccounts must be allowed by the RPC (public api.mainnet-beta allows it with filters; Helius/Triton too).
import { Connection, Keypair, Transaction, sendAndConfirmTransaction, ComputeBudgetProgram } from "@solana/web3.js";
import { readFileSync, writeFileSync } from "node:fs";
import * as S from "../client/sanctum.js";

const RPC = process.env.RPC_URL || "https://api.mainnet-beta.solana.com";
const POLL = Number(process.env.POLL_SECS || 30) * 1000;
const STATUS = process.env.STATUS_FILE || "watcher-status.json";
const DRY = !!process.env.DRY_RUN;
const ONCE = process.argv.includes("--once");
const kp = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(process.env.NODE_KEYPAIR, "utf8"))));
const conn = new Connection(RPC, "confirmed");
const log = (...a) => console.log(new Date().toISOString(), ...a);
const status = { node: kp.publicKey.toBase58(), program: S.PROGRAM_ID.toBase58(), rpc: RPC.replace(/api-key=[^&]+/, "api-key=***"), startedAt: new Date().toISOString(), polls: 0, lastPollAt: null, lastError: null, nodeState: null, watched: 0, candidates: [], panics: [] };
const save = () => { try { writeFileSync(STATUS, JSON.stringify(status, (k, v) => (typeof v === "bigint" ? v.toString() : v), 2)); } catch (e) { log("status write failed", e.message); } };
const tried = new Map(); // queued address -> last attempt ms (avoid hammering a failing item)

async function chainNow() {
  const slot = await conn.getSlot("confirmed");
  return (await conn.getBlockTime(slot)) ?? Math.floor(Date.now() / 1000);
}

async function poll() {
  await S.ready();
  const now = await chainNow();
  const nodeAcc = await conn.getAccountInfo(S.pda.node(kp.publicKey));
  const cfgAcc = await conn.getAccountInfo(S.pda.config());
  if (!nodeAcc || !cfgAcc) { status.nodeState = "not registered"; log("node not registered (register_node first)"); return; }
  const node = S.decodeNode(nodeAcc.data), cfg = S.decodeConfig(cfgAcc.data);
  const active = node.unstakeAt === 0n && node.stake >= cfg.minStake;
  status.nodeState = { stake: node.stake, minStake: cfg.minStake, active, panics: node.panics };
  if (!active) { log("node not active (unstaking or below min stake) — not panicking"); return; }

  // Sanctums with watchers_on (byte offset 287 of the 289-byte account)
  const sanctums = await conn.getProgramAccounts(S.PROGRAM_ID, { filters: [{ dataSize: S.SIZES.Sanctum }, { memcmp: { offset: 287, bytes: "2" } }] }); // base58 "2" = 0x01
  status.watched = sanctums.length;
  const candidates = [];
  for (const { pubkey, account } of sanctums) {
    const s = S.decodeSanctum(account.data);
    if (!s.watchersOn) continue;
    if (BigInt(now) < s.guardianMutedUntil) continue; // muted after a cold unfreeze
    if (BigInt(now) + 3600n < s.frozenUntil) continue; // already frozen (re-panic only in the last hour)
    const items = await S.fetchQueue(conn, pubkey);
    for (const q of items) {
      if (q.approved || q.panicEpoch !== s.panicEpoch) continue;
      if (BigInt(now) < q.readyAt - 3600n) continue;
      candidates.push({ sanctum: pubkey.toBase58(), seq: q.seq, amount: q.amount, mint: q.mint.toBase58(), to: q.to.toBase58(), readyAt: Number(q.readyAt), address: q.address.toBase58() });
    }
  }
  status.candidates = candidates;
  for (const c of candidates) {
    const last = tried.get(c.address) || 0;
    if (Date.now() - last < 5 * 60_000) continue;
    tried.set(c.address, Date.now());
    log(`unapproved queue item in final hour: sanctum ${c.sanctum} #${c.seq} amount ${c.amount} -> ${c.to}`);
    if (DRY) { log("DRY_RUN: not sending"); continue; }
    try {
      const tx = new Transaction().add(ComputeBudgetProgram.setComputeUnitPrice({ microLamports: 50_000 }),
        S.watcherPanic({ operator: kp.publicKey, sanctum: c.sanctum, seq: BigInt(c.seq) }));
      const sig = await sendAndConfirmTransaction(conn, tx, [kp], { commitment: "confirmed" });
      log("WATCHER PANIC sent", sig);
      status.panics.push({ at: new Date().toISOString(), ...c, signature: sig });
    } catch (e) {
      log("watcher_panic failed:", e.message.split("\n")[0]);
      status.lastError = e.message.slice(0, 500);
    }
  }
}

log(`watcher node ${kp.publicKey.toBase58()} on ${status.rpc}, program ${status.program}${DRY ? " (DRY RUN)" : ""}`);
for (;;) {
  try { await poll(); status.lastError = status.lastError; } catch (e) { status.lastError = e.message.slice(0, 500); log("poll error:", e.message); }
  status.polls++; status.lastPollAt = new Date().toISOString(); save();
  if (ONCE) break;
  await new Promise((r) => setTimeout(r, POLL));
}
