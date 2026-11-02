// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";

/// Sanctum core: tighten-only, sticky panic, panic voids queue, cold approvals, key/registry events,
/// registry opt-out.
contract SanctumCoreTest is Fixture {
    event Approved(uint256 id, address by);
    event OwnerSet(address oldOwner, address newOwner);
    event ColdSet(address oldCold, address newCold);
    event BlacklistSet(address oldBlacklist, address newBlacklist);
    event WatcherRegistrySet(address oldRegistry, address newRegistry);

    function setUp() public { _base(); }

    // ---- a. tighten-only on the hot-key path, every field --------------------------------------

    function _loosens(Sanctum.Rules memory n, Sanctum.Rules memory o) internal pure returns (bool) {
        return n.capBps > o.capBps || n.dayCapBps > o.dayCapBps || n.delayBps > o.delayBps || n.delay < o.delay || (o.allowlistOn && !n.allowlistOn);
    }

    function testFuzz_hot_key_cannot_loosen_any_field(uint16 cap, uint16 day, uint16 dbps, uint32 delay, bool al, bool startAl) public {
        Sanctum v = _sanctum();
        if (startAl) { vm.prank(cold); v.coldSetRules(Sanctum.Rules(500, 1000, 1000, 6 hours, true)); }
        cap = uint16(bound(cap, 0, 10_000)); day = uint16(bound(day, 0, 10_000)); dbps = uint16(bound(dbps, 0, 10_000));
        Sanctum.Rules memory r = Sanctum.Rules(cap, day, dbps, delay, al);
        (uint16 c0, uint16 d0, uint16 b0, uint32 l0, bool a0) = v.rules();
        Sanctum.Rules memory cur = Sanctum.Rules(c0, d0, b0, l0, a0);
        vm.prank(hot);
        if (_loosens(r, cur)) {
            vm.expectRevert();
            v.proposeRules(r);
        } else {
            v.proposeRules(r);
            vm.warp(block.timestamp + 3 days);
            vm.prank(hot); v.applyRules();
            (c0, d0, b0, l0, a0) = v.rules();
            assertEq(c0, cap); assertEq(d0, day); assertEq(b0, dbps); assertEq(l0, delay); assertEq(a0, al);
        }
    }

    function test_each_field_reverts_with_its_reason() public {
        Sanctum v = _sanctum();
        Sanctum.Rules memory r;
        r = _defaults(); r.capBps = 501;
        vm.prank(hot); vm.expectRevert(bytes("cap: tighten only")); v.proposeRules(r);
        r = _defaults(); r.dayCapBps = 1001;
        vm.prank(hot); vm.expectRevert(bytes("day cap: tighten only")); v.proposeRules(r);
        r = _defaults(); r.delayBps = 1001;
        vm.prank(hot); vm.expectRevert(bytes("delayBps: tighten only")); v.proposeRules(r);
        r = _defaults(); r.delay = 6 hours - 1;
        vm.prank(hot); vm.expectRevert(bytes("delay: tighten only")); v.proposeRules(r);
        vm.prank(cold); v.coldSetRules(Sanctum.Rules(500, 1000, 1000, 6 hours, true));
        r = _defaults(); r.allowlistOn = false;
        vm.prank(hot); vm.expectRevert(bytes("allowlist: tighten only")); v.proposeRules(r);
        // turning it on is a tightening
        vm.prank(cold); v.coldSetRules(_defaults());
        r = _defaults(); r.allowlistOn = true;
        vm.prank(hot); v.proposeRules(r);
    }

    function test_apply_rechecks_after_cold_tightened() public {
        Sanctum v = _sanctum();
        vm.prank(hot); v.proposeRules(Sanctum.Rules(400, 1000, 1000, 6 hours, false));
        vm.prank(cold); v.coldSetRules(Sanctum.Rules(300, 1000, 1000, 6 hours, false)); // clears pending
        vm.warp(block.timestamp + 3 days);
        vm.prank(hot); vm.expectRevert(bytes("waiting")); v.applyRules();
        vm.prank(hot); vm.expectRevert(bytes("cap: tighten only")); v.proposeRules(Sanctum.Rules(400, 1000, 1000, 6 hours, false));
    }

    // ---- b. no perpetual guardian freeze ---------------------------------------------------------

    function testFuzz_guardian_cannot_extend_freeze_before_last_hour(uint256 dt) public {
        Sanctum v = _sanctum();
        vm.prank(g1); v.panic();
        uint64 until = v.frozenUntil();
        dt = bound(dt, 0, 24 hours);
        vm.warp(block.timestamp + dt);
        vm.prank(g1);
        if (dt < 23 hours) {
            vm.expectRevert(bytes("frozen: last hour only"));
            v.panic();
            assertEq(v.frozenUntil(), until);
        } else {
            v.panic();
            assertEq(v.frozenUntil(), block.timestamp + 24 hours);
        }
    }

    function testFuzz_watcher_cannot_extend_freeze_before_last_hour(uint256 dt) public {
        Sanctum v = _sanctum();
        vm.prank(cold); v.setWatchersOn(true);
        vm.prank(watcher); v.panic();
        uint64 until = v.frozenUntil();
        dt = bound(dt, 0, 24 hours);
        vm.warp(block.timestamp + dt);
        vm.prank(watcher);
        if (dt < 23 hours) {
            vm.expectRevert(bytes("frozen: last hour only"));
            v.panic();
            assertEq(v.frozenUntil(), until);
        } else {
            v.panic();
            assertEq(v.frozenUntil(), block.timestamp + 24 hours);
        }
    }

    function test_owner_and_cold_can_repanic_any_time() public {
        Sanctum v = _sanctum();
        vm.prank(g1); v.panic();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(hot); v.panic();
        assertEq(v.frozenUntil(), block.timestamp + 24 hours);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(cold); v.panic();
        assertEq(v.frozenUntil(), block.timestamp + 24 hours);
    }

    // ---- panic voids queue ---------------------------------------------------------------------

    function testFuzz_panic_voids_queue(uint8 n, uint256 amt) public {
        Sanctum v = _sanctum();
        n = uint8(bound(n, 1, 8));
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            vm.prank(hot); ids[i] = v.withdraw(address(0), hot, bound(amt, 10.01 ether, 100 ether));
            assertTrue(ids[i] != type(uint256).max);
        }
        vm.prank(g1); v.panic();
        vm.prank(cold); v.approveQueued(ids[0]); // even an approval does not revive a voided item
        vm.warp(block.timestamp + 25 hours);
        for (uint256 i; i < n; ++i) {
            vm.prank(hot); vm.expectRevert(bytes("voided by panic")); v.executeQueued(ids[i]);
        }
        assertEq(address(v).balance, 100 ether);
    }

    // ---- c. cold approvals ---------------------------------------------------------------------

    function test_muted_window_items_need_approval() public {
        Sanctum v = _sanctum();
        vm.prank(g1); v.panic();
        vm.prank(cold); v.unfreeze(); // mutes guardians for 24h
        vm.warp(block.timestamp + 1);
        vm.prank(hot); uint256 id = v.withdraw(address(0), hot, 50 ether);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hot); vm.expectRevert(bytes("needs cold approval")); v.executeQueued(id);
        vm.prank(hot); vm.expectRevert(bytes("cold")); v.approveQueued(id);
        vm.prank(g1); vm.expectRevert(bytes("cold")); v.approveQueued(id);
        vm.expectEmit(address(v)); emit Approved(id, cold);
        vm.prank(cold); v.approveQueued(id);
        assertTrue(v.approved(id));
        vm.prank(hot); v.executeQueued(id);
        assertEq(address(v).balance, 50 ether);
        assertEq(hot.balance, 50 ether - _fee(50 ether));
    }

    function test_items_after_mute_window_need_no_approval() public {
        Sanctum v = _sanctum();
        vm.prank(g1); v.panic();
        vm.prank(cold); v.unfreeze();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(hot); uint256 id = v.withdraw(address(0), hot, 50 ether);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hot); v.executeQueued(id);
        assertEq(address(v).balance, 50 ether);
    }

    function test_cannot_approve_done_item() public {
        Sanctum v = _sanctum();
        vm.prank(hot); uint256 id = v.withdraw(address(0), hot, 50 ether);
        vm.prank(cold); v.cancel(id);
        vm.prank(cold); vm.expectRevert(bytes("done")); v.approveQueued(id);
    }

    function test_require_approval_flag_cold_only_default_off() public {
        Sanctum v = _sanctum();
        assertFalse(v.requireApproval());
        vm.prank(hot); vm.expectRevert(bytes("cold")); v.setRequireApproval(true);
        vm.prank(cold); v.setRequireApproval(true);
        assertTrue(v.requireApproval());
    }

    // ---- d. events + registry opt-out ---------------------------------------------------------

    function test_key_and_registry_changes_emit() public {
        Sanctum v = _sanctum();
        address h2 = makeAddr("h2"); address c2 = makeAddr("c2"); address b2 = makeAddr("b2");
        vm.expectEmit(address(v)); emit OwnerSet(hot, h2);
        vm.prank(cold); v.setOwner(h2);
        vm.expectEmit(address(v)); emit BlacklistSet(address(blacklist), b2);
        vm.prank(cold); v.setBlacklist(b2);
        vm.expectEmit(address(v)); emit WatcherRegistrySet(address(registry), address(0));
        vm.prank(cold); v.setWatcherRegistry(address(0));
        vm.expectEmit(address(v)); emit ColdSet(cold, c2);
        vm.prank(cold); v.setCold(c2);
        assertEq(v.cold(), c2);
        vm.prank(cold); vm.expectRevert(bytes("cold")); v.setWatcherRegistry(address(registry));
    }

    function test_setWatcherRegistry_opt_out_and_replace() public {
        Sanctum v = _sanctum();
        vm.prank(cold); v.setWatchersOn(true);
        vm.prank(hot); vm.expectRevert(bytes("cold")); v.setWatcherRegistry(address(0));
        vm.prank(cold); v.setWatcherRegistry(address(0));
        vm.prank(watcher); vm.expectRevert(bytes("standing")); v.panic();
        vm.prank(hot); v.panic(); // owner panic unaffected
        vm.prank(cold); v.setWatcherRegistry(address(registry));
        vm.warp(block.timestamp + 23 hours);
        vm.prank(watcher); v.panic();
    }

    function test_setters_cold_only() public {
        Sanctum v = _sanctum();
        vm.startPrank(hot);
        vm.expectRevert(bytes("cold")); v.setOwner(hot);
        vm.expectRevert(bytes("cold")); v.setCold(hot);
        vm.expectRevert(bytes("cold")); v.setBlacklist(address(0));
        vm.expectRevert(bytes("cold")); v.setWatchersOn(true);
        vm.expectRevert(bytes("cold")); v.setAllowlist(hot, true);
        vm.expectRevert(bytes("cold")); v.coldSetRules(_defaults());
        vm.expectRevert(bytes("cold")); v.unfreeze();
        vm.expectRevert(bytes("cold")); v.coldWithdraw(address(0), hot, 1);
        vm.expectRevert(bytes("cold")); v.setGuardians(_none(), 0);
        vm.stopPrank();
        vm.prank(cold); vm.expectRevert(bytes("cold")); v.setCold(address(0));
        vm.prank(cold); vm.expectRevert(bytes("owner")); v.setOwner(address(0));
    }

    // ---- blacklist + allowlist destinations ------------------------------------------------------

    function test_blacklisted_destination_refused_everywhere() public {
        Sanctum v = _sanctum();
        address bad = makeAddr("bad");
        vm.prank(hot); uint256 id = v.withdraw(address(0), bad, 50 ether);
        vm.prank(deployer); blacklist.flag(bad, true, "drainer");
        vm.prank(hot); vm.expectRevert(bytes("blacklisted")); v.withdraw(address(0), bad, 1 ether);
        vm.prank(cold); vm.expectRevert(bytes("blacklisted")); v.coldWithdraw(address(0), bad, 1 ether);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hot); vm.expectRevert(bytes("blacklisted")); v.executeQueued(id); // flagged after queueing
        assertEq(bad.balance, 0);
    }

    function test_allowlist_gates_destinations() public {
        Sanctum v = _sanctum();
        address ok = makeAddr("ok"); address other = makeAddr("other");
        Sanctum.Rules memory r = _defaults(); r.allowlistOn = true;
        vm.prank(cold); v.coldSetRules(r);
        vm.prank(cold); v.setAllowlist(ok, true);
        vm.prank(hot); vm.expectRevert(bytes("not allowlisted")); v.withdraw(address(0), other, 1 ether);
        vm.prank(hot); v.withdraw(address(0), ok, 1 ether);
        assertEq(ok.balance, 1 ether);
        vm.prank(hot); vm.expectRevert(bytes("to")); v.withdraw(address(0), address(0), 1 ether);
    }
}

