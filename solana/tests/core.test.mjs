import { test } from "node:test";
import assert from "node:assert/strict";
import { setup, S, Keypair, PublicKey, T0, TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID } from "./harness.mjs";

const SOL = 1_000_000_000n;

test("create: defaults, key checks, guardian limits", async () => {
  const h = await setup();
  const g = [h.kp(), h.kp(), h.kp()];
  const c = h.createSanctum({ guardians: g });
  const s = h.sanctum(c.sanctum);
  assert.deepEqual(s.rules, { capBps: 500, dayCapBps: 1000, delayBps: 1000, delaySecs: 21600n });
  assert.equal(s.guardians.length, 3);
  assert.ok(s.hot.equals(c.hot.publicKey) && s.cold.equals(c.cold.publicKey));
  assert.equal(h.vaultSol(c.sanctum), 0n); // vault funded with exactly the rent minimum
  const hot = h.kp();
  h.fails(S.create({ hot: hot.publicKey, cold: hot.publicKey }), [hot], "BadKey");
  h.fails(S.create({ hot: hot.publicKey, cold: Keypair.generate().publicKey, guardians: [1, 2, 3, 4].map(() => Keypair.generate().publicKey) }), [hot], "TooManyGuardians");
  const d = Keypair.generate().publicKey;
  h.fails(S.create({ hot: hot.publicKey, cold: Keypair.generate().publicKey, guardians: [d, d] }), [hot], "DuplicateGuardian");
  h.fails(S.create({ hot: hot.publicKey, cold: Keypair.generate().publicKey, rules: { capBps: 10001, dayCapBps: 1, delayBps: 1, delaySecs: 0n } }), [hot], "BadRules");
  // second sanctum, same hot key, nonce 1
  h.send(S.create({ hot: hot.publicKey, cold: Keypair.generate().publicKey, nonce: 1n }), [hot]);
  assert.ok(h.exists(S.pda.sanctum(hot.publicKey, 1n)));
});

test("hourly cap boundary: exactly 5% pays, 1 lamport more queues; window resets at +3600s", async () => {
  const h = await setup();
  const c = h.createSanctum({ fund: 100n * SOL });
  const dest = Keypair.generate().publicKey;
  h.withdrawSol(c, 5n * SOL, dest);
  assert.equal(h.lamports(dest), 5n * SOL);
  assert.equal(h.sanctum(c.sanctum).queueSeq, 0n);
  h.withdrawSol(c, 1n, dest); // no hourly room left -> queued, not paid
  assert.equal(h.lamports(dest), 5n * SOL);
  assert.equal(h.sanctum(c.sanctum).queueSeq, 1n);
  h.warp(3599);
  h.withdrawSol(c, 1n, dest);
  assert.equal(h.sanctum(c.sanctum).queueSeq, 2n);
  h.warp(1); // window started at T0, now T0+3600 -> fresh window on 95 SOL: room 4.75, daily room 10%*(95+5)-5 = 5
  const room = S.capRoom(h.cap(c.sanctum), h.sanctum(c.sanctum).rules, h.vaultSol(c.sanctum), h.now);
  assert.equal(room, 4_750_000_000n);
  h.withdrawSol(c, room, dest);
  assert.equal(h.lamports(dest), 5n * SOL + room);
});

test("delay_bps boundary: exactly 10% pays (caps opened by cold), 10%+1 queues", async () => {
  const h = await setup();
  const c = h.createSanctum({ fund: 100n * SOL });
  h.send(S.coldSetRules({ cold: c.cold.publicKey, sanctum: c.sanctum, rules: { capBps: 10000, dayCapBps: 10000, delayBps: 1000, delaySecs: 21600n } }), [c.cold]);
  const dest = Keypair.generate().publicKey;
  h.withdrawSol(c, 10n * SOL, dest);
  assert.equal(h.lamports(dest), 10n * SOL);
  h.withdrawSol(c, 9n * SOL + 1n, dest); // 10% of 90 = 9 SOL; +1 lamport queues
  assert.equal(h.lamports(dest), 10n * SOL);
  assert.equal(h.queued(c.sanctum, 0n).amount, 9n * SOL + 1n);
});

