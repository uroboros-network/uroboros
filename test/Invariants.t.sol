// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture, MockERC20} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";

/// Handler 1: hot and cold keys hammer the DIRECT paths on two assets (ETH + ERC-20), with random deposits.
/// Nothing ever executes the queue, so every wei that leaves went through `_spendWindow`.
contract CapsHandler is Fixture {
    Sanctum public v;
    address[2] public assets;
    mapping(address => mapping(uint64 => uint256)) public sentInHour;   // ghost: direct outflow per asset per hour
    mapping(address => uint64) public hourStart;                         // ghost: when the fixed hourly window opened
    mapping(address => uint256) public hourBal;                          // ghost: balance at that moment
    mapping(address => uint256) public hourOut;                          // ghost: outflow in that window
    uint256 public calls;

    constructor(Sanctum _v, address _hot, address _cold, address _token) {
        v = _v; hot = _hot; cold = _cold; assets[0] = address(0); assets[1] = _token; token = MockERC20(_token);
    }

    function _asset(uint256 i) internal view returns (address) { return assets[i % 2]; }

    function _track(address a, uint256 before) internal {
        uint256 out = before - v.balanceOf(a);
        if (out == 0) return;
        sentInHour[a][uint64(block.timestamp / 1 hours)] += out;
        if (block.timestamp >= hourStart[a] + 1 hours) { hourStart[a] = uint64(block.timestamp); hourBal[a] = before; hourOut[a] = 0; }
        hourOut[a] += out;
    }

    function warp(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 0, 4 hours)); }

    function hotWithdraw(uint256 which, uint256 amt) external {
        address a = _asset(which);
        uint256 bal = v.balanceOf(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal / 8 + 1);
        vm.prank(hot);
        try v.withdraw(a, hot, amt) returns (uint256) {} catch {}
        _track(a, bal);
        calls++;
    }

    function coldWithdraw(uint256 which, uint256 amt) external {
        address a = _asset(which);
        uint256 bal = v.balanceOf(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal / 8 + 1);
        vm.prank(cold);
        try v.coldWithdraw(a, cold, amt) {} catch {}
        _track(a, bal);
        calls++;
    }

    function depositAsset(uint256 which, uint256 amt) external {
        address a = _asset(which);
        amt = bound(amt, 0, 20 ether);
        if (a == address(0)) vm.deal(address(v), address(v).balance + amt);
        else token.mint(address(v), amt);
    }

    function rolling(address a) external view returns (uint256 sum) {
        uint64 h = uint64(block.timestamp / 1 hours);
        for (uint64 i; i < 24 && i <= h; ++i) sum += sentInHour[a][h - i];
    }
}

contract CapsInvariant is Fixture {
    CapsHandler h;
    Sanctum v;

    function setUp() public {
        _base();
        v = _sanctum();
        token.mint(address(v), 100_000e18);
        h = new CapsHandler(v, hot, cold, address(token));
        targetContract(address(h));
    }

    /// Per asset: direct outflow over any rolling 24h never exceeds dayCapBps (10%) of balance-a-day-ago.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_direct_outflow_within_day_cap_per_asset() public view {
        for (uint256 i; i < 2; ++i) {
            address a = h.assets(i);
            uint256 r = h.rolling(a);
            assertLe(r, (v.balanceOf(a) + r) * 1000 / 10_000, "day cap");
        }
    }

    /// Per asset: inside the live fixed hourly window, direct outflow never exceeds capBps (5%) of the balance
    /// at the window's start.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_direct_outflow_within_hour_cap_per_asset() public view {
        for (uint256 i; i < 2; ++i) {
            address a = h.assets(i);
            if (block.timestamp >= h.hourStart(a) + 1 hours) continue; // window closed: nothing live to bound
            assertLe(h.hourOut(a), h.hourBal(a) * 500 / 10_000, "hour cap");
        }
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_queue_never_executed() public view {
        uint256 n = v.queueLength();
        for (uint256 i; i < n && i < 60; ++i) {
            (,,,, bool done) = v.queue(i);
            assertFalse(done);
        }
    }
}

