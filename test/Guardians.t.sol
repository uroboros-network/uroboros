// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {Fixture} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";

/// SPEC §3.1: guardians (0–5, cold-set), one-guardian panic with the sticky/mute rules, M-of-N recovery
/// with a 7-day timer, and the `watchersOn` opt-in.
contract GuardiansTest is Fixture {
    event GuardianPanic(address sanctum, address guardian);
    event WatcherPanic(address sanctum, address watcher);
    event Panic(address by, uint64 until);
    event GuardiansSet(address[] guardians, uint8 threshold);
    event RecoveryVote(address guardian, address newCold, uint8 votes, uint8 threshold);
    event RecoveryStarted(address newCold, uint64 readyAt);
    event RecoveryCancelled(address by);
    event RecoveryExecuted(address oldCold, address newCold);
    event ColdSet(address oldCold, address newCold);
    event WatchersOnSet(bool on);

    address newCold = makeAddr("newCold");

    function setUp() public { _base(); }

    // ---- guardian panic ----------------------------------------------------------------------------

    function test_any_one_guardian_can_panic_attributed() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.expectEmit(address(v)); emit GuardianPanic(address(v), g2);
        vm.expectEmit(address(v)); emit Panic(g2, uint64(block.timestamp + 24 hours));
        vm.prank(g2); v.panic();
        assertEq(v.frozenUntil(), block.timestamp + 24 hours);
        assertEq(v.lastPanicAt(), block.timestamp);
        vm.prank(hot); vm.expectRevert(bytes("frozen")); v.withdraw(address(0), hot, 1);
    }

    function test_non_guardian_has_no_standing() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(makeAddr("random")); vm.expectRevert(bytes("standing")); v.panic();
        vm.prank(g4); vm.expectRevert(bytes("standing")); v.panic();
        // a registered watcher is not a guardian: no standing while watchersOn is off (default)
        vm.prank(watcher); vm.expectRevert(bytes("standing")); v.panic();
        assertEq(v.frozenUntil(), 0);
    }

    function test_no_guardians_no_watchers_only_keys_can_panic() public {
        Sanctum v = _sanctumWith(_none(), 0);
        assertEq(v.guardianCount(), 0);
        assertEq(v.threshold(), 0);
        vm.prank(g1); vm.expectRevert(bytes("standing")); v.panic();
        vm.prank(watcher); vm.expectRevert(bytes("standing")); v.panic();
        vm.prank(hot); v.panic();
        assertGt(v.frozenUntil(), block.timestamp);
    }

    function test_guardian_muted_24h_after_cold_unfreeze() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(g1); v.panic();
        vm.prank(cold); v.unfreeze();
        assertEq(v.frozenUntil(), 0);
        assertEq(v.guardianMutedUntil(), block.timestamp + 24 hours);
        // every guardian is muted, not only the one who panicked
        vm.prank(g1); vm.expectRevert(bytes("muted")); v.panic();
        vm.prank(g2); vm.expectRevert(bytes("muted")); v.panic();
        vm.prank(g3); vm.expectRevert(bytes("muted")); v.panic();
        vm.warp(block.timestamp + 24 hours - 1);
        vm.prank(g2); vm.expectRevert(bytes("muted")); v.panic();
        vm.warp(block.timestamp + 1);
        vm.prank(g2); v.panic();
        assertEq(v.frozenUntil(), block.timestamp + 24 hours);
    }

    function test_guardian_repanic_last_hour_only() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(g1); v.panic();
        uint64 until = v.frozenUntil();
        vm.warp(block.timestamp + 23 hours - 1);
        vm.prank(g2); vm.expectRevert(bytes("frozen: last hour only")); v.panic();
        assertEq(v.frozenUntil(), until);
        vm.warp(block.timestamp + 1); // exactly 23h in: last hour starts
        vm.prank(g2); v.panic();
        assertEq(v.frozenUntil(), block.timestamp + 24 hours);
        // and again after the freeze has lapsed
        vm.warp(block.timestamp + 25 hours);
        vm.prank(g3); v.panic();
        assertEq(v.frozenUntil(), block.timestamp + 24 hours);
    }

    /// Guardian panics carry a GuardianPanic event; owner / cold panics carry none (settlement reads this stream).
    function test_panic_attribution_stream() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(cold); v.setWatchersOn(true);
        vm.recordLogs();
        vm.prank(cold); v.panic();
        vm.prank(cold); v.unfreeze();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(g2); v.panic();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(watcher); v.panic();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 tg = keccak256("GuardianPanic(address,address)");
        bytes32 tw = keccak256("WatcherPanic(address,address)");
        uint256 ng; uint256 nw;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == tg) {
                (address s, address who) = abi.decode(logs[i].data, (address, address));
                assertEq(s, address(v)); assertEq(who, g2); ng++;
            } else if (logs[i].topics[0] == tw) {
                (address s, address who) = abi.decode(logs[i].data, (address, address));
                assertEq(s, address(v)); assertEq(who, watcher); nw++;
            }
        }
        assertEq(ng, 1); assertEq(nw, 1);
    }

    // ---- guardian set management ------------------------------------------------------------------

    function test_default_thresholds() public {
        assertEq(_sanctumWith(_none(), 0).threshold(), 0);
        assertEq(_sanctumWith(_one(), 0).threshold(), 1);
        address[] memory two = new address[](2); two[0] = g1; two[1] = g2;
        assertEq(_sanctumWith(two, 0).threshold(), 2);
        assertEq(_sanctumWith(_three(), 0).threshold(), 2);
        assertEq(_sanctumWith(_five(), 0).threshold(), 2);
        // explicit values are honoured
        assertEq(_sanctumWith(_five(), 5).threshold(), 5);
        assertEq(_sanctumWith(_five(), 1).threshold(), 1);
        assertEq(_sanctumWith(_three(), 3).threshold(), 3);
    }

    function test_set_bounds_max5_no_zero_no_duplicates_threshold() public {
        Sanctum v = _sanctumWith(_three(), 0);
        address[] memory six = new address[](6);
        for (uint256 i; i < 6; ++i) six[i] = makeAddr(string(abi.encodePacked("s", i)));
        vm.prank(cold); vm.expectRevert(bytes("max 5")); v.setGuardians(six, 0);
        address[] memory z = new address[](2); z[0] = g1; z[1] = address(0);
        vm.prank(cold); vm.expectRevert(bytes("guardian 0")); v.setGuardians(z, 0);
        address[] memory d = new address[](2); d[0] = g1; d[1] = g1;
        vm.prank(cold); vm.expectRevert(bytes("duplicate")); v.setGuardians(d, 0);
        vm.prank(cold); vm.expectRevert(bytes("threshold")); v.setGuardians(_three(), 4);
        vm.prank(cold); vm.expectRevert(bytes("threshold")); v.setGuardians(_none(), 1);
        // the factory applies the same checks at creation
        vm.prank(hot); vm.expectRevert(bytes("max 5")); factory.create(cold, six, 0);
        vm.prank(hot); vm.expectRevert(bytes("duplicate")); factory.create(cold, d, 0);
        vm.prank(hot); vm.expectRevert(bytes("guardian 0")); factory.create(cold, z, 0);
        vm.prank(hot); vm.expectRevert(bytes("threshold")); factory.create(cold, _three(), 4);
        // the set is unchanged after every failed attempt
        assertEq(v.guardianCount(), 3);
        assertTrue(v.isGuardian(g1) && v.isGuardian(g2) && v.isGuardian(g3));
    }

    function test_set_replaces_whole_set_and_emits() public {
        Sanctum v = _sanctumWith(_three(), 0);
        address[] memory n = new address[](2); n[0] = g4; n[1] = g5;
        vm.expectEmit(address(v)); emit GuardiansSet(n, 2);
        vm.prank(cold); v.setGuardians(n, 0);
        assertEq(v.guardianCount(), 2);
        assertFalse(v.isGuardian(g1)); assertFalse(v.isGuardian(g2)); assertFalse(v.isGuardian(g3));
        assertTrue(v.isGuardian(g4)); assertTrue(v.isGuardian(g5));
        address[] memory got = v.getGuardians();
        assertEq(got.length, 2); assertEq(got[0], g4); assertEq(got[1], g5);
        vm.prank(g1); vm.expectRevert(bytes("standing")); v.panic();
        vm.prank(g4); v.panic();
        // clearing the set
        vm.prank(cold); v.setGuardians(_none(), 0);
        assertEq(v.guardianCount(), 0);
        assertEq(v.threshold(), 0);
        assertFalse(v.isGuardian(g4));
        // hot key and guardians cannot manage the set
        vm.prank(hot); vm.expectRevert(bytes("cold")); v.setGuardians(_one(), 0);
        vm.prank(g1); vm.expectRevert(bytes("cold")); v.setGuardians(_one(), 0);
    }

    // ---- recovery ----------------------------------------------------------------------------------

    function test_recovery_happy_path_2_of_3() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.expectEmit(address(v)); emit RecoveryVote(g1, newCold, 1, 2);
        vm.prank(g1); v.proposeCold(newCold);
        assertEq(v.recoveryReadyAt(), 0);
        assertEq(v.votesFor(v.recoveryEpoch(), newCold), 1);
        vm.expectEmit(address(v)); emit RecoveryVote(g3, newCold, 2, 2);
        vm.expectEmit(address(v)); emit RecoveryStarted(newCold, uint64(block.timestamp + 7 days));
        vm.prank(g3); v.proposeCold(newCold);
        assertEq(v.proposedCold(), newCold);
        assertEq(v.recoveryReadyAt(), block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days - 1);
        vm.expectRevert(bytes("waiting")); v.executeRecovery();
        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(v)); emit ColdSet(cold, newCold);
        vm.expectEmit(address(v)); emit RecoveryExecuted(cold, newCold);
        vm.prank(makeAddr("anyone")); v.executeRecovery();
        assertEq(v.cold(), newCold);
        assertEq(v.proposedCold(), address(0));
        assertEq(v.recoveryReadyAt(), 0);
        // the old cold key is out, the new one is in
        vm.prank(cold); vm.expectRevert(bytes("cold")); v.unfreeze();
        vm.prank(newCold); v.coldWithdraw(address(0), newCold, 1 ether);
        assertEq(newCold.balance, 1 ether);
        vm.expectRevert(bytes("no recovery")); v.executeRecovery();
    }

    function test_recovery_threshold_enforced() public {
        Sanctum v = _sanctumWith(_five(), 3);
        vm.prank(g1); v.proposeCold(newCold);
        vm.prank(g2); v.proposeCold(newCold);
        assertEq(v.recoveryReadyAt(), 0);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(bytes("no recovery")); v.executeRecovery();
        assertEq(v.cold(), cold);
        vm.prank(g5); v.proposeCold(newCold);
        assertEq(v.recoveryReadyAt(), block.timestamp + 7 days);
    }

    function test_recovery_duplicate_vote_rejected() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(g1); v.proposeCold(newCold);
        vm.prank(g1); vm.expectRevert(bytes("voted")); v.proposeCold(newCold);
        assertEq(v.recoveryReadyAt(), 0);
        // votes are per candidate: g1 can back a different address, that does not help newCold
        vm.prank(g1); v.proposeCold(makeAddr("other"));
        assertEq(v.votesFor(v.recoveryEpoch(), newCold), 1);
        assertEq(v.recoveryReadyAt(), 0);
    }

    function test_recovery_only_guardians_vote_and_candidate_checks() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(hot); vm.expectRevert(bytes("guardian")); v.proposeCold(newCold);
        vm.prank(cold); vm.expectRevert(bytes("guardian")); v.proposeCold(newCold);
        vm.prank(makeAddr("random")); vm.expectRevert(bytes("guardian")); v.proposeCold(newCold);
        vm.prank(g1); vm.expectRevert(bytes("newCold")); v.proposeCold(address(0));
        vm.prank(g1); vm.expectRevert(bytes("newCold")); v.proposeCold(cold);
        // a Sanctum without guardians has no recovery at all
        Sanctum w = _sanctumWith(_none(), 0);
        vm.prank(g1); vm.expectRevert(bytes("guardian")); w.proposeCold(newCold);
    }

    function test_recovery_cancel_by_cold_forgets_votes() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(g1); v.proposeCold(newCold);
        vm.prank(g2); v.proposeCold(newCold);
        assertGt(v.recoveryReadyAt(), 0);
        vm.prank(hot); vm.expectRevert(bytes("cold")); v.cancelRecovery();
        vm.prank(g1); vm.expectRevert(bytes("cold")); v.cancelRecovery();
        vm.warp(block.timestamp + 7 days - 1);
        uint256 e0 = v.recoveryEpoch();
        vm.expectEmit(address(v)); emit RecoveryCancelled(cold);
        vm.prank(cold); v.cancelRecovery();
        assertEq(v.recoveryReadyAt(), 0);
        assertEq(v.proposedCold(), address(0));
        assertEq(v.recoveryEpoch(), e0 + 1);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(bytes("no recovery")); v.executeRecovery();
        assertEq(v.cold(), cold);
        vm.prank(cold); vm.expectRevert(bytes("no recovery")); v.cancelRecovery();
        // after a cancel the same guardians must vote again from zero
        vm.prank(g1); v.proposeCold(newCold);
        assertEq(v.votesFor(v.recoveryEpoch(), newCold), 1);
        assertEq(v.recoveryReadyAt(), 0);
    }

    function test_recovery_cancel_works_while_frozen_and_cold_can_still_act() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(g1); v.panic();
        vm.prank(g1); v.proposeCold(newCold);
        vm.prank(g2); v.proposeCold(newCold);
        vm.prank(cold); v.cancelRecovery();
        vm.prank(cold); v.setGuardians(_none(), 0); // rogue guardians removed
        vm.prank(g1); vm.expectRevert(bytes("guardian")); v.proposeCold(newCold);
    }

    function test_recovery_one_active_at_a_time() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(g1); v.proposeCold(newCold);
        vm.prank(g2); v.proposeCold(newCold);
        vm.prank(g3); vm.expectRevert(bytes("recovery active")); v.proposeCold(makeAddr("other"));
        vm.prank(g3); vm.expectRevert(bytes("recovery active")); v.proposeCold(newCold);
    }

    function test_guardian_set_change_voids_recovery() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(g1); v.proposeCold(newCold);
        vm.prank(g2); v.proposeCold(newCold);
        vm.prank(cold); v.setGuardians(_five(), 0);
        assertEq(v.recoveryReadyAt(), 0);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(bytes("no recovery")); v.executeRecovery();
        assertEq(v.cold(), cold);
    }

    function test_setCold_voids_recovery() public {
        Sanctum v = _sanctumWith(_three(), 0);
        vm.prank(g1); v.proposeCold(newCold);
        vm.prank(g2); v.proposeCold(newCold);
        address c2 = makeAddr("c2");
        vm.prank(cold); v.setCold(c2);
        assertEq(v.recoveryReadyAt(), 0);
        vm.warp(block.timestamp + 8 days);
        vm.expectRevert(bytes("no recovery")); v.executeRecovery();
        assertEq(v.cold(), c2);
    }

    function test_recovery_all_of_one() public {
        Sanctum v = _sanctumWith(_one(), 0);
        vm.prank(g1); v.proposeCold(newCold);
        assertEq(v.recoveryReadyAt(), block.timestamp + 7 days);
        vm.warp(block.timestamp + 7 days);
        v.executeRecovery();
        assertEq(v.cold(), newCold);
    }

    /// Recovery cannot complete before 7 days whatever the vote timing.
    function testFuzz_recovery_timer(uint256 gap, uint256 wait) public {
        Sanctum v = _sanctumWith(_three(), 0);
        gap = bound(gap, 0, 30 days);
        wait = bound(wait, 0, 14 days);
        vm.prank(g1); v.proposeCold(newCold);
        vm.warp(block.timestamp + gap);
        vm.prank(g2); v.proposeCold(newCold);
        uint256 started = block.timestamp;
        vm.warp(block.timestamp + wait);
        if (wait < 7 days) {
            vm.expectRevert(bytes("waiting"));
            v.executeRecovery();
            assertEq(v.cold(), cold);
            assertEq(v.recoveryReadyAt(), started + 7 days);
        } else {
            v.executeRecovery();
            assertEq(v.cold(), newCold);
            assertEq(v.recoveryReadyAt(), 0);
        }
    }

    // ---- watchersOn ----------------------------------------------------------------------------------

    function test_watchersOn_gates_watcher_panic() public {
        Sanctum v = _sanctumWith(_one(), 0);
        vm.prank(watcher); vm.expectRevert(bytes("standing")); v.panic();
        vm.prank(hot); vm.expectRevert(bytes("cold")); v.setWatchersOn(true);
        vm.expectEmit(address(v)); emit WatchersOnSet(true);
        vm.prank(cold); v.setWatchersOn(true);
        assertTrue(v.watchersOn());
        vm.prank(makeAddr("notWatcher")); vm.expectRevert(bytes("standing")); v.panic();
        vm.expectEmit(address(v)); emit WatcherPanic(address(v), watcher);
        vm.prank(watcher); v.panic();
        assertEq(v.frozenUntil(), block.timestamp + 24 hours);
        // deregistered watchers lose standing at once
        registry.set(watcher, false);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(watcher); vm.expectRevert(bytes("standing")); v.panic();
        registry.set(watcher, true);
        vm.prank(watcher); v.panic();
        // switching off again removes the right
        vm.prank(cold); v.setWatchersOn(false);
        vm.warp(block.timestamp + 25 hours);
        vm.prank(watcher); vm.expectRevert(bytes("standing")); v.panic();
    }

    function test_watchersOn_with_no_registry_is_noop() public {
        vm.prank(deployer);
        // factory with no registry (step 1 deploy): watchersOn can be flipped but grants nobody standing
        Sanctum v = new Sanctum(hot, cold, address(blacklist), address(0), address(feeRouter), _one(), 0, _defaults());
        vm.prank(cold); v.setWatchersOn(true);
        vm.prank(watcher); vm.expectRevert(bytes("standing")); v.panic();
        vm.prank(cold); v.setWatcherRegistry(address(registry));
        vm.prank(watcher); v.panic();
    }

    function test_watcher_mute_and_last_hour_same_as_guardian() public {
        Sanctum v = _sanctumWith(_one(), 0);
        vm.prank(cold); v.setWatchersOn(true);
        vm.prank(watcher); v.panic();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(watcher); vm.expectRevert(bytes("frozen: last hour only")); v.panic();
        vm.prank(g1); vm.expectRevert(bytes("frozen: last hour only")); v.panic();
        vm.prank(cold); v.unfreeze();
        vm.prank(watcher); vm.expectRevert(bytes("muted")); v.panic();
        vm.prank(g1); vm.expectRevert(bytes("muted")); v.panic();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(watcher); v.panic();
    }

    /// A guardian is a guardian first: even when registered as a watcher, its panic is attributed as a guardian.
    function test_guardian_who_is_also_watcher_attributed_as_guardian() public {
        Sanctum v = _sanctumWith(_one(), 0);
        registry.set(g1, true);
        vm.prank(cold); v.setWatchersOn(true);
        vm.expectEmit(address(v)); emit GuardianPanic(address(v), g1);
        vm.prank(g1); v.panic();
    }
}