test("rolling 24h: an outflow counts for >= 24h (25 hourly buckets); no back-to-back days", async () => {
  const h = await setup();
  const c = h.createSanctum({ fund: 100n * SOL });
  const dest = Keypair.generate().publicKey;
  h.withdrawSol(c, 5n * SOL, dest);          // hour 0
  h.warp(3600); h.withdrawSol(c, 4_750_000_000n, dest); // hour 1: 5% of 95
  const st = () => S.capRoom(h.cap(c.sanctum), h.sanctum(c.sanctum).rules, h.vaultSol(c.sanctum), h.now);
  h.warp(3600); assert.equal(st(), 250_000_000n); // daily: 10% of (90.25 + 9.75) - 9.75
  h.withdrawSol(c, 250_000_000n, dest); assert.equal(h.lamports(dest), 10n * SOL);
  assert.equal(st(), 0n);
  h.setTime(T0 + 24n * 3600n + 3599n); assert.equal(st(), 0n, "hour-0 outflow still counted 24h59m later");
  h.withdrawSol(c, 1n, dest); assert.equal(h.lamports(dest), 10n * SOL); // queued
  h.setTime(T0 + 25n * 3600n); // hour 0 bucket expires, hours 1-2 (5 SOL) still counted
  // day cap = 10% of (90 + 5) = 9.5 - 5 spent = 4.5 ; hourly 5% of 90 = 4.5
  assert.equal(st(), 4_500_000_000n);
  h.withdrawSol(c, 4_500_000_000n, dest);
  assert.equal(h.lamports(dest), 14_500_000_000n);
  assert.throws(() => h.send(S.coldWithdrawSol({ cold: c.cold.publicKey, sanctum: c.sanctum, to: dest, amount: 1n }), [c.cold]), /HourlyCap|DailyCap/);
});

test("queue: strict ready_at, pays in full past caps, rent back to payer, cancel by hot/cold only", async () => {
  const h = await setup();
  const c = h.createSanctum({ fund: 100n * SOL });
  const dest = Keypair.generate().publicKey;
  h.withdrawSol(c, 20n * SOL, dest); // 20% -> queued
  const q = h.queued(c.sanctum, 0n);
  assert.equal(q.readyAt, T0 + 21600n);
  const exec = (signer) => S.executeQueuedSol({ signer: signer.publicKey, sanctum: c.sanctum, seq: 0n, payer: c.hot.publicKey, to: dest });
  h.fails(exec(c.hot), [c.hot], "NotReady");
  h.setTime(q.readyAt);
  h.fails(exec(c.hot), [c.hot], "NotReady"); // strict: a cancel/panic landing AT ready_at always wins
  const stranger = h.kp();
  h.setTime(q.readyAt + 1n);
  h.fails(exec(stranger), [stranger], "Unauthorized");
  const hotBefore = h.lamports(c.hot.publicKey);
  h.send(exec(c.cold), [c.cold]); // cold can execute too
  assert.equal(h.lamports(dest), 20n * SOL);
  assert.ok(!h.exists(S.pda.queued(c.sanctum, 0n)));
  assert.ok(h.lamports(c.hot.publicKey) > hotBefore, "queue rent refunded to payer");
  // to == payer (hot sends to itself) works
  h.withdrawSol(c, 30n * SOL, c.hot.publicKey);
  h.warp(21601);
  h.send(S.executeQueuedSol({ signer: c.hot.publicKey, sanctum: c.sanctum, seq: 1n, payer: c.hot.publicKey, to: c.hot.publicKey }), [c.hot]);
  // wrong destination rejected
  h.withdrawSol(c, 20n * SOL, dest);
  h.warp(21601);
  h.fails(S.executeQueuedSol({ signer: c.hot.publicKey, sanctum: c.sanctum, seq: 2n, payer: c.hot.publicKey, to: stranger.publicKey }), [c.hot], "BadDestination");
  // cancel
  h.fails(S.cancelQueued({ signer: stranger.publicKey, sanctum: c.sanctum, seq: 2n, payer: c.hot.publicKey }), [stranger], "Unauthorized");
  h.send(S.cancelQueued({ signer: c.cold.publicKey, sanctum: c.sanctum, seq: 2n, payer: c.hot.publicKey }), [c.cold]);
  assert.ok(!h.exists(S.pda.queued(c.sanctum, 2n)));
  h.withdrawSol(c, 20n * SOL, dest);
  h.send(S.cancelQueued({ signer: c.hot.publicKey, sanctum: c.sanctum, seq: 3n, payer: c.hot.publicKey }), [c.hot]);
  // queue PDA pre-funded by a griefer does not block queueing
  const next = S.pda.queued(c.sanctum, 4n);
  h.airdrop(next, 0.001);
  h.withdrawSol(c, 20n * SOL, dest);
  assert.equal(h.queued(c.sanctum, 4n).amount, 20n * SOL);
  // only hot can withdraw
  h.fails(S.withdrawSol({ hot: stranger.publicKey, sanctum: c.sanctum, to: dest, amount: 1n, queueSeq: 5n }), [stranger], "Unauthorized");
  h.fails(S.withdrawSol({ hot: c.hot.publicKey, sanctum: c.sanctum, to: S.pda.vault(c.sanctum), amount: 1n, queueSeq: 5n }), [c.hot], "BadDestination");
  h.fails(S.withdrawSol({ hot: c.hot.publicKey, sanctum: c.sanctum, to: dest, amount: 1000n * SOL, queueSeq: 5n }), [c.hot], "Balance");
  h.fails(S.withdrawSol({ hot: c.hot.publicKey, sanctum: c.sanctum, to: dest, amount: 20n * SOL, queueSeq: 9n }), [c.hot], "BadQueueAccount");
});

