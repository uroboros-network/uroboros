// Uroboros Sanctum (Solana) — tiny ESM client. Depends only on @solana/web3.js v1.
// Browser: <script type="importmap">{"imports":{"@solana/web3.js":"https://esm.sh/@solana/web3.js@1.98.4"}}</script>
// then: import * as S from "./sanctum.js";
import { PublicKey, SystemProgram, TransactionInstruction } from "@solana/web3.js";

export const PROGRAM_ID = new PublicKey("C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj");
export const TOKEN_PROGRAM_ID = new PublicKey("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");
export const TOKEN_2022_PROGRAM_ID = new PublicKey("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb");
export const ATA_PROGRAM_ID = new PublicKey("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL");
export const SOL_MINT = new PublicKey(new Uint8Array(32)); // 1111...1111: SOL marker for caps + queue items
export const DEFAULT_RULES = { capBps: 500, dayCapBps: 1000, delayBps: 1000, delaySecs: 6n * 3600n };
export const HOUR = 3600;

// Anchor discriminators, from target/idl/sanctum.json (sha256("global:<ix>")[0..8], sha256("account:<Name>")[0..8])
const IX = {"add_stake": [58, 135, 189, 105, 160, 120, 165, 224], "apply_rules": [57, 22, 71, 185, 168, 212, 204, 183], "approve_queued": [26, 242, 51, 188, 161, 28, 42, 244], "cancel_queued": [160, 77, 212, 172, 218, 230, 205, 84], "cold_set_rules": [65, 122, 146, 51, 245, 77, 205, 4], "cold_withdraw_sol": [175, 20, 3, 10, 108, 68, 168, 187], "cold_withdraw_token": [249, 121, 123, 22, 217, 202, 147, 158], "create": [24, 30, 200, 40, 5, 28, 7, 119], "deposit_sol": [108, 81, 78, 117, 125, 155, 56, 200], "deposit_token": [11, 156, 96, 218, 39, 163, 180, 19], "execute_queued_sol": [184, 122, 1, 124, 3, 167, 148, 240], "execute_queued_token": [163, 116, 203, 43, 252, 6, 199, 69], "init_staking": [42, 18, 242, 224, 66, 32, 122, 8], "panic": [53, 209, 63, 219, 113, 108, 125, 195], "propose_rules": [150, 130, 56, 145, 104, 78, 147, 17], "register_node": [102, 85, 117, 114, 194, 188, 211, 168], "request_unstake": [44, 154, 110, 253, 160, 202, 54, 34], "set_cold": [184, 148, 203, 134, 124, 225, 4, 220], "set_guardians": [166, 69, 140, 183, 157, 169, 253, 40], "set_hot": [22, 253, 63, 166, 150, 170, 43, 104], "set_modes": [102, 54, 218, 62, 127, 203, 246, 120], "slash": [204, 141, 18, 161, 8, 177, 92, 142], "unfreeze": [133, 160, 68, 253, 80, 232, 218, 247], "unfreeze_and_rotate": [9, 76, 159, 207, 18, 34, 77, 25], "watcher_panic": [131, 12, 205, 149, 28, 18, 107, 231], "withdraw_sol": [145, 131, 74, 136, 65, 137, 42, 38], "withdraw_stake": [153, 8, 22, 138, 105, 176, 87, 66], "withdraw_token": [136, 235, 181, 5, 101, 109, 57, 81]};
const ACC = {"CapState": [232, 243, 86, 114, 168, 251, 42, 233], "Config": [155, 12, 170, 224, 30, 250, 204, 130], "Node": [208, 53, 1, 3, 49, 122, 180, 49], "Queued": [38, 212, 89, 248, 54, 112, 194, 83], "Sanctum": [31, 19, 136, 14, 30, 238, 32, 13]};
/** Kept for API compatibility (discriminators are static now). */
export function ready() { return Promise.resolve(); }
export function accountDiscriminator(name) { return Uint8Array.from(ACC[name]); }