/// Invariant handler: a stolen hot key hammering the direct (instant) path, never executing the queue.
contract DirectPathHandler is Fixture {
    Sanctum public v;
    uint256 public constant START = 100 ether;
    mapping(uint64 => uint256) public sentInHour; // ghost: instant outflow per hour bucket
    uint256 public calls;
    uint256 public totalOut;

    constructor(Sanctum _v, address _hot) { v = _v; hot = _hot; }

    function withdraw(uint256 amt, uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 hours));
        uint256 bal = address(v).balance;
        if (bal == 0) return;
        amt = bound(amt, 1, bal / 8 + 1); // mostly cap-sized: exercise the instant path, not just the queue
        uint256 before = bal;
        vm.prank(hot);
        try v.withdraw(address(0), hot, amt) returns (uint256) {} catch {}
        uint256 out = before - address(v).balance;
        sentInHour[uint64(block.timestamp / 1 hours)] += out;
        totalOut += out;
        calls++;
    }

    function rolling() external view returns (uint256 sum) {
        uint64 h = uint64(block.timestamp / 1 hours);
        for (uint64 i; i < 24 && i <= h; ++i) sum += sentInHour[h - i];
    }
}

contract DirectPathInvariant is Fixture {
    DirectPathHandler h;
    Sanctum v;

    function setUp() public {
        _base();
        v = _sanctum();
        h = new DirectPathHandler(v, hot);
        targetContract(address(h));
    }

    /// Instant outflow over any rolling 24h never exceeds dayCapBps (10%) of the balance a day ago
    /// (current balance + what left in that window; there are no deposits and no queue executions here).
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_direct_outflow_within_day_cap() public view {
        uint256 r = h.rolling();
        assertLe(r, (address(v).balance + r) * 1000 / 10_000);
    }

    /// The queue never paid out (executions are never called), so total loss is the instant path only.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_no_queue_execution() public view {
        uint256 n = v.queueLength();
        for (uint256 i; i < n && i < 50; ++i) {
            (,,,, bool done) = v.queue(i);
            assertFalse(done);
        }
    }
}