test("panic: frozen => zero outflow on every path; queue voided; only cold unfreezes", async () => {
  const h = await setup();
  const g = h.kp();
  const c = h.createSanctum({ fund: 100n * SOL, guardians: [g] });
  const dest = Keypair.generate().publicKey;
  h.withdrawSol(c, 20n * SOL, dest); // queued seq 0
  h.warp(60);
  h.send(S.panic({ signer: g.publicKey, sanctum: c.sanctum }), [g]);
  const s = h.sanctum(c.sanctum);
  assert.equal(s.frozenUntil, h.now + 86400n);
  h.fails(S.withdrawSol({ hot: c.hot.publicKey, sanctum: c.sanctum, to: dest, amount: 1n, queueSeq: 1n }), [c.hot], "Frozen");
  h.fails(S.coldWithdrawSol({ cold: c.cold.publicKey, sanctum: c.sanctum, to: dest, amount: 1n }), [c.cold], "Frozen");
  h.warp(21601);
  h.fails(S.executeQueuedSol({ signer: c.cold.publicKey, sanctum: c.sanctum, seq: 0n, payer: c.hot.publicKey, to: dest }), [c.cold], "Frozen");
  h.fails(S.proposeRules({ hot: c.hot.publicKey, sanctum: c.sanctum, rules: { capBps: 100, dayCapBps: 100, delayBps: 100, delaySecs: 21600n } }), [c.hot], "Frozen");
  assert.equal(h.lamports(dest), 0n);
  h.fails(S.unfreeze({ cold: c.hot.publicKey, sanctum: c.sanctum }), [c.hot], "Unauthorized");
  h.fails(S.unfreeze({ cold: g.publicKey, sanctum: c.sanctum }), [g], "Unauthorized");
  const stranger = h.kp();
  h.fails(S.panic({ signer: stranger.publicKey, sanctum: c.sanctum }), [stranger], "Unauthorized");
  h.send(S.unfreeze({ cold: c.cold.publicKey, sanctum: c.sanctum }), [c.cold]);
  // queued before the panic stays void forever
  h.fails(S.executeQueuedSol({ signer: c.hot.publicKey, sanctum: c.sanctum, seq: 0n, payer: c.hot.publicKey, to: dest }), [c.hot], "VoidedByPanic");
  h.send(S.cancelQueued({ signer: c.hot.publicKey, sanctum: c.sanctum, seq: 0n, payer: c.hot.publicKey }), [c.hot]); // rent back
  // freeze expires on its own after 24h
  h.send(S.panic({ signer: c.cold.publicKey, sanctum: c.sanctum }), [c.cold]);
  h.warp(86399);
  h.fails(S.withdrawSol({ hot: c.hot.publicKey, sanctum: c.sanctum, to: dest, amount: 1n, queueSeq: 1n }), [c.hot], "Frozen");
  h.warp(1);
  h.withdrawSol(c, 1n * SOL, dest);
  assert.equal(h.lamports(dest), 1n * SOL);
});