// ---------------------------------------------------------------- bytes
const toBuf = (u8) => (typeof Buffer !== "undefined" ? Buffer.from(u8) : u8);
class W {
  constructor() { this.b = []; }
  u8(v) { this.b.push(Number(v) & 255); return this; }
  bool(v) { return this.u8(v ? 1 : 0); }
  u16(v) { v = Number(v); this.b.push(v & 255, (v >> 8) & 255); return this; }
  u32(v) { v = Number(v); for (let i = 0; i < 4; i++) this.b.push((v >>> (8 * i)) & 255); return this; }
  u64(v) { let x = BigInt.asUintN(64, BigInt(v)); for (let i = 0; i < 8; i++) { this.b.push(Number(x & 255n)); x >>= 8n; } return this; }
  i64(v) { return this.u64(BigInt.asUintN(64, BigInt(v))); }
  pk(p) { this.b.push(...new PublicKey(p).toBytes()); return this; }
  raw(a) { this.b.push(...a); return this; }
  rules(r) { return this.u16(r.capBps).u16(r.dayCapBps).u16(r.delayBps).i64(r.delaySecs); }
  done() { return toBuf(Uint8Array.from(this.b)); }
}
class R {
  constructor(data) { this.d = data instanceof Uint8Array ? data : Uint8Array.from(data); this.o = 8; }
  u8() { return this.d[this.o++]; }
  bool() { return this.u8() !== 0; }
  u16() { const v = this.d[this.o] | (this.d[this.o + 1] << 8); this.o += 2; return v; }
  uN(n) { let x = 0n; for (let i = n - 1; i >= 0; i--) x = (x << 8n) | BigInt(this.d[this.o + i]); this.o += n; return x; }
  u64() { return this.uN(8); }
  i64() { return BigInt.asIntN(64, this.uN(8)); }
  u128() { return this.uN(16); }
  pk() { const p = new PublicKey(this.d.subarray(this.o, this.o + 32)); this.o += 32; return p; }
  rules() { return { capBps: this.u16(), dayCapBps: this.u16(), delayBps: this.u16(), delaySecs: this.i64() }; }
}
const data = (name) => new W().raw(IX[name]);
const m = (pubkey, isSigner, isWritable) => ({ pubkey: new PublicKey(pubkey), isSigner, isWritable });
const ix = (keys, d) => new TransactionInstruction({ programId: PROGRAM_ID, keys, data: d });
const u64le = (n) => { const w = new W().u64(n); return Uint8Array.from(w.b); };

