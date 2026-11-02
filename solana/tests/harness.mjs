// LiteSVM harness: loads target/deploy/sanctum.so as an UPGRADEABLE program (so init_staking's upgrade-authority
// check is real), sends web3.js v1 transactions built by client/sanctum.js, warps the clock.
import { LiteSVM, FailedTransactionMetadata } from "litesvm";
import { getTransactionDecoder, address } from "@solana/kit";
import { Keypair, Transaction, PublicKey, SystemProgram, LAMPORTS_PER_SOL } from "@solana/web3.js";
import {
  TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID, createInitializeMint2Instruction, createMintToInstruction,
  createAssociatedTokenAccountIdempotentInstruction, getAssociatedTokenAddressSync,
} from "@solana/spl-token";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import * as S from "../client/sanctum.js";

export { S, Keypair, PublicKey, LAMPORTS_PER_SOL, TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID };
const SO = fileURLToPath(new URL("../target/deploy/sanctum.so", import.meta.url));
const LOADER = new PublicKey("BPFLoaderUpgradeab1e11111111111111111111111");
const dec = getTransactionDecoder();
export const T0 = 1_800_000_000n - (1_800_000_000n % 3600n); // hour-aligned start time

export async function setup({ upgradeAuthority } = {}) {
  await S.ready();
  const svm = new LiteSVM().withDefaultPrograms();
  const elf = readFileSync(SO);
  const admin = upgradeAuthority || Keypair.generate();
  // upgradeable layout: Program { programdata }, ProgramData { slot, Some(authority), elf }
  const pdAddr = S.pda.programData();
  const progData = new Uint8Array(36); progData.set([2, 0, 0, 0]); progData.set(pdAddr.toBytes(), 4);
  const pd = new Uint8Array(45 + elf.length);
  pd.set([3, 0, 0, 0]); pd[12] = 1; pd.set(admin.publicKey.toBytes(), 13); pd.set(elf, 45);
  svm.setAccount({ address: address(pdAddr.toBase58()), data: pd, executable: false, lamports: 10n ** 10n, programAddress: address(LOADER.toBase58()), space: BigInt(pd.length) });
  svm.setAccount({ address: address(S.PROGRAM_ID.toBase58()), data: progData, executable: true, lamports: 10n ** 9n, programAddress: address(LOADER.toBase58()), space: 36n });
  const h = new Harness(svm, admin);
  h.setTime(T0);
  h.airdrop(admin.publicKey, 100);
  return h;
}

export class Harness {
  constructor(svm, admin) { this.svm = svm; this.admin = admin; }
  setTime(t) { const c = this.svm.getClock(); c.unixTimestamp = BigInt(t); c.slot = c.slot + 1n; this.svm.setClock(c); this.now = BigInt(t); }
  warp(secs) { this.setTime(this.now + BigInt(secs)); }
  airdrop(pk, sol) { this.svm.airdrop(address(pk.toBase58()), BigInt(Math.round(sol * LAMPORTS_PER_SOL))); }
  kp(sol = 10) { const k = Keypair.generate(); this.airdrop(k.publicKey, sol); return k; }
  lamports(pk) { const a = this.svm.getAccount(address(new PublicKey(pk).toBase58())); return a.exists ? BigInt(a.lamports) : 0n; }
  data(pk) { const a = this.svm.getAccount(address(new PublicKey(pk).toBase58())); return a.exists ? a.data : null; }
  exists(pk) { return this.data(pk) !== null; }
  send(ixs, signers) {
    const tx = new Transaction();
    tx.recentBlockhash = this.svm.latestBlockhash();
    tx.feePayer = signers[0].publicKey;
    tx.add(...(Array.isArray(ixs) ? ixs : [ixs]));
    tx.sign(...signers);
    const res = this.svm.sendTransaction(dec.decode(tx.serialize()));
    this.svm.expireBlockhash();
    if (res instanceof FailedTransactionMetadata) {
      const logs = res.meta().logs().join("\n");
      const e = new Error("tx failed: " + res.err().toString() + "\n" + logs);
      e.logs = logs;
      throw e;
    }
    return res;
  }
  /** expect a failure whose logs mention `code` (Anchor error name) */
  fails(ixs, signers, code) {
    try { this.send(ixs, signers); } catch (e) {
      if (code && !e.message.includes(code)) throw new Error(`expected ${code}, got:\n${e.message}`);
      return e;
    }
    throw new Error(`expected failure ${code || ""} but tx succeeded`);
  }