test("guardians: re-panic only in last hour; muted 24h after unfreeze; hot muted too; cold never", async () => {
  const h = await setup();
  const g1 = h.kp(), g2 = h.kp();
  const c = h.createSanctum({ fund: 100n * SOL, guardians: [g1, g2] });
  h.send(S.panic({ signer: g1.publicKey, sanctum: c.sanctum }), [g1]);
  const until = h.sanctum(c.sanctum).frozenUntil;
  h.setTime(until - 3601n);
  h.fails(S.panic({ signer: g2.publicKey, sanctum: c.sanctum }), [g2], "FrozenLastHourOnly");
  h.setTime(until - 3600n);
  h.send(S.panic({ signer: g2.publicKey, sanctum: c.sanctum }), [g2]); // extends by 24h from now
  assert.equal(h.sanctum(c.sanctum).frozenUntil, h.now + 86400n);
  h.send(S.panic({ signer: c.hot.publicKey, sanctum: c.sanctum }), [c.hot]); // hot may stack any time (before a cold unfreeze)
  h.send(S.unfreeze({ cold: c.cold.publicKey, sanctum: c.sanctum }), [c.cold]);
  const muted = h.sanctum(c.sanctum).guardianMutedUntil;
  assert.equal(muted, h.now + 86400n);
  h.fails(S.panic({ signer: g1.publicKey, sanctum: c.sanctum }), [g1], "GuardianMuted");
  h.fails(S.panic({ signer: c.hot.publicKey, sanctum: c.sanctum }), [c.hot], "GuardianMuted");
  // queued during mute: needs cold approval
  const dest = Keypair.generate().publicKey;
  h.withdrawSol(c, 20n * SOL, dest);
  const seq = h.sanctum(c.sanctum).queueSeq - 1n;
  h.warp(21601);
  const exec = S.executeQueuedSol({ signer: c.hot.publicKey, sanctum: c.sanctum, seq, payer: c.hot.publicKey, to: dest });
  h.fails(exec, [c.hot], "NeedsColdApproval");
  h.fails(S.approveQueued({ cold: c.hot.publicKey, sanctum: c.sanctum, seq }), [c.hot], "Unauthorized");
  h.send(S.approveQueued({ cold: c.cold.publicKey, sanctum: c.sanctum, seq }), [c.cold]);
  h.send(exec, [c.hot]);
  assert.equal(h.lamports(dest), 20n * SOL);
  h.send(S.panic({ signer: c.cold.publicKey, sanctum: c.sanctum }), [c.cold]); // cold is never muted
  h.send(S.unfreeze({ cold: c.cold.publicKey, sanctum: c.sanctum }), [c.cold]);
  h.setTime(h.sanctum(c.sanctum).guardianMutedUntil);
  h.send(S.panic({ signer: g1.publicKey, sanctum: c.sanctum }), [g1]); // mute over
  // set_guardians: removed guardian loses standing
  h.send(S.setGuardians({ cold: c.cold.publicKey, sanctum: c.sanctum, guardians: [g2.publicKey] }), [c.cold]);
  h.warp(86400);
  h.fails(S.panic({ signer: g1.publicKey, sanctum: c.sanctum }), [g1], "Unauthorized");
  h.send(S.panic({ signer: g2.publicKey, sanctum: c.sanctum }), [g2]);
});

test("unfreeze_and_rotate: thief's hot key is replaced in the same instruction", async () => {
  const h = await setup();
  const c = h.createSanctum({ fund: 100n * SOL });
  const dest = Keypair.generate().publicKey;
  h.send(S.panic({ signer: c.hot.publicKey, sanctum: c.sanctum }), [c.hot]);
  const fresh = h.kp();
  h.send(S.unfreezeAndRotate({ cold: c.cold.publicKey, sanctum: c.sanctum, newHot: fresh.publicKey }), [c.cold]);
  const s = h.sanctum(c.sanctum);
  assert.equal(s.frozenUntil, 0n);
  assert.ok(s.hot.equals(fresh.publicKey));
  h.fails(S.panic({ signer: c.hot.publicKey, sanctum: c.sanctum }), [c.hot], "Unauthorized");
  h.fails(S.withdrawSol({ hot: c.hot.publicKey, sanctum: c.sanctum, to: dest, amount: 1n, queueSeq: 0n }), [c.hot], "Unauthorized");
  h.send(S.withdrawSol({ hot: fresh.publicKey, sanctum: c.sanctum, to: dest, amount: 1n * SOL, queueSeq: 0n }), [fresh]);
  assert.equal(h.lamports(dest), 1n * SOL);
  h.fails(S.unfreezeAndRotate({ cold: c.cold.publicKey, sanctum: c.sanctum, newHot: c.cold.publicKey }), [c.cold], "BadKey");
  // set_cold / set_hot
  const newCold = h.kp();
  h.fails(S.setCold({ cold: fresh.publicKey, sanctum: c.sanctum, newCold: newCold.publicKey }), [fresh], "Unauthorized");
  h.send(S.setCold({ cold: c.cold.publicKey, sanctum: c.sanctum, newCold: newCold.publicKey }), [c.cold]);
  h.fails(S.setHot({ cold: c.cold.publicKey, sanctum: c.sanctum, newHot: c.hot.publicKey }), [c.cold], "Unauthorized");
  h.send(S.setHot({ cold: newCold.publicKey, sanctum: c.sanctum, newHot: c.hot.publicKey }), [newCold]);
});

