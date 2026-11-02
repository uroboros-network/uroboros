// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture, RejectingSink} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {BountySanctum} from "../src/BountySanctum.sol";
import {BountyCold} from "../src/BountyCold.sol";
import {Blacklist} from "../src/Blacklist.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";

/// AUDIT-3 (pre-launch, after step 3). Naming: `test_A3_<id>_...`. Every test PASSES: a finding test asserts the
/// behaviour that exists today (so the PoC is the green test), a `_verify_` test pins an AUDIT-2 fix or a proof.
/// See AUDIT-3.md for severities.

// ---------------------------------------------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------------------------------------------

/// An "ERC-20" anyone can deploy: reports a huge balance, transfers nothing, and can re-enter the bounty key.
contract FakeToken {
    BountySanctum public bounty;
    address public loot;
    bool public reenter;
    uint256 public reentrantPaid;
    function arm(BountySanctum b, address l) external { bounty = b; loot = l; reenter = true; }
    function balanceOf(address) external pure returns (uint256) { return 1e30; }
    function transfer(address, uint256) external returns (bool) {
        if (reenter) {
            reenter = false;
            uint256 room = bounty.probeRoom();
            bounty.withdraw(address(0), address(bounty.sanctum()), room);
            reentrantPaid += room;
            // a second ETH probe in the same frame must hit the caps
            try bounty.withdraw(address(0), address(bounty.sanctum()), 1) { reentrantPaid += 1; } catch {}
        }
        return true;
    }
}