  // ---- sanctum helpers
  rentMin() { return this.svm.minimumBalanceForRentExemption(0n); }
  sanctum(pk) { return S.decodeSanctum(this.data(pk)); }
  cap(sanctum, mint) { const d = this.data(S.pda.cap(sanctum, mint)); return d ? S.decodeCapState(d) : null; }
  queued(sanctum, seq) { const d = this.data(S.pda.queued(sanctum, seq)); return d ? S.decodeQueued(d) : null; }
  vaultSol(sanctum) { return this.lamports(S.pda.vault(sanctum)) - this.rentMin(); }
  createSanctum({ guardians = [], rules = null, fund = 0n } = {}) {
    const hot = this.kp(1000), cold = this.kp(10);
    const g = guardians.length ? guardians : [];
    this.send(S.create({ hot: hot.publicKey, cold: cold.publicKey, guardians: g.map((k) => k.publicKey), rules }), [hot]);
    const sanctum = S.pda.sanctum(hot.publicKey, 0n);
    if (fund > 0n) this.send(S.depositSol({ depositor: hot.publicKey, sanctum, amount: fund }), [hot]);
    return { hot, cold, sanctum, guardians: g };
  }
  withdrawSol(ctx, amount, to, signer) {
    const s = this.sanctum(ctx.sanctum);
    return this.send(S.withdrawSol({ hot: (signer || ctx.hot).publicKey, sanctum: ctx.sanctum, to: to || ctx.hot.publicKey, amount, queueSeq: s.queueSeq }), [signer || ctx.hot]);
  }

  // ---- tokens
  createMint({ program = TOKEN_2022_PROGRAM_ID, decimals = 6, authority } = {}) {
    const mint = Keypair.generate();
    authority = authority || this.admin;
    const space = 82;
    const lamports = this.svm.minimumBalanceForRentExemption(82n);
    this.send([
      SystemProgram.createAccount({ fromPubkey: authority.publicKey, newAccountPubkey: mint.publicKey, lamports: Number(lamports), space, programId: program }),
      createInitializeMint2Instruction(mint.publicKey, decimals, authority.publicKey, null, program),
    ], [authority, mint]);
    return { mint: mint.publicKey, program, authority, decimals };
  }
  ata(owner, m) { return getAssociatedTokenAddressSync(m.mint, owner, true, m.program); }
  mintTo(owner, m, amount) {
    const a = this.ata(owner, m);
    this.send([
      createAssociatedTokenAccountIdempotentInstruction(m.authority.publicKey, a, owner, m.mint, m.program),
      createMintToInstruction(m.mint, a, m.authority.publicKey, BigInt(amount), [], m.program),
    ], [m.authority]);
    return a;
  }
  ensureAta(owner, m) {
    const a = this.ata(owner, m);
    this.send(createAssociatedTokenAccountIdempotentInstruction(this.admin.publicKey, a, owner, m.mint, m.program), [this.admin]);
    return a;
  }
  tokenBal(acct) {
    const d = this.data(acct); if (!d) return 0n;
    let x = 0n; for (let i = 7; i >= 0; i--) x = (x << 8n) | BigInt(d[64 + i]); return x;
  }
  supply(m) { const d = this.data(m.mint); let x = 0n; for (let i = 7; i >= 0; i--) x = (x << 8n) | BigInt(d[36 + i]); return x; }
}
