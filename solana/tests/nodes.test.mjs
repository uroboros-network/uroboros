import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, S, Keypair, TOKEN_2022_PROGRAM_ID } from "./harness.mjs";

const SOL = 1_000_000_000n;
const MIN = 1_000_000_000_000n; // 1M tokens at 6 decimals

async function world() {
  const h = await setup();
  const m = h.createMint({ program: TOKEN_2022_PROGRAM_ID, decimals: 6 });
  const op = h.kp(10);
  h.mintTo(op.publicKey, m, 5n * MIN);
  return { h, m, op };
}
const init = (h, m, signer = h.admin, min = MIN, cd = 3n * 86400n) =>
  h.send(S.initStaking({ admin: signer.publicKey, mint: m.mint, minStake: min, cooldownSecs: cd }), [signer]);

test("init_staking: only the upgrade authority, once", async () => {
  const { h, m } = await world();
  const imp = h.kp();
  h.fails(S.initStaking({ admin: imp.publicKey, mint: m.mint, minStake: MIN, cooldownSecs: 0n }), [imp], "Unauthorized");
  init(h, m);
  const c = S.decodeConfig(h.data(S.pda.config()));
  assert.ok(c.admin.equals(h.admin.publicKey) && c.mint.equals(m.mint));
  assert.equal(c.minStake, MIN);
  assert.throws(() => init(h, m));
});

test("register / add / unstake cooldown / withdraw; min stake enforced", async () => {
  const { h, m, op } = await world();
  init(h, m);
  h.fails(S.registerNode({ operator: op.publicKey, mint: m.mint, amount: MIN - 1n }), [op], "BelowMinStake");
  h.send(S.registerNode({ operator: op.publicKey, mint: m.mint, amount: MIN }), [op]);
  h.send(S.addStake({ operator: op.publicKey, mint: m.mint, amount: MIN }), [op]);
  let n = S.decodeNode(h.data(S.pda.node(op.publicKey)));
  assert.equal(n.stake, 2n * MIN);
  assert.equal(h.tokenBal(S.pda.stakeVault()), 2n * MIN);
  h.fails(S.withdrawStake({ operator: op.publicKey, mint: m.mint }), [op], "NotReady");
  h.send(S.requestUnstake({ operator: op.publicKey }), [op]);
  h.fails(S.addStake({ operator: op.publicKey, mint: m.mint, amount: MIN }), [op], "Unstaking");
  h.warp(3 * 86400 - 1);
  h.fails(S.withdrawStake({ operator: op.publicKey, mint: m.mint }), [op], "NotReady");
  h.warp(1);
  const opAta = h.ata(op.publicKey, m);
  h.send(S.withdrawStake({ operator: op.publicKey, mint: m.mint }), [op]);
  assert.equal(h.tokenBal(opAta), 5n * MIN);
  assert.ok(!h.exists(S.pda.node(op.publicKey)));
  assert.equal(S.decodeConfig(h.data(S.pda.config())).totalStaked, 0n);
  // wrong mint rejected
  const other = h.createMint({ program: TOKEN_2022_PROGRAM_ID });
  h.mintTo(op.publicKey, other, MIN);
  h.fails(S.registerNode({ operator: op.publicKey, mint: other.mint, amount: MIN }), [op]);
});

test("slash: admin only, burns supply, works while unstaking", async () => {
  const { h, m, op } = await world();
  init(h, m);
  h.send(S.registerNode({ operator: op.publicKey, mint: m.mint, amount: 2n * MIN }), [op]);
  h.send(S.requestUnstake({ operator: op.publicKey }), [op]);
  const supply0 = h.supply(m);
  h.fails(S.slash({ admin: op.publicKey, operator: op.publicKey, mint: m.mint, amount: MIN }), [op], "Unauthorized");
  h.fails(S.slash({ admin: h.admin.publicKey, operator: op.publicKey, mint: m.mint, amount: 3n * MIN }), [h.admin], "Balance");
  h.send(S.slash({ admin: h.admin.publicKey, operator: op.publicKey, mint: m.mint, amount: MIN, reasonCode: 7 }), [h.admin]);
  assert.equal(h.supply(m), supply0 - MIN);
  assert.equal(S.decodeNode(h.data(S.pda.node(op.publicKey))).stake, MIN);
  h.warp(3 * 86400);
  h.send(S.withdrawStake({ operator: op.publicKey, mint: m.mint }), [op]);
  assert.equal(h.tokenBal(h.ata(op.publicKey, m)), 4n * MIN);
});