interface Ownable2StepLike {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

// ---------------------------------------------------------------------------------------------------------------
// Sanctum / BountySanctum / guardians / subscription (no pool needed)
// ---------------------------------------------------------------------------------------------------------------

contract Audit3SanctumTest is Fixture {
    address admin = makeAddr("a3.admin");
    address robber = makeAddr("a3.robber");
    address robber2 = makeAddr("a3.robber2");
    address loot = makeAddr("a3.loot");
    address funder = makeAddr("a3.funder");
    address evil = makeAddr("a3.evilCold");

    // ledger for the strict-window proof: signed balance deltas with timestamps
    uint256[] evT;
    int256[] evD;
    uint256 bal0;
    uint256 tStart;

    function setUp() public { _base(); }

    function _bounty() internal returns (BountySanctum b, Sanctum s) {
        vm.deal(admin, 10 ether);
        vm.prank(admin);
        b = new BountySanctum{value: 0.5 ether}(address(factory), admin, _three(), 0);
        s = b.sanctum();
    }

    // ====================================================================================================
    // §2 rolling 24h: any strict 24h window (T, T+24h] pays out ≤ dayCapBps × (balance at T + deposits in window)
    // ====================================================================================================

    function _balAt(uint256 T) internal view returns (uint256 b) {
        int256 x = int256(bal0);
        for (uint256 i; i < evT.length; ++i) if (evT[i] <= T) x += evD[i];
        b = uint256(x);
    }

    /// Checks every window of length ≤ 24h that ends now and starts at now−24h or at any event inside it.
    function _checkWindows(uint16 dayCapBps) internal view {
        uint256 E = block.timestamp;
        uint256 lo = E >= 24 hours ? E - 24 hours : 0;
        for (uint256 k; k <= evT.length; ++k) {
            uint256 T = k == evT.length ? lo : evT[k];
            if (T < lo || T >= E) continue;
            uint256 base = _balAt(T);
            uint256 out;
            uint256 dep;
            for (uint256 i; i < evT.length; ++i) {
                if (evT[i] > T && evT[i] <= E) {
                    if (evD[i] < 0) out += uint256(-evD[i]);
                    else dep += uint256(evD[i]);
                }
            }
            assertLe(out * 10_000, uint256(dayCapBps) * (base + dep), "strict 24h window above dayCap");
        }
    }

    function _roll(Sanctum s, uint16 dayCapBps, uint256 seed) internal {
        bal0 = address(s).balance;
        tStart = block.timestamp;
        for (uint256 i; i < 40; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            // time step: hit hour boundaries on purpose (−1 s / exact / +1 s), short hops and long gaps
            uint256 mode = (r >> 8) % 5;
            uint256 now_ = block.timestamp;
            if (mode == 0) vm.warp(now_ - now_ % 1 hours + 1 hours - 1);
            else if (mode == 1) vm.warp(now_ - now_ % 1 hours + 1 hours);
            else if (mode == 2) vm.warp(now_ + 1);
            else if (mode == 3) vm.warp(now_ + ((r >> 16) % 3 hours));
            else vm.warp(now_ + 59 minutes + ((r >> 24) % 2 minutes));

            if (r % 10 < 2) {
                uint256 amt = 1 ether + (r >> 32) % 20 ether;
                vm.deal(funder, amt);
                vm.prank(funder);
                (bool okd,) = address(s).call{value: amt}("");
                require(okd);
                evT.push(block.timestamp);
                evD.push(int256(amt));
            } else {
                uint256 room = s.capRoom(address(0));
                uint256 amt = room * ((r >> 40) % 150) / 100; // 0..149% of the room: over-cap attempts too
                if (amt == 0) amt = 1;
                vm.prank(cold);
                (bool ok,) = address(s).call(abi.encodeCall(Sanctum.coldWithdraw, (address(0), loot, amt)));
                if (ok) {
                    assertLe(amt, room, "paid above capRoom");
                    evT.push(block.timestamp);
                    evD.push(-int256(amt));
                    _checkWindows(dayCapBps);
                } else {
                    assertGt(amt, room, "refused inside capRoom");
                }
            }
        }
    }

    /// default rules 5%/h · 10%/24h
    function testFuzz_A3_verify_rolling24h_strict_window_default(uint256 seed) public {
        Sanctum s = _sanctum(); // 100 ETH
        _roll(s, 1000, seed);
    }

    /// bounty rules 1%/h · 2%/24h
    function testFuzz_A3_verify_rolling24h_strict_window_bounty_rules(uint256 seed) public {
        vm.deal(hot, 100 ether);
        vm.prank(hot);
        Sanctum s = Sanctum(payable(factory.createWithRules{value: 100 ether}(
            cold, _none(), 0, Sanctum.Rules({capBps: 100, dayCapBps: 200, delayBps: 10_000, delay: 24 hours, allowlistOn: false})
        )));
        _roll(s, 200, seed);
    }

    /// Worst case inside one wall-clock hour (fixed hourly window): two caps one second apart.
    /// Default: 5% + 4.75% = 9.75% in 1 s, then only 0.25% more for the rest of the 24h. Total ≤ 10% per strict 24h.
    function test_A3_I1_hourly_double_raid_default_quantified() public {
        Sanctum s = _sanctum(); // 100 ETH
        uint256 t = (block.timestamp / 1 hours + 1) * 1 hours + 600; // mid-hour start
        vm.warp(t);
        vm.startPrank(cold);
        s.coldWithdraw(address(0), loot, 1); // opens the hourly window at t
        vm.warp(t + 3599);
        s.coldWithdraw(address(0), loot, s.capRoom(address(0))); // rest of window 1
        vm.warp(t + 3600);
        uint256 second = s.capRoom(address(0));
        s.coldWithdraw(address(0), loot, second); // window 2 opens
        vm.stopPrank();
        assertApproxEqAbs(loot.balance, 9.75 ether, 1, "9.75% inside one second");
        assertEq(s.capRoom(address(0)), 0, "hourly window 2 is full");
        vm.warp(t + 7200);
        assertEq(s.capRoom(address(0)), 0.25 ether, "0.25% left for the rest of the rolling day");
        // walk 25 hours: nothing beyond 10% total in any strict 24h
        uint256 paid = loot.balance;
        for (uint256 h = 1; h <= 24; ++h) {
            vm.warp(t + 3600 + h * 1 hours - 1);
            uint256 r = s.capRoom(address(0));
            if (r > 0) { vm.prank(cold); s.coldWithdraw(address(0), loot, r); }
            if (block.timestamp < t + 24 hours) assertLe(loot.balance, 10 ether, "10%/24h");
        }
        assertGe(loot.balance, paid);
    }

    /// Bounty: 1% + 0.99% = 1.99% of the prize inside one second, i.e. the whole daily cap room in two txs.
    /// STEP 4: the probes cycle back into the Sanctum, so the room is consumed but the prize never moves.
    function test_A3_I1_hourly_double_raid_bounty_quantified() public {
        (BountySanctum b, Sanctum s) = _bounty();
        uint256 t = (block.timestamp / 1 hours + 1) * 1 hours + 600;
        vm.warp(t);
        vm.prank(robber); b.withdraw(address(0), address(s), 1);
        vm.warp(t + 3599);
        vm.prank(robber); b.withdraw(address(0), address(s), b.probeRoom());
        vm.warp(t + 3600);
        vm.prank(robber); b.withdraw(address(0), address(s), b.probeRoom());
        // the prize does not shrink when probes cycle back, so the second hourly window is a full 1% again
        assertEq(b.totalCycled(), 0.01 ether, "2 x 1% of 0.5 ETH cycled in 1 s");
        assertEq(b.prize(), 0.5 ether, "nothing left the Sanctum");
        assertEq(loot.balance, 0);
        assertEq(b.probeRoom(), 0, "hourly window 2 is full");
        vm.warp(t + 7200);
        // rolling day room = 2% x (balance + 24h outflow) - 24h outflow = 2% x 0.51 - 0.01
        assertApproxEqAbs(b.probeRoom(), 0.0002 ether, 2, "0.04% left in the rolling day");
    }

    // ====================================================================================================
    // §3 BountySanctum
    // ====================================================================================================

    /// M1 (why BountyCold exists): with an EOA as the bounty's cold key, coldSetRules loosens at once and
    /// coldWithdraw takes the whole prize in the same block. Production uses BountyCold (Audit3BountyColdTest).
    function test_A3_M1_bounty_cold_loosens_rules_and_takes_prize_in_one_block() public {
        (BountySanctum b, Sanctum s) = _bounty();
        vm.deal(address(this), 3 ether);
        (bool ok,) = address(b).call{value: 3 ether}(""); // plain top-ups
        require(ok);
        uint256 prize = b.prize();
        vm.startPrank(admin);
        s.coldSetRules(Sanctum.Rules({capBps: 10_000, dayCapBps: 10_000, delayBps: 10_000, delay: 0, allowlistOn: false}));
        s.coldWithdraw(address(0), admin, prize);
        vm.stopPrank();
        assertEq(b.prize(), 0);
        assertEq(admin.balance, 10 ether - 0.5 ether + prize);
    }

    /// I-cold: the same is true for EVERY Sanctum: a stolen cold key empties it in one tx, even while frozen.
    function test_A3_I2_stolen_cold_key_drains_frozen_sanctum_in_one_tx() public {
        Sanctum s = _sanctumWith(_three(), 0);
        vm.prank(g1); s.panic();
        assertGt(s.frozenUntil(), block.timestamp);
        vm.startPrank(cold);
        s.unfreeze();
        s.coldSetRules(Sanctum.Rules({capBps: 10_000, dayCapBps: 10_000, delayBps: 10_000, delay: 0, allowlistOn: false}));
        s.coldWithdraw(address(0), evil, 100 ether);
        vm.stopPrank();
        assertEq(evil.balance, 100 ether);
        // guardians are muted for 24h after the unfreeze and could not have stopped it anyway
        vm.prank(g2); vm.expectRevert("muted"); s.panic();
    }

    /// L1 SUPERSEDED by the STEP 4 redesign ("main vault = break-the-caps bounty"): the self-loop is now the
    /// ONLY allowed destination. Every other `to` (the key, the robber, any wallet) reverts "to"; a probe to the
    /// Sanctum consumes the cap room like a real withdrawal and the prize never moves. The AUDIT-3 L1 grief (probes
    /// burning the room of honest raiders) no longer matters: there is no honest outflow left to block.
    function test_STEP4_L1_self_loop_is_the_only_destination() public {
        (BountySanctum b, Sanctum s) = _bounty();
        uint256 prize0 = b.prize();
        uint256 room = b.probeRoom();
        assertGt(room, 0);
        vm.prank(robber); vm.expectRevert(bytes("to")); b.withdraw(address(0), loot, 1);
        vm.prank(robber); vm.expectRevert(bytes("to")); b.withdraw(address(0), robber, 1);
        vm.prank(robber); vm.expectRevert(bytes("to")); b.withdraw(address(0), address(b), 1);
        vm.prank(robber); vm.expectRevert(bytes("to")); b.withdraw(address(0), admin, 1);
        assertEq(b.probeRoom(), room, "cap room untouched by refused calls");
        assertEq(b.attempts(), 0);
        vm.prank(robber2); b.withdraw(address(0), address(s), room);
        assertEq(b.prize(), prize0, "the probe came straight back");
        assertEq(b.totalCycled(), room);
        assertEq(b.attempts(), 1);
        assertEq(b.probeRoom(), 0, "room consumed exactly like a real withdrawal");
        assertEq(loot.balance + robber2.balance, 0);
    }

    /// L2 FIXED: only ETH raids. A fake "token" (huge balanceOf, re-entrant transfer) reverts "eth only" before any
    /// call to it: no Attempt/Sent events, no attempts, no re-entry, the ETH room is intact.
    function test_FIXED_L2_fake_token_rejected_eth_only() public {
        (BountySanctum b, Sanctum s) = _bounty();
        FakeToken f = new FakeToken();
        f.arm(b, loot);
        uint256 room = b.probeRoom();
        vm.recordLogs();
        vm.prank(robber); vm.expectRevert(bytes("eth only")); b.withdraw(address(f), address(s), 1e28);
        assertEq(vm.getRecordedLogs().length, 0, "no events");
        assertEq(b.attempts(), 0);
        assertEq(b.totalCycled(), 0);
        assertEq(f.reentrantPaid(), 0, "token never called");
        assertEq(loot.balance, 0);
        assertEq(b.probeRoom(), room);
        // the ETH path is unchanged
        vm.prank(robber); b.withdraw(address(0), address(s), room);
        assertEq(b.attempts(), 1);
        assertEq(s.queueLength(), 0);
    }

    /// L2 FIXED, no regression: stray ERC-20s sent to the key are still swept to the cold key.
    function test_FIXED_L2_sweep_still_sends_stray_erc20_to_cold() public {
        (BountySanctum b,) = _bounty();
        token.mint(address(b), 7e18);
        b.sweep(address(token));
        assertEq(token.balanceOf(admin), 7e18);
        assertEq(token.balanceOf(address(b)), 0);
    }

    /// Admin-chosen guardians can keep the game frozen indefinitely (re-panic in the last hour, rotating guardians).
    function test_A3_I3_guardians_can_freeze_bounty_indefinitely() public {
        (BountySanctum b, Sanctum s) = _bounty();
        address[3] memory g = [g1, g2, g3];
        for (uint256 d; d < 6; ++d) {
            vm.prank(g[d % 3]); s.panic();
            for (uint256 h; h < 23; ++h) {
                assertEq(b.probeRoom(), 0);
                vm.warp(block.timestamp + 1 hours);
            }
            vm.warp(block.timestamp + 30 minutes); // last hour of the freeze
        }
        assertEq(b.probeRoom(), 0, "6 days frozen");
        vm.prank(robber); vm.expectRevert("frozen"); b.withdraw(address(0), address(s), 1);
    }

    /// No queue path even when the admin sets delayBps below capBps: the raid reverts "queued", nothing is parked.
    function test_A3_verify_no_queue_even_with_low_delayBps() public {
        (BountySanctum b, Sanctum s) = _bounty();
        vm.prank(admin);
        s.coldSetRules(Sanctum.Rules({capBps: 100, dayCapBps: 200, delayBps: 50, delay: 24 hours, allowlistOn: false}));
        uint256 room = b.probeRoom();
        vm.prank(robber); vm.expectRevert("queued"); b.withdraw(address(0), address(s), room);
        assertEq(s.queueLength(), 0);
        vm.prank(robber); b.withdraw(address(0), address(s), room / 2 - 1); // below 0.5% still cycles
        assertEq(s.queueLength(), 0);
    }

    // ====================================================================================================
    // §4 guardians / recovery / watchers / trial
    // ====================================================================================================

    function test_A3_verify_colluding_guardians_loop_until_set_shrinks() public {
        Sanctum s = _sanctumWith(_three(), 0); // threshold 2
        for (uint256 i; i < 3; ++i) {
            vm.prank(g1); s.proposeCold(evil);
            vm.prank(g2); s.proposeCold(evil);
            assertEq(s.proposedCold(), evil);
            vm.warp(block.timestamp + 6 days); // cold must answer inside every 7-day timer
            vm.prank(cold); s.cancelRecovery();
        }
        // a running recovery is voided by setGuardians, and the removed pair can no longer vote
        vm.prank(g1); s.proposeCold(evil);
        vm.prank(g2); s.proposeCold(evil);
        address[] memory one = new address[](1); one[0] = g3;
        vm.prank(cold); s.setGuardians(one, 0);
        assertEq(s.recoveryReadyAt(), 0);
        vm.prank(g1); vm.expectRevert("guardian"); s.proposeCold(evil);
    }

    function test_A3_verify_recovery_executes_while_frozen_hot_key_survives() public {
        Sanctum s = _sanctumWith(_three(), 0);
        address newCold = makeAddr("a3.newCold");
        vm.prank(g1); s.proposeCold(newCold);
        vm.prank(g2); s.proposeCold(newCold);
        vm.warp(block.timestamp + 7 days - 30 minutes);
        vm.prank(g3); s.panic();
        vm.warp(block.timestamp + 30 minutes);
        assertGt(s.frozenUntil(), block.timestamp);
        s.executeRecovery(); // anyone, while frozen
        assertEq(s.cold(), newCold);
        assertEq(s.owner(), hot, "old hot key stays the owner until the new cold rotates it");
        vm.prank(newCold); s.unfreeze();
        vm.prank(newCold); s.setOwner(newCold);
    }

    function test_A3_verify_watchersOn_with_zero_registry_is_noop() public {
        Sanctum s = _sanctum();
        vm.startPrank(cold);
        s.setWatcherRegistry(address(0));
        s.setWatchersOn(true);
        vm.stopPrank();
        vm.prank(watcher); vm.expectRevert("standing"); s.panic();
    }

    /// L3: the AUDIT-2 L2 fix (no trial for custom rules) is bypassed with the default rules: coldSetRules is
    /// instant and loosening, so the same $120 starts a new 7-day trial every tx, in one block.
    function test_A3_L3_trial_recycled_same_block_via_coldSetRules() public {
        address farmer = makeAddr("a3.farmer");
        vm.deal(farmer, 0.04 ether); // $120 at $3000
        for (uint256 i; i < 5; ++i) {
            vm.prank(farmer);
            Sanctum s = Sanctum(payable(factory.create{value: 0.04 ether}(farmer, _none(), 0)));
            assertEq(sub.coveredUntil(address(s)), block.timestamp + 7 days, "trial granted");
            vm.startPrank(farmer);
            s.coldSetRules(Sanctum.Rules({capBps: 10_000, dayCapBps: 10_000, delayBps: 10_000, delay: 0, allowlistOn: false}));
            s.coldWithdraw(address(0), farmer, 0.04 ether);
            vm.stopPrank();
        }
        assertEq(farmer.balance, 0.04 ether, "five trials for one $120 deposit, same block");
    }

    // ====================================================================================================
    // Recovery on/off switch (STEP3-FIXES-2): cold-only, default on, off = no votes + running recovery cancelled
    // ====================================================================================================

    event RecoveryOffSet(bool off);
    event RecoveryCancelled(address by);

    function test_FIXED_recovery_off_default_on_and_cold_only_switch() public {
        Sanctum s = _sanctumWith(_three(), 0);
        assertFalse(s.recoveryOff(), "personal Sanctums keep recovery on by default");
        vm.prank(hot); vm.expectRevert(bytes("cold")); s.setRecoveryOff(true);
        vm.prank(g1); vm.expectRevert(bytes("cold")); s.setRecoveryOff(true);
        vm.prank(evil); vm.expectRevert(bytes("cold")); s.setRecoveryOff(true);
        vm.expectEmit(address(s)); emit RecoveryOffSet(true);
        vm.prank(cold); s.setRecoveryOff(true);
        assertTrue(s.recoveryOff());
        vm.expectEmit(address(s)); emit RecoveryOffSet(false);
        vm.prank(cold); s.setRecoveryOff(false);
        assertFalse(s.recoveryOff());
        // back on: guardians can run a recovery again
        vm.prank(g1); s.proposeCold(evil);
        vm.prank(g2); s.proposeCold(evil);
        assertEq(s.proposedCold(), evil);
    }

    function test_FIXED_recovery_off_proposeCold_reverts() public {
        Sanctum s = _sanctumWith(_three(), 0);
        vm.prank(cold); s.setRecoveryOff(true);
        vm.prank(g1); vm.expectRevert(bytes("recovery off")); s.proposeCold(evil);
        vm.prank(g2); vm.expectRevert(bytes("recovery off")); s.proposeCold(evil);
        vm.prank(evil); vm.expectRevert(bytes("recovery off")); s.proposeCold(evil);
        assertEq(s.votesFor(s.recoveryEpoch(), evil), 0);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(bytes("no recovery")); s.executeRecovery();
        assertEq(s.cold(), cold);
        // guardians keep their panic
        vm.prank(g1); s.panic();
        assertGt(s.frozenUntil(), block.timestamp);
    }

    function test_FIXED_recovery_off_switching_on_cancels_running_recovery() public {
        Sanctum s = _sanctumWith(_three(), 0);
        vm.prank(g1); s.proposeCold(evil); // a pending vote (not yet a recovery) is forgotten too
        uint256 e0 = s.recoveryEpoch();
        vm.prank(g2); s.proposeCold(evil);
        assertGt(s.recoveryReadyAt(), 0);
        vm.warp(block.timestamp + 6 days);
        vm.expectEmit(address(s)); emit RecoveryCancelled(cold);
        vm.expectEmit(address(s)); emit RecoveryOffSet(true);
        vm.prank(cold); s.setRecoveryOff(true);
        assertEq(s.recoveryReadyAt(), 0);
        assertEq(s.proposedCold(), address(0));
        assertGt(s.recoveryEpoch(), e0);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(bytes("no recovery")); s.executeRecovery();
        assertEq(s.cold(), cold);
        // switched back on later, old votes do not count: a fresh threshold is needed
        vm.prank(cold); s.setRecoveryOff(false);
        vm.prank(g1); s.proposeCold(evil);
        assertEq(s.recoveryReadyAt(), 0, "one fresh vote is not a recovery");
    }

    function test_FIXED_recovery_off_switching_on_with_nothing_running() public {
        Sanctum s = _sanctumWith(_three(), 0);
        vm.prank(g1); s.proposeCold(evil);
        vm.recordLogs();
        vm.prank(cold); s.setRecoveryOff(true);
        assertEq(vm.getRecordedLogs().length, 1, "only RecoveryOffSet, no RecoveryCancelled");
        vm.prank(cold); s.setRecoveryOff(false);
        vm.prank(g2); s.proposeCold(evil);
        assertEq(s.recoveryReadyAt(), 0, "g1's vote from before the switch was forgotten");
    }
}

// ---------------------------------------------------------------------------------------------------------------
// AUDIT-3 L4 FIXED: two-step ownership on Blacklist
// ---------------------------------------------------------------------------------------------------------------

contract Audit3OwnershipTest is Fixture {
    address alice = makeAddr("a3.alice");
    function _eoa(string memory n) internal returns (address) { return makeAddr(n); }

    /// A nomination changes nothing until the named address accepts; a wrong nominee can be overwritten; only the
    /// pending owner can accept; the old owner keeps every right until then and loses them after.
    function _twoStep(Ownable2StepLike c, address cur, function() internal ownerOnlyCall) internal {
        address typo = _eoa("a3.typo");
        address safe = _eoa("a3.safe2s");
        vm.prank(cur); c.transferOwnership(typo);
        assertEq(c.owner(), cur, "nomination does not move ownership");
        assertEq(c.pendingOwner(), typo);
        vm.prank(cur); c.transferOwnership(safe); // fix the typo: still owner, can re-nominate
        vm.prank(typo); vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, typo));
        c.acceptOwnership();
        vm.prank(safe); c.acceptOwnership();
        assertEq(c.owner(), safe);
        assertEq(c.pendingOwner(), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, cur));
        ownerOnlyCall();
    }

    address _oc; // caller for the owner-only probe
    Blacklist _bl;
    function _probeBlacklist() internal { vm.prank(_oc); _bl.setOracle(alice, true); }

    function test_FIXED_L4_blacklist_two_step_ownership() public {
        vm.prank(deployer); _bl = new Blacklist();
        _oc = deployer;
        _twoStep(Ownable2StepLike(address(_bl)), deployer, _probeBlacklist);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// AUDIT-3 M1 FIXED: the bounty Sanctum's cold key is BountyCold, a locker that can only panic,
// unfreeze and setGuardians (owner). Guardian recovery is switched off in its constructor and can never be switched
// back on (STEP3-FIXES-2), so the cold key is BountyCold forever. The prize leaves only through raids.
// ---------------------------------------------------------------------------------------------------------------

/// Random sequences of everything BountyCold exposes (owner and strangers), guardian freezes and recovery votes,
/// top-ups, probes (STEP 4: they cycle back), ownership hand-overs and time. Ghost ledger: prize == seed + top-ups.
contract BountyColdHandler is Fixture {
    BountyCold public bc;
    BountySanctum public b;
    Sanctum public s;
    address public owner_;
    address[] public actors;
    uint256 public ghostIn;
    uint256 public ghostCycled;
    uint256 public calls;

    constructor(BountyCold _bc, address _owner) {
        bc = _bc; b = _bc.bounty(); s = _bc.sanctum(); owner_ = _owner;
        actors.push(_owner); actors.push(makeAddr("h.stranger")); actors.push(makeAddr("h.robber"));
        actors.push(makeAddr("h.g1")); actors.push(makeAddr("h.g2")); actors.push(makeAddr("h.g3"));
        actors.push(makeAddr("h.safe"));
    }

    function _who(uint256 i) internal view returns (address) { return actors[i % actors.length]; }

    function warp(uint256 dt) external {
        dt = bound(dt, 0, 8 days); // no watcher duty modelled any more: nobody cancels anything
        vm.warp(block.timestamp + dt);
        calls++;
    }

    function panic(uint256 w) external { vm.prank(_who(w)); try bc.panic() {} catch {} calls++; }
    function unfreeze(uint256 w) external { vm.prank(_who(w)); try bc.unfreeze() {} catch {} calls++; }
    /// Every actor tries to execute a recovery and to switch recovery back on, directly on the Sanctum.
    function tryRecovery(uint256 w) external {
        address a = _who(w);
        vm.startPrank(a);
        try s.setRecoveryOff(false) { revert("setRecoveryOff reachable"); } catch {}
        try s.executeRecovery() { revert("executeRecovery reachable"); } catch {}
        try s.cancelRecovery() { revert("cancelRecovery reachable"); } catch {}
        vm.stopPrank();
        calls++;
    }

    function setGuardians(uint256 w, uint256 mask, uint8 th) external {
        address[] memory g = new address[](0);
        uint256 n;
        for (uint256 i; i < actors.length && n < 5; ++i) if ((mask >> i) & 1 == 1) n++;
        g = new address[](n);
        n = 0;
        for (uint256 i; i < actors.length && n < g.length; ++i) if ((mask >> i) & 1 == 1) g[n++] = actors[i];
        vm.prank(_who(w)); try bc.setGuardians(g, uint8(bound(th, 0, g.length))) {} catch {}
        calls++;
    }

    function guardianPanic(uint256 w) external { vm.prank(_who(w)); try s.panic() {} catch {} calls++; }

    function guardianVote(uint256 w, uint256 c) external {
        vm.prank(_who(w)); try s.proposeCold(_who(c)) {} catch {}
        calls++;
    }

    function handOver(uint256 w, uint256 to) external {
        vm.prank(_who(w)); try bc.transferOwnership(_who(to)) {} catch {}
        vm.prank(_who(to)); try bc.acceptOwnership() {} catch {}
        calls++;
    }

    function topUp(uint256 amt) external {
        amt = bound(amt, 1, 5 ether);
        vm.deal(address(this), amt);
        b.topUp{value: amt}();
        ghostIn += amt;
        calls++;
    }

    function raid(uint256 w, uint256 amt) external {
        uint256 room = b.probeRoom();
        if (room == 0) return;
        amt = bound(amt, 1, room);
        address r = _who(w);
        vm.prank(r);
        try b.withdraw(address(0), r, amt) { revert("probe to a wallet paid"); } catch {}
        vm.prank(r);
        b.withdraw(address(0), address(s), amt); // the only destination: comes straight back
        ghostCycled += amt;
        calls++;
    }

    /// Every fund-moving / loosening Sanctum entry point, tried by every actor directly on the Sanctum. The only
    /// address that could call them (the cold key) is BountyCold, which has no path to them.
    function tryColdPowers(uint256 w) external {
        address a = _who(w);
        vm.startPrank(a);
        try s.coldWithdraw(address(0), a, 1) { revert("coldWithdraw reachable"); } catch {}
        try s.coldSetRules(Sanctum.Rules({capBps: 10_000, dayCapBps: 10_000, delayBps: 10_000, delay: 0, allowlistOn: false})) { revert("coldSetRules reachable"); } catch {}
        try s.setOwner(a) { revert("setOwner reachable"); } catch {}
        try s.setCold(a) { revert("setCold reachable"); } catch {}
        try s.withdraw(address(0), a, 1) { revert("withdraw reachable"); } catch {}
        vm.stopPrank();
        calls++;
    }
}

contract Audit3BountyColdTest is Fixture {
    BountyCold bc;
    BountySanctum b;
    Sanctum s;
    BountyColdHandler h;
    address dev = makeAddr("a3.dev");
    address safe = makeAddr("a3.safe");
    address robber = makeAddr("a3.robber");
    uint256 constant SEED = 0.5 ether;

    function setUp() public {
        _base();
        vm.deal(dev, 10 ether);
        vm.prank(dev);
        bc = new BountyCold{value: SEED}(dev, address(factory), _three(), 0);
        b = bc.bounty();
        s = bc.sanctum();
        h = new BountyColdHandler(bc, dev);
        targetContract(address(h));
    }

    // ---- invariants over random call sequences ------------------------------------------------------------

    function invariant_FIXED_M1_prize_leaves_only_through_raids() public view {
        // STEP 4: probes cycle back, so nothing leaves at all
        assertEq(b.prize(), SEED + h.ghostIn(), "prize == seed + top-ups");
        assertEq(b.totalCycled(), h.ghostCycled());
        assertEq(s.queueLength(), 0, "nothing ever queued");
    }

    function invariant_FIXED_M1_rules_and_keys_never_change() public view {
        (uint16 cap, uint16 day, uint16 dbps, uint32 delay, bool al) = s.rules();
        assertEq(cap, 100); assertEq(day, 200); assertEq(dbps, 10_000); assertEq(delay, 24 hours); assertFalse(al);
        assertEq(s.owner(), address(b), "hot key is the BountySanctum forever");
        assertEq(s.cold(), address(bc), "cold key is BountyCold forever (no watcher needed)");
        assertTrue(s.recoveryOff(), "recovery stays off");
        assertEq(s.recoveryReadyAt(), 0, "no recovery ever starts");
        assertEq(s.proposedCold(), address(0));
        assertEq(address(s.blacklist()), address(blacklist));
        assertFalse(s.watchersOn());
        assertEq(s.rulesReadyAt(), 0, "no pending rule change");
        assertEq(address(bc).balance, 0);
        assertEq(address(b).balance, 0);
    }

    /// No call sequence on BountyCold (or directly on the Sanctum, by any actor) turns recovery back on.
    function invariant_FIXED_recovery_off_bounty_never_back_on() public view {
        assertTrue(s.recoveryOff());
        assertEq(s.recoveryReadyAt(), 0);
        assertEq(s.cold(), address(bc));
    }

    // ---- unit proofs ------------------------------------------------------------------------------------

    function test_FIXED_M1_wiring_cold_is_locker() public view {
        assertEq(s.cold(), address(bc));
        assertEq(b.cold(), address(bc));
        assertEq(s.owner(), address(b));
        assertEq(bc.owner(), dev);
        assertEq(b.prize(), SEED);
        assertEq(s.guardianCount(), 3);
    }

    /// BountyCold has no fallback and no generic call: every Sanctum cold/owner selector sent to it reverts.
    function test_FIXED_M1_no_fund_moving_selector_on_bountyCold() public {
        bytes[] memory calls_ = new bytes[](19);
        calls_[0] = abi.encodeCall(Sanctum.coldWithdraw, (address(0), dev, 1));
        calls_[1] = abi.encodeCall(Sanctum.coldSetRules, (Sanctum.Rules(10_000, 10_000, 10_000, 0, false)));
        calls_[2] = abi.encodeCall(Sanctum.setAllowlist, (dev, true));
        calls_[3] = abi.encodeCall(Sanctum.setOwner, (dev));
        calls_[4] = abi.encodeCall(Sanctum.setCold, (dev));
        calls_[5] = abi.encodeCall(Sanctum.setBlacklist, (address(0)));
        calls_[6] = abi.encodeCall(Sanctum.setWatcherRegistry, (address(0)));
        calls_[7] = abi.encodeCall(Sanctum.setWatchersOn, (true));
        calls_[8] = abi.encodeCall(Sanctum.setRequireApproval, (true));
        calls_[9] = abi.encodeCall(Sanctum.approveQueued, (0));
        calls_[10] = abi.encodeCall(Sanctum.executeQueued, (0));
        calls_[11] = abi.encodeCall(Sanctum.cancel, (0));
        calls_[12] = abi.encodeCall(Sanctum.withdraw, (address(0), dev, 1));
        calls_[13] = abi.encodeCall(Sanctum.proposeRules, (Sanctum.Rules(100, 200, 10_000, 24 hours, false)));
        calls_[14] = abi.encodeCall(Sanctum.applyRules, ());
        calls_[15] = abi.encodeWithSignature("execute(address,bytes)", address(s), "");
        calls_[16] = abi.encodeCall(Sanctum.setRecoveryOff, (false));
        calls_[17] = abi.encodeCall(Sanctum.cancelRecovery, ());
        calls_[18] = abi.encodeWithSignature("setRecoveryOff(bool)", true);
        for (uint256 i; i < calls_.length; ++i) {
            vm.prank(dev);
            (bool ok,) = address(bc).call(calls_[i]);
            assertFalse(ok, "BountyCold must not expose this");
        }
        (bool ok2,) = address(bc).call{value: 1}("");
        assertFalse(ok2, "no receive");
        assertEq(b.prize(), SEED);
    }

    /// Owner powers are panic / unfreeze / setGuardians only; strangers get none of them; nothing moves funds.
    function test_FIXED_M1_owner_powers_are_freeze_and_guardians_only() public {
        vm.prank(robber); vm.expectRevert(); bc.panic();
        vm.prank(robber); vm.expectRevert(); bc.unfreeze();
        vm.prank(robber); vm.expectRevert(); bc.setGuardians(_none(), 0);
        vm.prank(dev); bc.panic();
        vm.prank(robber); vm.expectRevert(bytes("frozen")); b.withdraw(address(0), address(s), 1);
        vm.prank(dev); bc.unfreeze();
        uint256 room = b.probeRoom();
        vm.prank(robber); b.withdraw(address(0), address(s), room);
        vm.prank(dev); bc.setGuardians(_none(), 0);
        assertEq(s.guardianCount(), 0);
        assertEq(b.prize(), SEED, "probe cycled back");
        assertEq(dev.balance, 10 ether - SEED, "owner gained nothing");
    }

    /// The bounty Sanctum has recovery off from the creation tx: guardians cannot vote, nothing can execute.
    function test_FIXED_recovery_off_bounty_from_construction() public {
        assertTrue(s.recoveryOff());
        vm.prank(g1); vm.expectRevert(bytes("recovery off")); s.proposeCold(dev);
        vm.prank(g2); vm.expectRevert(bytes("recovery off")); s.proposeCold(dev);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(bytes("no recovery")); s.executeRecovery();
        assertEq(s.cold(), address(bc));
        // a new guardian set (owner) does not turn it back on
        vm.prank(dev); bc.setGuardians(_one(), 0);
        vm.prank(g1); vm.expectRevert(bytes("recovery off")); s.proposeCold(dev);
        // nobody but BountyCold can switch it, and BountyCold has no function for it
        address[3] memory who = [dev, g1, robber];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]); vm.expectRevert(bytes("cold")); s.setRecoveryOff(false);
        }
        assertTrue(s.recoveryOff());
    }

    /// Step-3's residual is closed: the 7-day uncancelled recovery that replaced BountyCold can no longer start.
    function test_FIXED_recovery_off_bounty_gap_closed() public {
        vm.prank(g1); vm.expectRevert(bytes("recovery off")); s.proposeCold(dev);
        vm.warp(block.timestamp + 7 days);
        vm.expectRevert(bytes("no recovery")); s.executeRecovery();
        assertEq(s.cold(), address(bc), "cold key is still the locker");
    }

    /// The constructor's single setRecoveryOff(true) is visible as an event in the creation tx.
    function test_FIXED_recovery_off_bounty_event_in_creation_tx() public {
        vm.deal(dev, 1 ether);
        vm.recordLogs();
        vm.prank(dev);
        BountyCold bc2 = new BountyCold{value: 0.1 ether}(dev, address(factory), _three(), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(bc2.sanctum()) && logs[i].topics[0] == keccak256("RecoveryOffSet(bool)")) {
                assertEq(abi.decode(logs[i].data, (bool)), true);
                seen = true;
            }
        }
        assertTrue(seen, "RecoveryOffSet(true) emitted at construction");
        assertTrue(bc2.sanctum().recoveryOff());
    }

    function test_FIXED_M1_bountyCold_two_step_and_no_renounce() public {
        vm.prank(dev); vm.expectRevert(bytes("no renounce")); bc.renounceOwnership();
        vm.prank(dev); bc.transferOwnership(safe);
        assertEq(bc.owner(), dev);
        vm.prank(dev); bc.panic(); // still owner while pending
        vm.prank(safe); bc.acceptOwnership();
        assertEq(bc.owner(), safe);
        vm.prank(dev); vm.expectRevert(); bc.unfreeze();
        vm.prank(safe); bc.unfreeze();
    }

    /// Stray ERC-20s swept from the key go to the cold key = BountyCold, where they stay (no exit). Documented.
    function test_FIXED_M1_sweep_lands_in_bountyCold() public {
        token.mint(address(b), 1e18);
        b.sweep(address(token));
        assertEq(token.balanceOf(address(bc)), 1e18);
    }
}
