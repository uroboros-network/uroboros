// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";

/// Rolling 24h cap + factory defaults + capRoom.
contract CapsTest is Fixture {
    address to = makeAddr("to");

    function setUp() public { _base(); }

    function test_factory_defaults() public {
        Sanctum v = _sanctum();
        (uint16 capBps, uint16 dayCapBps, uint16 delayBps, uint32 delay, bool allowlistOn) = v.rules();
        assertEq(capBps, 500);
        assertEq(dayCapBps, 1000);
        assertEq(delayBps, 1000);
        assertEq(delay, 6 hours);
        assertFalse(allowlistOn);
        assertEq(v.owner(), hot);
        assertEq(v.cold(), cold);
        assertEq(v.feeRouter(), address(feeRouter));
        assertEq(address(v.blacklist()), address(blacklist));
        assertEq(address(v.watchers()), address(registry));
        assertFalse(v.watchersOn());
        assertEq(factory.count(), 1);
        assertEq(factory.sanctums(0), address(v));
        assertEq(factory.sanctumsOf(hot, 0), address(v));
        assertTrue(factory.isSanctum(address(v)));
    }

    function test_factory_createWithRules_and_rejects_bad_rules() public {
        Sanctum.Rules memory r = Sanctum.Rules(200, 500, 500, 12 hours, true);
        vm.prank(hot); Sanctum v = Sanctum(payable(factory.createWithRules(cold, _none(), 0, r)));
        (uint16 c, uint16 d, uint16 b, uint32 l, bool a) = v.rules();
        assertEq(c, 200); assertEq(d, 500); assertEq(b, 500); assertEq(l, 12 hours); assertTrue(a);
        r.capBps = 10_001;
        vm.prank(hot); vm.expectRevert(bytes("bps")); factory.createWithRules(cold, _none(), 0, r);
        vm.prank(hot); vm.expectRevert(bytes("keys")); factory.create(address(0), _none(), 0);
    }

    function test_daily_cap_5_then_5_then_blocked_then_resets() public {
        Sanctum v = _sanctum();
        // hour 1: 5% of 100
        vm.prank(hot); v.withdraw(address(0), to, 5 ether);
        _assertQueued(v, hot, to, 0.01 ether); // over the hourly cap: queued, not paid
        // hour 2: another 5% (of 95 = 4.75) is fine; day total 9.75 of 10
        vm.warp(block.timestamp + 1 hours);
        vm.prank(hot); v.withdraw(address(0), to, 4.75 ether);
        // hour 3: hourly window has room (5% of 90.25) but the 10%/day cap (10 of day-start 100) blocks
        vm.warp(block.timestamp + 1 hours);
        _assertQueued(v, hot, to, 1 ether);
        vm.prank(hot); v.withdraw(address(0), to, 0.25 ether); // exactly what is left of the 10%
        _assertQueued(v, hot, to, 1);
        // cold key is bound by the daily cap too
        vm.prank(cold); vm.expectRevert(bytes("daily cap")); v.coldWithdraw(address(0), to, 1 ether);
        assertEq(to.balance, 10 ether);
        // the hour-1 outflow ages out once its bucket is 25 hours old (it stays counted for at least a full 24h;
        // step 3 widened the ring from 24 to 25 buckets): until then still blocked, then 5% of 90 allowed
        vm.warp(t0 + 24 hours);
        _assertQueued(v, hot, to, 1 ether);
        vm.warp(t0 + 25 hours - 1);
        _assertQueued(v, hot, to, 1 ether);
        vm.warp(t0 + 25 hours);
        vm.prank(hot); v.withdraw(address(0), to, 4.5 ether);
        assertEq(to.balance, 14.5 ether);
    }

    function test_hot_key_cannot_raise_day_cap_cold_can() public {
        Sanctum v = _sanctum();
        Sanctum.Rules memory r = _defaults();
        r.dayCapBps = 1001;
        vm.prank(hot); vm.expectRevert(bytes("day cap: tighten only")); v.proposeRules(r);
        r.dayCapBps = 10_000;
        vm.prank(hot); vm.expectRevert(bytes("day cap: tighten only")); v.proposeRules(r);
        r.dayCapBps = 800;
        vm.prank(hot); v.proposeRules(r);
        vm.warp(block.timestamp + 3 days);
        vm.prank(hot); v.applyRules();
        (, uint16 d,,,) = v.rules();
        assertEq(d, 800);
        r.dayCapBps = 10_000;
        vm.prank(cold); v.coldSetRules(r);
        (, d,,,) = v.rules();
        assertEq(d, 10_000);
        r.dayCapBps = 10_001;
        vm.prank(cold); vm.expectRevert(bytes("bps")); v.coldSetRules(r);
    }

    function test_hot_key_raised_cap_still_bound_by_day_cap() public {
        Sanctum v = _sanctum();
        Sanctum.Rules memory r = _defaults();
        r.capBps = 10_000; r.delayBps = 10_000;
        vm.prank(hot); vm.expectRevert(bytes("cap: tighten only")); v.proposeRules(r);
        vm.prank(cold); v.coldSetRules(r);
        _assertQueued(v, hot, to, 50 ether); // over the daily cap: waits out the 6h delay instead
        vm.prank(hot); v.withdraw(address(0), to, 10 ether);
        assertEq(address(v).balance, 90 ether);
    }

    /// Queue release skips both caps; the only thing taken off is the 0.25% fee.
    function test_queued_transfer_full_after_6h_skips_both_caps() public {
        Sanctum v = _sanctum();
        vm.prank(hot); v.withdraw(address(0), to, 5 ether);      // use the hourly cap
        vm.prank(hot); uint256 id = v.withdraw(address(0), to, 95 ether); // > 10%: queued
        assertEq(id, 0);
        vm.warp(block.timestamp + 6 hours - 1);
        vm.prank(hot); vm.expectRevert(bytes("waiting")); v.executeQueued(id);
        vm.warp(block.timestamp + 1);
        vm.prank(hot); v.executeQueued(id);
        assertEq(to.balance, 100 ether - _fee(95 ether));
        assertEq(feeRouter.received(), _fee(95 ether));
        assertEq(address(v).balance, 0);
    }

    function test_queued_transfer_still_voided_by_panic() public {
        Sanctum v = _sanctum();
        vm.prank(hot); uint256 id = v.withdraw(address(0), to, 100 ether);
        vm.prank(hot); v.panic();
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(hot); vm.expectRevert(bytes("voided by panic")); v.executeQueued(id);
    }

    function test_executeQueued_requires_balance_and_single_use() public {
        Sanctum v = _sanctum();
        vm.prank(hot); uint256 id = v.withdraw(address(0), to, 100 ether);
        vm.prank(cold); v.coldWithdraw(address(0), cold, 5 ether); // balance now 95
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hot); vm.expectRevert(bytes("balance")); v.executeQueued(id);
        vm.deal(address(v), 100 ether);
        vm.prank(cold); v.executeQueued(id); // cold may release too
        vm.prank(hot); vm.expectRevert(bytes("done")); v.executeQueued(id);
        vm.prank(hot); vm.expectRevert(bytes("done")); v.cancel(id);
        vm.prank(makeAddr("x")); vm.expectRevert(bytes("owner/cold")); v.executeQueued(id);
    }

    /// withdraw() must queue `amount` (not revert, not pay): returns a real id, recipient unchanged.
    function _assertQueued(Sanctum v, address from, address dest, uint256 amount) internal returns (uint256 id) {
        uint256 before = dest.balance;
        uint256 len = v.queueLength();
        vm.prank(from); id = v.withdraw(address(0), dest, amount);
        assertTrue(id != type(uint256).max, "not queued");
        assertEq(id, len);
        assertEq(dest.balance, before, "paid immediately");
        (address qt, address qto, uint256 qamt,, bool done) = v.queue(id);
        assertEq(qt, address(0)); assertEq(qto, dest); assertEq(qamt, amount); assertFalse(done);
    }

    function _assertImmediate(Sanctum v, address from, address dest, uint256 amount) internal {
        uint256 before = dest.balance;
        uint256 len = v.queueLength();
        vm.prank(from); uint256 id = v.withdraw(address(0), dest, amount);
        assertEq(id, type(uint256).max, "queued");
        assertEq(v.queueLength(), len);
        assertEq(dest.balance, before + amount);
    }

    /// 7% is above the 5%/h cap but below the 10% queue threshold: queued (no dead end), paid after 6h less fee.
    function test_owner_7pct_over_hourly_cap_queued_then_full_after_6h() public {
        Sanctum v = _sanctum();
        assertEq(v.capRoom(address(0)), 5 ether);
        uint256 id = _assertQueued(v, hot, to, 7 ether);
        vm.warp(block.timestamp + 6 hours - 1);
        vm.prank(hot); vm.expectRevert(bytes("waiting")); v.executeQueued(id);
        vm.warp(block.timestamp + 1);
        vm.prank(hot); v.executeQueued(id);
        assertEq(to.balance, 7 ether - _fee(7 ether));
        assertEq(address(v).balance, 93 ether);
    }

    /// Exactly capRoom goes out now, capRoom+1 is queued — under the hourly cap, after an hourly reset,
    /// when the rolling daily cap binds, and once a spend ages out of the rolling-day ring.
    function test_capRoom_matches_withdraw_at_boundaries() public {
        Sanctum v = _sanctum();
        uint256 room = v.capRoom(address(0));
        assertEq(room, 5 ether);
        _assertQueued(v, hot, to, room + 1);
        _assertImmediate(v, hot, to, room);
        assertEq(v.capRoom(address(0)), 0);
        _assertQueued(v, hot, to, 1);
        vm.warp(block.timestamp + 1 hours - 1);
        assertEq(v.capRoom(address(0)), 0);
        _assertQueued(v, hot, to, 1);
        vm.warp(block.timestamp + 1);
        room = v.capRoom(address(0));
        assertEq(room, 4.75 ether);
        _assertQueued(v, hot, to, room + 1);
        _assertImmediate(v, hot, to, room);
        vm.warp(block.timestamp + 1 hours);
        room = v.capRoom(address(0));
        assertEq(room, 0.25 ether);
        _assertQueued(v, hot, to, room + 1);
        _assertImmediate(v, hot, to, room);
        _assertQueued(v, hot, to, 1);
        vm.warp(t0 + 25 hours - 1); // the t0 outflow is counted for 25 bucket-hours (≥ 24 wall-clock hours)
        assertEq(v.capRoom(address(0)), 0);
        _assertQueued(v, hot, to, 1);
        vm.warp(t0 + 25 hours);
        room = v.capRoom(address(0));
        assertGt(room, 0);
        _assertQueued(v, hot, to, room + 1);
        _assertImmediate(v, hot, to, room);
        assertEq(v.capRoom(address(0)), 0);
        assertEq(to.balance, 10 ether + room);
    }

    /// Random amounts at random times: whenever capRoom says it fits, withdraw pays now (never reverts on a
    /// cap); whenever it does not, withdraw queues.
    function testFuzz_capRoom_never_lies(uint256 seed) public {
        Sanctum v = _sanctum();
        for (uint256 i; i < 40; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + (seed % 3 hours));
            uint256 bal = address(v).balance;
            if (bal == 0) break;
            uint256 room = v.capRoom(address(0));
            uint256 amt = (seed >> 32) % 4 == 0 ? room : ((seed >> 64) % (bal / 10 + 1)); // below the 10% queue line
            if (amt * 10_000 > bal * 1000) continue;
            if (amt <= room) _assertImmediate(v, hot, to, amt);
            else _assertQueued(v, hot, to, amt);
        }
    }

    /// A hot-key withdrawal queued only because it is over the cap is still voided by a guardian panic.
    function test_hot_key_over_cap_queue_voided_by_panic() public {
        Sanctum v = _sanctum();
        address thief = makeAddr("thief");
        _assertImmediate(v, hot, thief, 5 ether);              // the hourly cap
        uint256 id = _assertQueued(v, hot, thief, 4 ether);    // < 10% but over the cap
        vm.prank(g1); v.panic();
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(hot); vm.expectRevert(bytes("voided by panic")); v.executeQueued(id);
        vm.prank(cold); vm.expectRevert(bytes("voided by panic")); v.executeQueued(id);
        assertEq(thief.balance, 5 ether);
        assertEq(address(v).balance, 95 ether);
    }

    /// Fixed 24h windows let a thief take ~20% across a window boundary. Rolling buckets must not.
    function test_rolling_day_cap_no_boundary_double_dip() public {
        Sanctum v = _sanctum();
        vm.prank(hot); v.withdraw(address(0), to, 1); // opens the (old) day window at t0
        vm.warp(block.timestamp + 22 hours);
        vm.prank(hot); v.withdraw(address(0), to, 4.99 ether);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(hot); v.withdraw(address(0), to, 4.75 ether);
        vm.warp(block.timestamp + 1 hours); // t0+24h: a fixed window would reset here
        _assertQueued(v, hot, to, 1 ether);
        vm.warp(block.timestamp + 1 hours);
        _assertQueued(v, hot, to, 1 ether);
        vm.warp(block.timestamp + 21 hours);
        vm.prank(hot); v.withdraw(address(0), to, 4 ether);
        assertLe(100 ether - address(v).balance, 13.74 ether + 1);
    }

    /// A hot key could set delay 0 + delayBps 0 after 3 days: every withdraw queues and executes at once,
    /// skipping both caps. Shortening the delay is cold-key only.
    function test_hot_key_cannot_shorten_delay() public {
        Sanctum v = _sanctum();
        Sanctum.Rules memory r = _defaults();
        r.delay = 0; r.delayBps = 0;
        vm.prank(hot); vm.expectRevert(bytes("delay: tighten only")); v.proposeRules(r);
        r.delay = 6 hours - 1;
        vm.prank(hot); vm.expectRevert(bytes("delay: tighten only")); v.proposeRules(r);
        r.delay = 12 hours; // lengthening is fine
        vm.prank(hot); v.proposeRules(r);
        vm.prank(cold); r.delay = 0; v.coldSetRules(r);
        (,,, uint32 d,) = v.rules();
        assertEq(d, 0);
    }

    // ---- ERC-20 path: caps are per asset ----------------------------------------------------------

    function test_erc20_caps_independent_of_eth() public {
        Sanctum v = _sanctum();
        token.mint(hot, 1000e18);
        vm.startPrank(hot);
        token.approve(address(v), 1000e18);
        v.deposit(address(token), 1000e18);
        assertEq(v.balanceOf(address(token)), 1000e18);
        assertEq(v.capRoom(address(token)), 50e18);
        uint256 id = v.withdraw(address(token), to, 50e18);
        assertEq(id, type(uint256).max);
        assertEq(token.balanceOf(to), 50e18);
        id = v.withdraw(address(token), to, 1); // token hourly cap used
        assertTrue(id != type(uint256).max);
        id = v.withdraw(address(0), to, 5 ether);  // ETH untouched
        assertEq(id, type(uint256).max);
        vm.stopPrank();
    }
}