test("rules: hot tighten-only after max(delay, 3 days); panic kills a pending change; cold sets any", async () => {
  const h = await setup();
  const c = h.createSanctum({ fund: 100n * SOL });
  const base = { capBps: 500, dayCapBps: 1000, delayBps: 1000, delaySecs: 21600n };
  const p = (r) => S.proposeRules({ hot: c.hot.publicKey, sanctum: c.sanctum, rules: r });
  for (const loosen of [{ capBps: 501 }, { dayCapBps: 1001 }, { delayBps: 1001 }, { delaySecs: 21599n }])
    h.fails(p({ ...base, ...loosen }), [c.hot], "TightenOnly");
  const tight = { capBps: 100, dayCapBps: 200, delayBps: 500, delaySecs: 43200n };
  h.send(p(tight), [c.hot]);
  const apply = S.applyRules({ hot: c.hot.publicKey, sanctum: c.sanctum });
  h.warp(3 * 86400 - 1);
  h.fails(apply, [c.hot], "NotReady");
  h.warp(1);
  h.send(apply, [c.hot]);
  assert.deepEqual(h.sanctum(c.sanctum).rules, tight);
  // panic kills a pending proposal
  h.send(p({ ...tight, capBps: 50 }), [c.hot]);
  h.send(S.panic({ signer: c.cold.publicKey, sanctum: c.sanctum }), [c.cold]);
  h.send(S.unfreeze({ cold: c.cold.publicKey, sanctum: c.sanctum }), [c.cold]);
  h.warp(4 * 86400);
  h.fails(apply, [c.hot], "NotReady");
  // a proposal made under a long delay waits that delay
  h.send(S.coldSetRules({ cold: c.cold.publicKey, sanctum: c.sanctum, rules: { ...tight, delaySecs: 5n * 86400n } }), [c.cold]);
  h.send(p({ ...tight, delaySecs: 5n * 86400n }), [c.hot]);
  h.warp(5 * 86400 - 1); h.fails(apply, [c.hot], "NotReady");
  h.warp(1); h.send(apply, [c.hot]);
  // cold loosens at once
  h.fails(S.coldSetRules({ cold: c.hot.publicKey, sanctum: c.sanctum, rules: base }), [c.hot], "Unauthorized");
  h.send(S.coldSetRules({ cold: c.cold.publicKey, sanctum: c.sanctum, rules: base }), [c.cold]);
  assert.deepEqual(h.sanctum(c.sanctum).rules, base);
});