// ---------------------------------------------------------------- PDAs
export const pda = {
  sanctum: (creator, nonce = 0n) =>
    PublicKey.findProgramAddressSync([new TextEncoder().encode("sanctum"), new PublicKey(creator).toBytes(), u64le(nonce)], PROGRAM_ID)[0],
  vault: (sanctum) => PublicKey.findProgramAddressSync([new TextEncoder().encode("vault"), new PublicKey(sanctum).toBytes()], PROGRAM_ID)[0],
  cap: (sanctum, mint = SOL_MINT) =>
    PublicKey.findProgramAddressSync([new TextEncoder().encode("cap"), new PublicKey(sanctum).toBytes(), new PublicKey(mint).toBytes()], PROGRAM_ID)[0],
  queued: (sanctum, seq) =>
    PublicKey.findProgramAddressSync([new TextEncoder().encode("q"), new PublicKey(sanctum).toBytes(), u64le(seq)], PROGRAM_ID)[0],
  config: () => PublicKey.findProgramAddressSync([new TextEncoder().encode("config")], PROGRAM_ID)[0],
  stakeVault: () => PublicKey.findProgramAddressSync([new TextEncoder().encode("stake_vault")], PROGRAM_ID)[0],
  node: (operator) => PublicKey.findProgramAddressSync([new TextEncoder().encode("node"), new PublicKey(operator).toBytes()], PROGRAM_ID)[0],
  programData: () => PublicKey.findProgramAddressSync([PROGRAM_ID.toBytes()], new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111"))[0],
};
export function ata(owner, mint, tokenProgram = TOKEN_2022_PROGRAM_ID) {
  return PublicKey.findProgramAddressSync(
    [new PublicKey(owner).toBytes(), new PublicKey(tokenProgram).toBytes(), new PublicKey(mint).toBytes()], ATA_PROGRAM_ID)[0];
}

// ---------------------------------------------------------------- decoders
export function decodeSanctum(d) {
  const r = new R(d);
  const o = { creator: r.pk(), nonce: r.u64(), hot: r.pk(), cold: r.pk() };
  const g = [r.pk(), r.pk(), r.pk()];
  const n = r.u8();
  o.guardians = g.slice(0, n);
  Object.assign(o, {
    rules: r.rules(), pendingRules: r.rules(), rulesReadyAt: r.i64(), frozenUntil: r.i64(), lastPanicAt: r.i64(),
    guardianMutedUntil: r.i64(), panicEpoch: r.u64(), queueSeq: r.u64(), bump: r.u8(), vaultBump: r.u8(),
    watchersOn: r.bool(), approvalMode: r.bool(),
  });
  return o;
}
export function decodeCapState(d) {
  const r = new R(d);
  const o = { sanctum: r.pk(), mint: r.pk(), windowStart: r.i64(), windowBalance: r.u128(), windowSpent: r.u128(), ring: [] };
  for (let i = 0; i < 25; i++) o.ring.push({ hour: r.i64(), spent: r.u128() });
  o.initialized = r.bool();
  return o;
}
export function decodeQueued(d) {
  const r = new R(d);
  return {
    sanctum: r.pk(), seq: r.u64(), mint: r.pk(), to: r.pk(), amount: r.u64(), queuedAt: r.i64(), readyAt: r.i64(),
    panicEpoch: r.u64(), approved: r.bool(), payer: r.pk(), bump: r.u8(),
  };
}
export function decodeConfig(d) {
  const r = new R(d);
  return {
    admin: r.pk(), mint: r.pk(), tokenProgram: r.pk(), stakeVault: r.pk(), minStake: r.u64(), unstakeCooldown: r.i64(),
    totalStaked: r.u64(), nodeCount: r.u64(), bump: r.u8(), vaultBump: r.u8(),
  };
}
export function decodeNode(d) {
  const r = new R(d);
  return { operator: r.pk(), stake: r.u64(), unstakeAt: r.i64(), registeredAt: r.i64(), slashedTotal: r.u64(), panics: r.u64(), bump: r.u8() };
}

/** Pure mirror of the on-chain cap room (for UI: "you can send X now without queueing"). */
export function capRoom(cap, rules, bal, now) {
  bal = BigInt(bal); now = BigInt(now);
  const H = 3600n;
  const fresh = !cap || !cap.initialized || now >= cap.windowStart + H;
  const hourBal = fresh ? bal : cap.windowBalance;
  const hourSpent = fresh ? 0n : cap.windowSpent;
  const hourCap = (hourBal * BigInt(rules.capBps)) / 10000n;
  const hRoom = hourCap > hourSpent ? hourCap - hourSpent : 0n;
  let spent24 = 0n;
  if (cap) { const h = now / H; for (const s of cap.ring) if (s.spent > 0n && s.hour + 25n > h) spent24 += s.spent; }
  const dayCap = ((bal + spent24) * BigInt(rules.dayCapBps)) / 10000n;
  const dRoom = dayCap > spent24 ? dayCap - spent24 : 0n;
  return hRoom < dRoom ? hRoom : dRoom;
}
/** Would a hot-key withdraw of `amount` be queued? */
export function willQueue(cap, rules, bal, amount, now) {
  amount = BigInt(amount); bal = BigInt(bal);
  return amount * 10000n > bal * BigInt(rules.delayBps) || amount > capRoom(cap, rules, bal, now);
}

// ---------------------------------------------------------------- instructions (Sanctum)
export function create({ hot, cold, guardians = [], nonce = 0n, rules = null }) {
  const sanctum = pda.sanctum(hot, nonce);
  const w = data("create").u64(nonce).pk(cold).u32(guardians.length);
  for (const g of guardians) w.pk(g);
  if (rules) w.u8(1).rules(rules); else w.u8(0);
  return ix([m(hot, true, true), m(sanctum, false, true), m(pda.vault(sanctum), false, true), m(SystemProgram.programId, false, false)], w.done());
}
export function depositSol({ depositor, sanctum, amount }) {
  return ix([m(depositor, true, true), m(sanctum, false, false), m(pda.vault(sanctum), false, true), m(SystemProgram.programId, false, false)],
    data("deposit_sol").u64(amount).done());
}
export function depositToken({ depositor, sanctum, mint, from, amount, tokenProgram = TOKEN_2022_PROGRAM_ID }) {
  const vault = pda.vault(sanctum);
  from = from || ata(depositor, mint, tokenProgram);
  return ix([
    m(depositor, true, true), m(sanctum, false, false), m(vault, false, false), m(mint, false, false), m(from, false, true),
    m(ata(vault, mint, tokenProgram), false, true), m(tokenProgram, false, false), m(ATA_PROGRAM_ID, false, false),
    m(SystemProgram.programId, false, false),
  ], data("deposit_token").u64(amount).done());
}
/** `queueSeq` = current sanctum.queueSeq (the item address used if the transfer gets queued). */
export function withdrawSol({ hot, sanctum, to, amount, queueSeq }) {
  return ix([
    m(hot, true, true), m(sanctum, false, true), m(pda.vault(sanctum), false, true), m(pda.cap(sanctum), false, true),
    m(pda.queued(sanctum, queueSeq), false, true), m(to, false, true), m(SystemProgram.programId, false, false),
  ], data("withdraw_sol").u64(amount).done());
}
export function withdrawToken({ hot, sanctum, mint, to, amount, queueSeq, tokenProgram = TOKEN_2022_PROGRAM_ID }) {
  const vault = pda.vault(sanctum);
  return ix([
    m(hot, true, true), m(sanctum, false, true), m(vault, false, false), m(mint, false, false), m(ata(vault, mint, tokenProgram), false, true),
    m(pda.cap(sanctum, mint), false, true), m(pda.queued(sanctum, queueSeq), false, true), m(to, false, true),
    m(tokenProgram, false, false), m(SystemProgram.programId, false, false),
  ], data("withdraw_token").u64(amount).done());
}
export function executeQueuedSol({ signer, sanctum, seq, payer, to }) {
  return ix([
    m(signer, true, true), m(sanctum, false, false), m(pda.vault(sanctum), false, true), m(pda.queued(sanctum, seq), false, true),
    m(payer, false, true), m(to, false, true), m(SystemProgram.programId, false, false),
  ], data("execute_queued_sol").done());
}
export function executeQueuedToken({ signer, sanctum, seq, payer, mint, to, tokenProgram = TOKEN_2022_PROGRAM_ID }) {
  const vault = pda.vault(sanctum);
  return ix([
    m(signer, true, true), m(sanctum, false, false), m(vault, false, false), m(pda.queued(sanctum, seq), false, true), m(payer, false, true),
    m(mint, false, false), m(ata(vault, mint, tokenProgram), false, true), m(to, false, true), m(tokenProgram, false, false),
  ], data("execute_queued_token").done());
}
export function cancelQueued({ signer, sanctum, seq, payer }) {
  return ix([m(signer, true, false), m(sanctum, false, false), m(pda.queued(sanctum, seq), false, true), m(payer, false, true)],
    data("cancel_queued").done());
}
export function approveQueued({ cold, sanctum, seq }) {
  return ix([m(cold, true, false), m(sanctum, false, false), m(pda.queued(sanctum, seq), false, true)], data("approve_queued").done());
}
export function coldWithdrawSol({ cold, sanctum, to, amount }) {
  return ix([
    m(cold, true, true), m(sanctum, false, false), m(pda.vault(sanctum), false, true), m(pda.cap(sanctum), false, true),
    m(to, false, true), m(SystemProgram.programId, false, false),
  ], data("cold_withdraw_sol").u64(amount).done());
}
export function coldWithdrawToken({ cold, sanctum, mint, to, amount, tokenProgram = TOKEN_2022_PROGRAM_ID }) {
  const vault = pda.vault(sanctum);
  return ix([
    m(cold, true, true), m(sanctum, false, false), m(vault, false, false), m(mint, false, false), m(ata(vault, mint, tokenProgram), false, true),
    m(pda.cap(sanctum, mint), false, true), m(to, false, true), m(tokenProgram, false, false), m(SystemProgram.programId, false, false),
  ], data("cold_withdraw_token").u64(amount).done());
}
export function panic({ signer, sanctum }) {
  return ix([m(signer, true, false), m(sanctum, false, true)], data("panic").done());
}
const coldOnly = (name, w) => ({ cold, sanctum, ...a }) => ix([m(cold, true, false), m(sanctum, false, true)], w(data(name), a).done());
export const unfreeze = coldOnly("unfreeze", (d) => d);
export const unfreezeAndRotate = coldOnly("unfreeze_and_rotate", (d, a) => d.pk(a.newHot));
export const setGuardians = coldOnly("set_guardians", (d, a) => { d.u32(a.guardians.length); for (const g of a.guardians) d.pk(g); return d; });
export const setCold = coldOnly("set_cold", (d, a) => d.pk(a.newCold));
export const setHot = coldOnly("set_hot", (d, a) => d.pk(a.newHot));
export const coldSetRules = coldOnly("cold_set_rules", (d, a) => d.rules(a.rules));
export const setModes = coldOnly("set_modes", (d, a) => d.bool(a.watchersOn).bool(a.approvalMode));
export function proposeRules({ hot, sanctum, rules }) {
  return ix([m(hot, true, false), m(sanctum, false, true)], data("propose_rules").rules(rules).done());
}
export function applyRules({ hot, sanctum }) {
  return ix([m(hot, true, false), m(sanctum, false, true)], data("apply_rules").done());
}

// ---------------------------------------------------------------- instructions (watcher nodes)
export function initStaking({ admin, mint, minStake, cooldownSecs, tokenProgram = TOKEN_2022_PROGRAM_ID }) {
  return ix([
    m(admin, true, true), m(pda.config(), false, true), m(mint, false, false), m(pda.stakeVault(), false, true),
    m(pda.programData(), false, false), m(PROGRAM_ID, false, false), m(tokenProgram, false, false), m(SystemProgram.programId, false, false),
  ], data("init_staking").u64(minStake).i64(cooldownSecs).done());
}
export function registerNode({ operator, mint, from, amount, tokenProgram = TOKEN_2022_PROGRAM_ID }) {
  from = from || ata(operator, mint, tokenProgram);
  return ix([
    m(operator, true, true), m(pda.config(), false, true), m(pda.node(operator), false, true), m(mint, false, false), m(from, false, true),
    m(pda.stakeVault(), false, true), m(tokenProgram, false, false), m(SystemProgram.programId, false, false),
  ], data("register_node").u64(amount).done());
}
export function addStake({ operator, mint, from, amount, tokenProgram = TOKEN_2022_PROGRAM_ID }) {
  from = from || ata(operator, mint, tokenProgram);
  return ix([
    m(operator, true, false), m(pda.config(), false, true), m(pda.node(operator), false, true), m(mint, false, false), m(from, false, true),
    m(pda.stakeVault(), false, true), m(tokenProgram, false, false),
  ], data("add_stake").u64(amount).done());
}
export function requestUnstake({ operator }) {
  return ix([m(operator, true, false), m(pda.config(), false, false), m(pda.node(operator), false, true)], data("request_unstake").done());
}
export function withdrawStake({ operator, mint, to, tokenProgram = TOKEN_2022_PROGRAM_ID }) {
  to = to || ata(operator, mint, tokenProgram);
  return ix([
    m(operator, true, true), m(pda.config(), false, true), m(pda.node(operator), false, true), m(mint, false, false), m(to, false, true),
    m(pda.stakeVault(), false, true), m(tokenProgram, false, false),
  ], data("withdraw_stake").done());
}
export function slash({ admin, operator, mint, amount, reasonCode = 0, tokenProgram = TOKEN_2022_PROGRAM_ID }) {
  return ix([
    m(admin, true, false), m(pda.config(), false, true), m(pda.node(operator), false, true), m(mint, false, true),
    m(pda.stakeVault(), false, true), m(tokenProgram, false, false),
  ], data("slash").u64(amount).u16(reasonCode).done());
}
export function watcherPanic({ operator, sanctum, seq }) {
  return ix([
    m(operator, true, false), m(pda.config(), false, false), m(pda.node(operator), false, true), m(sanctum, false, true),
    m(pda.queued(sanctum, seq), false, false),
  ], data("watcher_panic").done());
}

// ---------------------------------------------------------------- RPC helpers (web3.js Connection)
export async function fetchSanctum(conn, sanctum) {
  await ready();
  const a = await conn.getAccountInfo(new PublicKey(sanctum));
  return a ? decodeSanctum(a.data) : null;
}
/** Usable SOL in the vault (lamports minus the 0-byte rent-exempt minimum). */
export async function vaultSolBalance(conn, sanctum) {
  const v = pda.vault(sanctum);
  const [lamports, rentMin] = await Promise.all([conn.getBalance(v), conn.getMinimumBalanceForRentExemption(0)]);
  return BigInt(Math.max(0, lamports - rentMin));
}
export const SIZES = { Sanctum: 289, CapState: 8 + 32 + 32 + 8 + 16 + 16 + 25 * 24 + 1, Queued: 178, Node: 8 + 32 + 8 * 5 + 1 };
/** Live (not executed/cancelled) queue items of a Sanctum. */
export async function fetchQueue(conn, sanctum) {
  await ready();
  const list = await conn.getProgramAccounts(PROGRAM_ID, {
    filters: [{ dataSize: SIZES.Queued }, { memcmp: { offset: 8, bytes: new PublicKey(sanctum).toBase58() } }],
  });
  return list.map((x) => ({ address: x.pubkey, ...decodeQueued(x.account.data) })).sort((a, b) => (a.seq < b.seq ? -1 : 1));
}