/// Handler 2: everything may happen (withdraws, queue releases, cold withdraws, guardian or owner panics, cold
/// unfreezes). Ghost: total outflow observed while `frozenUntil` was in the future.
contract FreezeHandler is Fixture {
    Sanctum public v;
    uint256 public outflowWhileFrozen;
    uint256 public frozenAttempts;
    uint256 public releases;
    uint256 public voidedReleases; // ghost: releases of items queued at or before the last panic

    constructor(Sanctum _v, address _hot, address _cold, address _g, address _token) {
        v = _v; hot = _hot; cold = _cold; g1 = _g; token = MockERC20(_token);
    }

    function _frozen() internal view returns (bool) { return block.timestamp < v.frozenUntil(); }

    function _measure(bool wasFrozen, uint256 e0, uint256 t0_) internal {
        uint256 out = (e0 - address(v).balance) + (t0_ - token.balanceOf(address(v)));
        if (wasFrozen) { frozenAttempts++; outflowWhileFrozen += out; }
    }

    function warp(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 0, 8 hours)); }

    function withdraw(uint256 which, uint256 amt, bool asCold) external {
        address a = which % 2 == 0 ? address(0) : address(token);
        uint256 bal = v.balanceOf(a);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);
        bool f = _frozen();
        (uint256 e0, uint256 t0_) = (address(v).balance, token.balanceOf(address(v)));
        if (asCold) { vm.prank(cold); try v.coldWithdraw(a, cold, amt) {} catch {} }
        else { vm.prank(hot); try v.withdraw(a, hot, amt) returns (uint256) {} catch {} }
        _measure(f, e0, t0_);
    }

    function execute(uint256 id) external {
        uint256 n = v.queueLength();
        if (n == 0) return;
        id = bound(id, 0, n - 1);
        bool f = _frozen();
        bool voided = v.queuedAt(id) <= v.lastPanicAt();
        (uint256 e0, uint256 t0_) = (address(v).balance, token.balanceOf(address(v)));
        vm.prank(hot);
        try v.executeQueued(id) { releases++; if (voided) voidedReleases++; } catch {}
        _measure(f, e0, t0_);
    }

    function panic(uint256 who) external {
        if ((who >> 8) % 4 != 0) return; // throttled so the queue gets to release sometimes
        address p = who % 3 == 0 ? hot : who % 3 == 1 ? cold : g1;
        vm.prank(p);
        try v.panic() {} catch {}
    }

    function unfreeze() external { vm.prank(cold); v.unfreeze(); }
    function approve(uint256 id) external {
        uint256 n = v.queueLength();
        if (n == 0) return;
        vm.prank(cold); try v.approveQueued(bound(id, 0, n - 1)) {} catch {}
    }
}

contract FreezeInvariant is Fixture {
    FreezeHandler h;
    Sanctum v;

    function setUp() public {
        _base();
        v = _sanctum();
        token.mint(address(v), 100_000e18);
        h = new FreezeHandler(v, hot, cold, g1, address(token));
        targetContract(address(h));
    }

    /// Frozen ⇒ zero outflow on every path (direct, cold, queue release), on every asset.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_frozen_means_zero_outflow() public view {
        assertEq(h.outflowWhileFrozen(), 0);
    }

    /// Queue items created at or before the last panic are never released.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_voided_items_never_released() public view {
        assertEq(h.voidedReleases(), 0);
    }
}

/// Handler 3: guardians vote for random candidates, the cold key cancels or rotates at random, anyone executes.
contract RecoveryHandler is Fixture {
    Sanctum public v;
    address[3] public gs;
    address[2] public candidates;
    uint256 public startedAt;        // ghost: when the current active recovery started (0 if none)
    uint256 public executions;
    uint256 public lastExecutedAt;
    uint256 public lastStartedAt;    // ghost: start time of the recovery that last executed

    constructor(Sanctum _v, address _cold, address[3] memory _gs) {
        v = _v; cold = _cold; gs = _gs;
        candidates[0] = makeAddr("candA"); candidates[1] = makeAddr("candB");
    }

    function warp(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 0, 3 days)); }

    function vote(uint256 g, uint256 c) external {
        bool active = v.recoveryReadyAt() != 0;
        vm.prank(gs[g % 3]);
        try v.proposeCold(candidates[c % 2]) {} catch {}
        if (!active && v.recoveryReadyAt() != 0) startedAt = block.timestamp;
    }

    function cancel() external {
        vm.prank(cold);
        try v.cancelRecovery() { startedAt = 0; } catch {}
    }

    function execute() external {
        try v.executeRecovery() {
            executions++; lastExecutedAt = block.timestamp; lastStartedAt = startedAt; startedAt = 0;
            cold = v.cold(); // the new cold key takes over the cancel role in this handler
        } catch {}
    }
}

contract RecoveryInvariant is Fixture {
    RecoveryHandler h;
    Sanctum v;

    function setUp() public {
        _base();
        v = _sanctumWith(_three(), 0);
        h = new RecoveryHandler(v, cold, [g1, g2, g3]);
        targetContract(address(h));
    }

    /// A recovery that executed did so no earlier than 7 days after its threshold vote.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_recovery_never_completes_early() public view {
        if (h.executions() > 0) assertGe(h.lastExecutedAt(), h.lastStartedAt() + 7 days);
    }

    /// An active recovery always has readyAt = start + 7 days; the cold key is one of the known keys.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 80
    function invariant_recovery_timer_shape() public view {
        if (v.recoveryReadyAt() != 0) {
            assertEq(v.recoveryReadyAt(), h.startedAt() + 7 days);
            assertTrue(v.proposedCold() != address(0));
        } else {
            assertEq(v.proposedCold(), address(0));
        }
        address c = v.cold();
        assertTrue(c == cold || c == h.candidates(0) || c == h.candidates(1));
    }
}