for (const [name, program] of [["Token-2022", TOKEN_2022_PROGRAM_ID], ["SPL Token", TOKEN_PROGRAM_ID]]) {
  test(`${name}: deposit, capped withdraw, queue, execute, wrong-mint destination, cold withdraw, freeze`, async () => {
    const h = await setup();
    const c = h.createSanctum();
    const m = h.createMint({ program, decimals: 6 });
    const other = h.createMint({ program, decimals: 6 });
    const src = h.mintTo(c.hot.publicKey, m, 1_000_000_000_000n);
    h.send(S.depositToken({ depositor: c.hot.publicKey, sanctum: c.sanctum, mint: m.mint, amount: 1_000_000_000_000n, tokenProgram: program }), [c.hot]);
    const vault = S.pda.vault(c.sanctum);
    assert.equal(h.tokenBal(h.ata(vault, m)), 1_000_000_000_000n);
    assert.equal(h.tokenBal(src), 0n);
    const user = Keypair.generate().publicKey;
    const dst = h.ensureAta(user, m);
    const wrong = h.ensureAta(user, other);
    const wd = (amount, to = dst) => S.withdrawToken({ hot: c.hot.publicKey, sanctum: c.sanctum, mint: m.mint, to, amount, queueSeq: h.sanctum(c.sanctum).queueSeq, tokenProgram: program });
    h.fails(wd(1n, wrong), [c.hot]);
    h.send(wd(50_000_000_000n), [c.hot]); // 5%
    assert.equal(h.tokenBal(dst), 50_000_000_000n);
    h.send(wd(200_000_000_000n), [c.hot]); // queued
    assert.equal(h.tokenBal(dst), 50_000_000_000n);
    h.warp(21601);
    const ex = S.executeQueuedToken({ signer: c.hot.publicKey, sanctum: c.sanctum, seq: 0n, payer: c.hot.publicKey, mint: m.mint, to: dst, tokenProgram: program });
    h.send(ex, [c.hot]);
    assert.equal(h.tokenBal(dst), 250_000_000_000n);
    // SOL caps and token caps are independent
    assert.ok(h.cap(c.sanctum, m.mint).initialized);
    assert.equal(h.cap(c.sanctum), null);
    // cold withdraw: capped
    const cw = (amount) => S.coldWithdrawToken({ cold: c.cold.publicKey, sanctum: c.sanctum, mint: m.mint, to: dst, amount, tokenProgram: program });
    h.send(cw(30_000_000_000n), [c.cold]); // daily: 10% of (750 + 50 spent) - 50 = 30 (queued 200 does not count)
    h.fails(cw(1n), [c.cold], "DailyCap");
    h.send(S.panic({ signer: c.hot.publicKey, sanctum: c.sanctum }), [c.hot]);
    h.warp(3600);
    h.fails(cw(1n), [c.cold], "Frozen");
    h.fails(wd(1n), [c.hot], "Frozen");
  });
}

test("fuzz: capped outflow in ANY 24h window <= 10% of (balance at window start + deposits in window)", async () => {
  const h = await setup();
  const c = h.createSanctum({ fund: 50n * SOL });
  const g = h.kp();
  h.send(S.setGuardians({ cold: c.cold.publicKey, sanctum: c.sanctum, guardians: [g.publicKey] }), [c.cold]);
  const dest = Keypair.generate().publicKey;
  let seed = 0x5eed1234;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 2 ** 32);
  const log = []; // {t, kind: 'out'|'dep', amount, balBefore}
  let paid = 0;
  for (let i = 0; i < 400; i++) {
    const r = rnd();
    h.warp(Math.floor(rnd() * 5400)); // 0..1.5h
    const bal = h.vaultSol(c.sanctum);
    if (r < 0.12) {
      const amt = BigInt(Math.floor(rnd() * 5e9));
      if (amt > 0n) { h.send(S.depositSol({ depositor: c.hot.publicKey, sanctum: c.sanctum, amount: amt }), [c.hot]); log.push({ t: h.now, kind: "dep", amount: amt, bal }); }
    } else if (r < 0.15) {
      h.send(S.coldSetRules({ cold: c.cold.publicKey, sanctum: c.sanctum, rules: S.DEFAULT_RULES }), [c.cold]); // no-op churn
    } else {
      const frac = rnd() < 0.5 ? rnd() * 0.06 : rnd() * 0.12;
      const amt = BigInt(Math.floor(Number(bal) * frac)) + 1n;
      if (amt > bal) continue;
      const cold = rnd() < 0.3;
      const before = h.lamports(dest);
      try {
        if (cold) h.send(S.coldWithdrawSol({ cold: c.cold.publicKey, sanctum: c.sanctum, to: dest, amount: amt }), [c.cold]);
        else h.withdrawSol(c, amt, dest);
      } catch (e) { if (!/HourlyCap|DailyCap/.test(e.message)) throw e; }
      const out = h.lamports(dest) - before;
      if (out > 0n) { paid++; log.push({ t: h.now, kind: "out", amount: out, bal }); }
    }
  }
  assert.ok(paid > 50, `enough paid withdrawals (${paid})`);
  // check every window starting at each event time
  let worst = 0;
  for (const start of log) {
    const end = start.t + 86400n;
    let out = 0n, dep = 0n;
    for (const e of log) if (e.t >= start.t && e.t < end) { if (e.kind === "out") out += e.amount; else dep += e.amount; }
    const basis = start.bal + dep;
    assert.ok(out * 10n <= basis, `window @${start.t}: out ${out} > 10% of ${basis}`);
    worst = Math.max(worst, Number(out) / Number(basis));
  }
  console.log(`fuzz: ${paid} paid outflows, worst 24h window = ${(worst * 100).toFixed(3)}% (limit 10%)`);
});
