// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture, MockERC20} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {BountySanctum} from "../src/BountySanctum.sol";
import {BountyCold} from "../src/BountyCold.sol";

/// STEP 4 redesign ("main vault = break-the-caps bounty"): the public hot key may only send to the bounty
/// Sanctum itself. Probes use the real caps/freeze (room is consumed like a real withdrawal) but every allowed
/// outflow cycles straight back, so the prize never decreases. Above the caps → revert (never queued); frozen →
/// revert; top-ups; sweep; events. No fork needed. (The cold key here is an EOA `admin` to exercise the Sanctum
/// mechanics; production uses BountyCold, see BountyRaidInvariantTest and Audit3BountyColdTest.)
contract BountyTest is Fixture {
    BountySanctum bounty;
    Sanctum s;
    address admin = makeAddr("admin");
    address robber = makeAddr("robber");
    address robber2 = makeAddr("robber2");
    address loot = makeAddr("loot");
    uint256 constant SEED = 0.5 ether;
    uint256 cycled; // independent ledger of what went round trip

    event Attempt(address indexed caller, uint256 amount, uint256 prize);
    event TopUp(address indexed from, uint256 amount, uint256 prize);
    event Swept(address token, address to, uint256 amount);

    function setUp() public {
        _base();
        vm.deal(admin, 10 ether);
        vm.prank(admin);
        bounty = new BountySanctum{value: SEED}(address(factory), admin, _three(), 0);
        s = bounty.sanctum();
        vm.deal(robber, 1 ether);
        vm.deal(robber2, 1 ether);
    }

    // ---- helpers ----------------------------------------------------------------------------

    /// Probe `amount` to the Sanctum; returns true when it went round trip. The prize may never go down; nothing
    /// reaches the caller; nothing is queued.
    function _try(address who, uint256 amount) internal returns (bool ok) {
        uint256 prize0 = bounty.prize();
        uint256 w0 = who.balance;
        uint256 room = s.capRoom(address(0));
        vm.prank(who);
        (ok,) = address(bounty).call(abi.encodeCall(BountySanctum.withdraw, (address(0), address(s), amount)));
        assertEq(bounty.prize(), prize0, "prize unchanged by a probe");
        assertEq(who.balance, w0, "nothing reaches the caller");
        if (ok) {
            cycled += amount;
            assertLe(amount, room, "only inside the room");
            assertEq(bounty.totalCycled(), cycled);
        }
        assertEq(s.queueLength(), 0, "nothing is ever queued");
    }

    function _expectRevert(address who, address to, uint256 amount, string memory reason) internal {
        uint256 prize0 = bounty.prize();
        vm.prank(who);
        vm.expectRevert(bytes(reason));
        bounty.withdraw(address(0), to, amount);
        assertEq(bounty.prize(), prize0);
        assertEq(s.queueLength(), 0, "nothing is ever queued");
    }

    // ---- wiring -----------------------------------------------------------------------------

    function test_wiring() public view {
        assertEq(s.owner(), address(bounty));
        assertEq(s.cold(), admin);
        assertEq(bounty.cold(), admin);
        assertEq(bounty.factory(), address(factory));
        assertTrue(factory.isSanctum(address(s)));
        (uint16 capBps, uint16 dayCapBps, uint16 delayBps, uint32 delay, bool allow) = s.rules();
        assertEq(capBps, 100);
        assertEq(dayCapBps, 200);
        assertEq(delayBps, 10_000);
        assertEq(delay, 24 hours);
        assertFalse(allow);
        assertFalse(s.watchersOn());
        assertEq(s.guardianCount(), 3);
        assertEq(s.threshold(), 2);
        assertEq(bounty.prize(), SEED);
        assertEq(address(bounty).balance, 0);
        assertEq(bounty.probeRoom(), SEED * 100 / 10_000);
        assertEq(bounty.totalCycled(), 0);
        assertEq(bounty.attempts(), 0);
    }

    function test_constructor_checks() public {
        vm.expectRevert(bytes("addr"));
        new BountySanctum(address(0), admin, _none(), 0);
        vm.expectRevert(bytes("addr"));
        new BountySanctum(address(factory), address(0), _none(), 0);
        address[] memory six = new address[](6);
        for (uint256 i; i < 6; ++i) six[i] = address(uint160(i + 1));
        vm.expectRevert(bytes("max 5"));
        new BountySanctum(address(factory), admin, six, 0);
        BountySanctum b = new BountySanctum(address(factory), admin, _none(), 0);
        assertEq(b.sanctum().guardianCount(), 0);
        assertEq(b.prize(), 0);
    }

    // ---- the only destination ---------------------------------------------------------------

    function test_every_destination_but_the_sanctum_is_refused() public {
        uint256 room = s.capRoom(address(0));
        address[8] memory dests = [robber, loot, address(bounty), admin, address(0), address(factory), g1, address(feeRouter)];
        for (uint256 i; i < dests.length; ++i) {
            _expectRevert(robber, dests[i], 1, "to");
            _expectRevert(robber, dests[i], room, "to");
        }
        assertEq(bounty.attempts(), 0);
        assertEq(s.capRoom(address(0)), room, "refused calls burn no room");
        assertTrue(_try(robber, room));
    }

    function testFuzz_any_destination_but_the_sanctum_is_refused(address to, uint256 amount) public {
        vm.assume(to != address(s));
        uint256 prize0 = bounty.prize();
        vm.prank(robber);
        vm.expectRevert(bytes("to"));
        bounty.withdraw(address(0), to, amount);
        assertEq(bounty.prize(), prize0);
    }

    /// At delayBps = 10000 the Sanctum itself STILL queues anything above capRoom (the capRoom branch of
    /// `withdraw`): shown directly on the raw Sanctum by impersonating the hot key. BountySanctum is the guard.
    function test_sanctum_alone_would_queue_above_caps() public {
        uint256 room = s.capRoom(address(0));
        vm.prank(address(bounty));
        uint256 id = s.withdraw(address(0), loot, room + 1);
        assertEq(id, 0, "raw Sanctum queued it");
        assertEq(s.queueLength(), 1);
        (bool ok,) = address(bounty).call(abi.encodeWithSignature("executeQueued(uint256)", 0));
        assertFalse(ok, "and nothing queued can be released through the public key");
    }

    function test_over_cap_reverts_not_queues() public {
        uint256 room = s.capRoom(address(0));
        _expectRevert(robber, address(s), room + 1, "over cap");
        _expectRevert(robber, address(s), SEED, "over cap");
        _expectRevert(robber, address(s), SEED * 1000 / 10_000, "over cap");
        _expectRevert(robber, address(s), type(uint256).max, "over cap");
        _expectRevert(robber, address(s), 0, "amount");
        assertTrue(_try(robber, room)); // exactly the room cycles
        _expectRevert(robber2, address(s), 1, "over cap");
    }

    function test_probe_event_and_counters() public {
        uint256 room = s.capRoom(address(0));
        vm.expectEmit(true, false, false, true, address(bounty));
        emit Attempt(robber, room, SEED);
        vm.prank(robber);
        uint256 c = bounty.withdraw(address(0), address(s), room);
        assertEq(c, room);
        assertEq(bounty.lastAttemptAt(), block.timestamp);
        assertEq(bounty.attempts(), 1);
        assertEq(bounty.totalCycled(), room);
        assertEq(bounty.prize(), SEED);
        assertEq(robber.balance, 1 ether);
    }

    /// A probe answers exactly like a stolen key would: the room is consumed, reopens with the hourly window and
    /// the rolling 24h cap binds. The prize never moves.
    function test_probe_uses_the_real_caps() public {
        uint256 room = s.capRoom(address(0));
        assertTrue(_try(robber, room));
        assertEq(s.capRoom(address(0)), 0, "hourly room consumed");
        assertEq(bounty.probeRoom(), 0);
        vm.warp(block.timestamp + 1 hours);
        uint256 room2 = s.capRoom(address(0));
        assertEq(room2, room, "next hour: same room (the prize did not shrink)");
        assertTrue(_try(robber2, room2));
        vm.warp(block.timestamp + 1 hours);
        // rolling day room = 2% x (balance + 24h outflow) - 24h outflow; the balance does not shrink here, so a
        // sliver (2% of what cycled) is left: 0.02 x 0.51 - 0.01 = 0.0002 ETH
        assertEq(s.capRoom(address(0)), 0.0002 ether, "about 2% of the rolling day used");
        vm.warp(block.timestamp + 22 hours);
        assertGt(s.capRoom(address(0)), 0, "first probe left the 24h window");
    }

    // ---- 48-hour scripted prober: the prize never goes down ---------------------------------------

    function test_48h_hammering_never_lowers_the_prize() public {
        for (uint256 h; h < 48; ++h) {
            for (uint256 i; i < 10; ++i) _try(i % 2 == 0 ? robber : robber2, SEED / 2000);
            uint256 room = s.capRoom(address(0));
            if (room > 0) assertTrue(_try(robber, room));
            _expectRevert(robber, address(s), s.capRoom(address(0)) + 1, "over cap");
            _expectRevert(robber, robber, 1, "to");
            vm.warp(block.timestamp + 1 hours);
        }
        assertEq(bounty.prize(), SEED);
        assertEq(loot.balance, 0);
        assertGt(bounty.totalCycled(), SEED * 3 / 100, "the caps let ~2%/day through, all of it back");
    }

    function testFuzz_random_probes(uint256[16] calldata amounts, uint32[16] calldata gaps, bool[16] calldata who) public {
        for (uint256 i; i < 16; ++i) {
            uint256 room = s.capRoom(address(0));
            uint256 amount = amounts[i] % (room * 3 + 2);
            bool want = amount > 0 && amount <= room;
            assertEq(_try(who[i] ? robber : robber2, amount), want, "cycles iff inside the room");
            vm.warp(block.timestamp + (gaps[i] % 3 hours));
        }
        assertEq(bounty.prize(), SEED);
    }

    // ---- freeze -----------------------------------------------------------------------------

    function test_guardian_panic_stops_probes_for_24h() public {
        _try(robber, s.capRoom(address(0)));
        vm.prank(g2);
        s.panic();
        assertEq(bounty.probeRoom(), 0);
        for (uint256 h; h < 23; ++h) {
            _expectRevert(robber, address(s), 1, "frozen");
            vm.warp(block.timestamp + 1 hours);
        }
        vm.warp(s.frozenUntil());
        assertTrue(_try(robber, s.capRoom(address(0))), "probing resumes after 24h");
    }

    function test_robber_cannot_panic_or_change_rules_through_the_key() public {
        (bool ok,) = address(bounty).call(abi.encodeWithSignature("panic()"));
        assertFalse(ok);
        (ok,) = address(bounty).call(abi.encodeWithSignature("cancel(uint256)", 0));
        assertFalse(ok);
        (ok,) = address(bounty).call(abi.encodeWithSignature("proposeRules((uint16,uint16,uint16,uint32,bool))", Sanctum.Rules(0, 0, 0, 0, false)));
        assertFalse(ok);
        vm.prank(robber);
        vm.expectRevert(bytes("standing"));
        s.panic();
        vm.prank(robber);
        vm.expectRevert(bytes("owner"));
        s.withdraw(address(0), robber, 1);
    }

    function test_cold_unfreeze_resumes_and_mutes_guardians() public {
        vm.prank(g1);
        s.panic();
        _expectRevert(robber, address(s), 1, "frozen");
        vm.prank(admin);
        s.unfreeze();
        assertTrue(_try(robber, s.capRoom(address(0))));
        vm.prank(g1);
        vm.expectRevert(bytes("muted"));
        s.panic();
    }

    function test_cold_can_tighten_the_game() public {
        vm.prank(admin);
        s.coldSetRules(Sanctum.Rules(50, 100, 10_000, 24 hours, false));
        assertEq(bounty.probeRoom(), SEED * 50 / 10_000);
        assertTrue(_try(robber, s.capRoom(address(0))));
        _expectRevert(robber, address(s), 1, "over cap");
    }

    // ---- top-up / sweep ---------------------------------------------------------------------

    function test_topUp_increases_prize_and_emits() public {
        vm.deal(address(this), 2 ether);
        vm.expectEmit(true, false, false, true, address(bounty));
        emit TopUp(address(this), 1 ether, SEED + 1 ether);
        bounty.topUp{value: 1 ether}();
        assertEq(bounty.prize(), SEED + 1 ether);
        assertEq(address(bounty).balance, 0);
        (bool ok,) = address(bounty).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(bounty.prize(), SEED + 1.5 ether);
        vm.expectRevert(bytes("value"));
        bounty.topUp();
    }

    function test_feeRouter_style_push_to_sanctum_directly() public {
        vm.deal(address(feeRouter), 1 ether);
        vm.prank(address(feeRouter));
        (bool ok,) = address(s).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(bounty.prize(), SEED + 1 ether);
    }

    function test_sweep_erc20_to_cold() public {
        token.mint(address(bounty), 5e18);
        vm.expectEmit(false, false, false, true, address(bounty));
        emit Swept(address(token), admin, 5e18);
        bounty.sweep(address(token));
        assertEq(token.balanceOf(admin), 5e18);
    }

    /// AUDIT-3 L2: ETH only. ERC-20s that land in the Sanctum stay there.
    function test_erc20_probes_rejected_eth_only() public {
        token.mint(address(s), 100e18);
        vm.prank(robber);
        vm.expectRevert(bytes("eth only"));
        bounty.withdraw(address(token), address(s), 1e18);
        assertEq(bounty.attempts(), 0);
        assertEq(token.balanceOf(address(s)), 100e18);
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Invariant: under random calls by any actor (raiders, guardians, BountyCold's owner, strangers, the Safe), on every
// public entry point of BountySanctum, BountyCold and the Sanctum itself, the bounty Sanctum's ETH balance NEVER
// decreases. There is no legitimate exit, so there is no exception to model.
// ---------------------------------------------------------------------------------------------------------------

contract BountyRaidHandler is Fixture {
    BountyCold public bc;
    BountySanctum public b;
    Sanctum public s;
    address[] public actors;
    uint256 public ghostIn;
    uint256 public lastPrize;
    bool public decreased;     // set if the prize was ever lower than after the previous action
    bool public leaked;        // set if any actor ever received ETH from the game
    uint256 public probes;

    constructor(BountyCold _bc, address dev) {
        bc = _bc; b = _bc.bounty(); s = _bc.sanctum();
        token = new MockERC20();
        actors.push(dev); actors.push(makeAddr("r.stranger")); actors.push(makeAddr("r.robber"));
        actors.push(makeAddr("g1")); actors.push(makeAddr("g2")); actors.push(makeAddr("g3"));
        actors.push(makeAddr("r.safe"));
        lastPrize = b.prize();
    }

    function _who(uint256 i) internal view returns (address) { return actors[i % actors.length]; }

    /// Runs after every action: the prize is monotone, every actor's ETH balance is unchanged.
    function _after(address a, uint256 bal0) internal {
        uint256 p = b.prize();
        if (p < lastPrize) decreased = true;
        lastPrize = p;
        if (a.balance > bal0) leaked = true;
    }

    function warp(uint256 dt) external { vm.warp(block.timestamp + bound(dt, 0, 3 days)); }

    function probe(uint256 w, uint256 amt, uint256 toSel) external {
        address a = _who(w);
        uint256 bal0 = a.balance;
        address[4] memory dests = [address(s), a, address(b), address(bc)];
        address to = dests[toSel % 4];
        uint256 room = b.probeRoom();
        amt = bound(amt, 0, room * 2 + 1);
        vm.prank(a);
        try b.withdraw(address(0), to, amt) { probes++; } catch {}
        _after(a, bal0);
    }

    function probeToken(uint256 w, uint256 amt) external {
        address a = _who(w);
        uint256 bal0 = a.balance;
        vm.prank(a);
        try b.withdraw(address(token), address(s), amt) { revert("token probe passed"); } catch {}
        _after(a, bal0);
    }

    function topUp(uint256 amt, bool direct) external {
        amt = bound(amt, 1, 3 ether);
        vm.deal(address(this), amt);
        if (direct) { (bool ok,) = address(s).call{value: amt}(""); require(ok); }
        else b.topUp{value: amt}();
        ghostIn += amt;
        _after(address(this), 0);
    }

    function coldPowers(uint256 w, uint256 which) external {
        address a = _who(w);
        uint256 bal0 = a.balance;
        vm.startPrank(a);
        uint256 k = which % 6;
        if (k == 0) try bc.panic() {} catch {}
        else if (k == 1) try bc.unfreeze() {} catch {}
        else if (k == 2) { address[] memory g = new address[](1); g[0] = _who(which >> 8); try bc.setGuardians(g, 0) {} catch {} }
        else if (k == 3) try bc.transferOwnership(_who(which >> 8)) {} catch {}
        else if (k == 4) try bc.acceptOwnership() {} catch {}
        else try s.panic() {} catch {}
        vm.stopPrank();
        _after(a, bal0);
    }

    /// Every fund-moving or loosening Sanctum entry point, by every actor, directly on the Sanctum.
    function sanctumDirect(uint256 w, uint256 which, uint256 amt) external {
        address a = _who(w);
        uint256 bal0 = a.balance;
        amt = bound(amt, 1, 10 ether);
        vm.startPrank(a);
        uint256 k = which % 12;
        bool ok;
        if (k == 0) (ok,) = address(s).call(abi.encodeCall(Sanctum.coldWithdraw, (address(0), a, amt)));
        else if (k == 1) (ok,) = address(s).call(abi.encodeCall(Sanctum.withdraw, (address(0), a, amt)));
        else if (k == 2) (ok,) = address(s).call(abi.encodeCall(Sanctum.executeQueued, (0)));
        else if (k == 3) (ok,) = address(s).call(abi.encodeCall(Sanctum.coldSetRules, (Sanctum.Rules(10_000, 10_000, 10_000, 0, false))));
        else if (k == 4) (ok,) = address(s).call(abi.encodeCall(Sanctum.setOwner, (a)));
        else if (k == 5) (ok,) = address(s).call(abi.encodeCall(Sanctum.setCold, (a)));
        else if (k == 6) (ok,) = address(s).call(abi.encodeCall(Sanctum.proposeCold, (a)));
        else if (k == 7) (ok,) = address(s).call(abi.encodeCall(Sanctum.executeRecovery, ()));
        else if (k == 8) (ok,) = address(s).call(abi.encodeCall(Sanctum.setRecoveryOff, (false)));
        else if (k == 9) (ok,) = address(s).call(abi.encodeCall(Sanctum.proposeRules, (Sanctum.Rules(10_000, 10_000, 10_000, 0, false))));
        else if (k == 10) (ok,) = address(s).call(abi.encodeCall(Sanctum.applyRules, ()));
        else (ok,) = address(s).call(abi.encodeCall(Sanctum.cancel, (0)));
        vm.stopPrank();
        if (ok && k != 6) revert("a privileged Sanctum call succeeded"); // proposeCold is "recovery off" anyway
        _after(a, bal0);
    }

    function sweep(uint256 amt) external {
        token.mint(address(b), bound(amt, 1, 1e24));
        b.sweep(address(token));
        _after(address(this), 0);
    }
}

contract BountyRaidInvariantTest is Fixture {
    BountyCold bc;
    BountyRaidHandler h;
    address dev = makeAddr("r.dev");
    uint256 constant SEED = 0.5 ether;

    function setUp() public {
        _base();
        vm.deal(dev, 10 ether);
        vm.prank(dev);
        bc = new BountyCold{value: SEED}(dev, address(factory), _three(), 0);
        h = new BountyRaidHandler(bc, dev);
        targetContract(address(h));
    }

    function invariant_STEP4_bounty_balance_never_decreases() public view {
        assertFalse(h.decreased(), "the bounty Sanctum's ETH went down");
        assertGe(h.b().prize(), SEED);
    }

    function invariant_STEP4_prize_is_seed_plus_topups_exactly() public view {
        assertEq(h.b().prize(), SEED + h.ghostIn(), "nothing ever left");
        assertFalse(h.leaked(), "no actor ever received ETH from the game");
        assertEq(h.s().queueLength(), 0);
        assertEq(address(h.b()).balance, 0);
        assertEq(address(bc).balance, 0);
    }

    function invariant_STEP4_keys_and_rules_fixed() public view {
        Sanctum s = h.s();
        assertEq(s.owner(), address(h.b()));
        assertEq(s.cold(), address(bc));
        assertTrue(s.recoveryOff());
        (uint16 cap, uint16 day, uint16 dbps,,) = s.rules();
        assertEq(cap, 100); assertEq(day, 200); assertEq(dbps, 10_000);
    }
}