test("watcher_panic: only staked active nodes, only opted-in sanctums, only live unapproved final-hour items", async () => {
  const { h, m, op } = await world();
  init(h, m);
  const c = h.createSanctum({ fund: 100n * SOL });
  const dest = Keypair.generate().publicKey;
  const wp = (o = op, seq = 0n) => S.watcherPanic({ operator: o.publicKey, sanctum: c.sanctum, seq });
  h.withdrawSol(c, 20n * SOL, dest); // seq 0, ready T+6h
  const q0 = h.queued(c.sanctum, 0n);
  h.setTime(q0.readyAt - 3600n);
  h.fails(wp(), [op], "AccountNotInitialized"); // not registered
  h.send(S.registerNode({ operator: op.publicKey, mint: m.mint, amount: MIN }), [op]);
  h.fails(wp(), [op], "WatchersOff");
  h.fails(S.setModes({ cold: c.cold.publicKey, sanctum: c.sanctum, watchersOn: true, approvalMode: false }), [c.cold], "WatchersNeedApproval");
  h.fails(S.setModes({ cold: c.hot.publicKey, sanctum: c.sanctum, watchersOn: true, approvalMode: true }), [c.hot], "Unauthorized");
  h.send(S.setModes({ cold: c.cold.publicKey, sanctum: c.sanctum, watchersOn: true, approvalMode: true }), [c.cold]);
  // approval mode: the unapproved item cannot execute even after the delay
  // final-hour boundary
  h.setTime(q0.readyAt - 3601n);
  h.fails(wp(), [op], "NotFinalHour");
  // approved item is untouchable
  h.send(S.approveQueued({ cold: c.cold.publicKey, sanctum: c.sanctum, seq: 0n }), [c.cold]);
  h.setTime(q0.readyAt - 3600n);
  h.fails(wp(), [op], "QueueApproved");
  // a second, unapproved item
  h.withdrawSol(c, 20n * SOL, dest); // seq 1
  const q1 = h.queued(c.sanctum, 1n);
  h.setTime(q1.readyAt - 3600n);
  // unstaking node cannot panic
  const op2 = h.kp(10); h.mintTo(op2.publicKey, m, MIN);
  h.send(S.registerNode({ operator: op2.publicKey, mint: m.mint, amount: MIN }), [op2]);
  h.send(S.requestUnstake({ operator: op2.publicKey }), [op2]);
  h.fails(wp(op2, 1n), [op2], "NodeNotActive");
  // the real one
  h.send(wp(op, 1n), [op]);
  const s = h.sanctum(c.sanctum);
  assert.equal(s.frozenUntil, h.now + 86400n);
  assert.equal(S.decodeNode(h.data(S.pda.node(op.publicKey))).panics, 1n);
  // the item is now void: no re-panic citing it, even in the last hour of the freeze
  h.setTime(s.frozenUntil - 3600n);
  h.fails(wp(op, 1n), [op], "VoidedByPanic");
  // approved seq 0 was voided too
  h.setTime(s.frozenUntil);
  h.fails(S.executeQueuedSol({ signer: c.hot.publicKey, sanctum: c.sanctum, seq: 0n, payer: c.hot.publicKey, to: dest }), [c.hot], "VoidedByPanic");
  // mute after cold unfreeze
  h.withdrawSol(c, 20n * SOL, dest); // seq 2
  h.send(S.panic({ signer: c.cold.publicKey, sanctum: c.sanctum }), [c.cold]);
  h.send(S.unfreeze({ cold: c.cold.publicKey, sanctum: c.sanctum }), [c.cold]);
  h.withdrawSol(c, 20n * SOL, dest); // seq 3, queued during mute
  const q3 = h.queued(c.sanctum, 3n);
  h.setTime(q3.readyAt - 3600n);
  h.fails(wp(op, 3n), [op], "GuardianMuted");
  // after the mute, a fresh item in its final hour can be panicked; a running freeze only in its last hour
  h.setTime(h.sanctum(c.sanctum).guardianMutedUntil);
  h.withdrawSol(c, 20n * SOL, dest); // seq 4
  const q4 = h.queued(c.sanctum, 4n);
  h.setTime(q4.readyAt - 10n);
  h.send(wp(op, 4n), [op]);
  // approval mode: an approved item executes, an unapproved one does not
  h.setTime(h.sanctum(c.sanctum).frozenUntil);
  h.withdrawSol(c, 20n * SOL, dest); // seq 5
  h.withdrawSol(c, 16n * SOL, dest); // seq 6
  h.warp(21601);
  h.fails(S.executeQueuedSol({ signer: c.hot.publicKey, sanctum: c.sanctum, seq: 5n, payer: c.hot.publicKey, to: dest }), [c.hot], "NeedsColdApproval");
  h.send(S.approveQueued({ cold: c.cold.publicKey, sanctum: c.sanctum, seq: 6n }), [c.cold]);
  h.send(S.executeQueuedSol({ signer: c.hot.publicKey, sanctum: c.sanctum, seq: 6n, payer: c.hot.publicKey, to: dest }), [c.hot]);
  assert.equal(h.lamports(dest), 16n * SOL);
  // stranger without a node account, and a node citing another sanctum's item
  const c2 = h.createSanctum({ fund: 10n * SOL });
  h.fails(S.watcherPanic({ operator: op.publicKey, sanctum: c2.sanctum, seq: 5n }), [op]);
});
