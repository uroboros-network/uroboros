// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// EVM review PoCs (MEV / ordering / challenge base).
// The challenge-base PoCs use a MOCK level defined here; nothing in this file touches or hints at the real levels.

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Blacklist} from "../src/Blacklist.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {Subscription} from "../src/Subscription.sol";
import {SanctumFactory} from "../src/SanctumFactory.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {Sanctum7702} from "../src/Sanctum7702.sol";
import {BountyCold} from "../src/BountyCold.sol";
import {BountySanctum} from "../src/BountySanctum.sol";
import {Challenge} from "../src/challenges/Challenge.sol";
import {ChallengeRegistry} from "../src/challenges/ChallengeRegistry.sol";

contract RvToken is ERC20 {
    constructor() ERC20("Rv", "RV") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

contract RvFeed {
    int256 public answer = 2285e8;
    uint256 public updatedAt;
    constructor() { updatedAt = block.timestamp; }
    function set(int256 a, uint256 u) external { answer = a; updatedAt = u; }
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// A "destination" contract the FeeCollector owner could name: accepts ETH and forwards it to an EOA.
contract RvForwarder {
    address public immutable to;
    constructor(address t) { to = t; }
    receive() external payable { (bool ok,) = to.call{value: msg.value}(""); require(ok); }
}

/// MOCK challenge level (not one of the real levels): a house account the "planted flaw" `takeHouse` empties, plus
/// honest player deposits/withdrawals. Used only to exercise the shared `Challenge` base.
contract MockLevel is Challenge {
    uint256 public house;
    mapping(address => uint256) public bal;
    address public payee;
    constructor(address r, uint64 o) payable Challenge(r, o) {}
    function _creditHouse(uint256 a) internal override { house += a; }
    function deposit() external payable whenOpen { bal[msg.sender] += msg.value; }
    function withdrawOwn(uint256 a) external whenOpen { bal[msg.sender] -= a; _pay(msg.sender, a); }
    function takeHouse(address to) external whenOpen { uint256 a = house; house = 0; _pay(to, a); }
    /// a permissionless "release" that pays a pre-set payee (e.g. a matured queue entry, a relayed signature)
    function setPayee(address p) external { payee = p; }
    function releaseHouseTo() external whenOpen { uint256 a = house; house = 0; _pay(payee, a); }
}

contract ReviewEVMTest is Test {
    Blacklist bl;
    FeeCollector fc;
    Subscription sub;
    SanctumFactory factory;
    RvFeed feed;
    RvToken usdc;

    address dev = makeAddr("dev");
    address cold = makeAddr("cold");
    address guardian = makeAddr("guardian");
    address thief = makeAddr("thief");
    address user;
    uint256 userPk;

    function setUp() public {
        vm.warp(1_793_600_000);
        (user, userPk) = makeAddrAndKey("user-hot");
        feed = new RvFeed();
        usdc = new RvToken();
        vm.startPrank(dev);
        bl = new Blacklist();
        fc = new FeeCollector(dev);
        sub = new Subscription(address(feed), address(fc), address(usdc));
        factory = new SanctumFactory(address(bl), address(0), address(fc), address(sub));
        sub.setFactory(address(factory));
        vm.stopPrank();
    }

    function _sanctum(uint256 eth) internal returns (Sanctum s) {
        address[] memory g = new address[](1);
        g[0] = guardian;
        vm.deal(user, eth);
        vm.prank(user);
        s = Sanctum(payable(factory.create{value: eth}(cold, g, 0)));
    }

    // ---- H: launch-day reality: no watchers, so a stolen hot key takes ~everything after 6 h unless a human acts ----
    function test_REV_H_no_watchers_stolen_hot_key_takes_99_7pct_in_6h() public {
        Sanctum s = _sanctum(10 ether);
        // thief holds the hot key: takes the immediate room, queues the rest
        vm.startPrank(user);
        uint256 room = s.capRoom(address(0));
        s.withdraw(address(0), thief, room);
        uint256 id = s.withdraw(address(0), thief, address(s).balance);
        vm.stopPrank();
        assertEq(room, 0.5 ether);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(user);
        s.executeQueued(id);
        // 10 ETH - 0.25% fee on the queued 9.5 ETH
        assertEq(thief.balance, 0.5 ether + 9.5 ether - 9.5 ether * 25 / 10_000);
        assertEq(address(s).balance, 0);
    }

    // ---- M: a hot-key thief can re-freeze forever (owner panic is never muted); cold must rotate the owner FIRST ----
    function test_REV_M_hot_key_refreezes_after_unfreeze_cold_must_setOwner_first() public {
        Sanctum s = _sanctum(10 ether);
        vm.prank(user); s.panic();
        vm.prank(cold); s.unfreeze();
        vm.prank(user); s.panic(); // back-run of the unfreeze: allowed, guardians' mute does not apply to the owner
        assertGt(s.frozenUntil(), block.timestamp);
        // the remedy works while frozen
        vm.prank(cold); s.setOwner(cold);
        vm.prank(cold); s.unfreeze();
        vm.prank(user); vm.expectRevert(bytes("standing")); s.panic();
    }

    // ---- M: cancel race: the queue is executable in the exact second readyAt is reached; a later cancel is too late ----
    function test_REV_M_execute_at_readyAt_beats_a_late_cancel() public {
        Sanctum s = _sanctum(10 ether);
        vm.prank(user);
        uint256 id = s.withdraw(address(0), thief, 5 ether);
        (,,, uint64 readyAt,) = s.queue(id);
        vm.warp(readyAt);
        vm.prank(user); s.executeQueued(id); // thief lands first in the block (priority fee / mempool front-run)
        vm.prank(cold); vm.expectRevert(bytes("done")); s.cancel(id);
        // panic would also have been too late; it had to land before readyAt
    }

    // ---- M: the 7702 delegate does not restrict transactions the EOA key signs itself ----
    function test_REV_M_7702_delegate_does_not_stop_eoa_signed_transfers() public {
        Sanctum s = _sanctum(1 ether);
        Sanctum7702 d = new Sanctum7702();
        vm.signAndAttachDelegation(address(d), userPk);
        vm.prank(user);
        Sanctum7702(payable(user)).init(address(s));
        assertEq(Sanctum7702(payable(user)).vault(), address(s));
        usdc.mint(user, 1_000e6);
        // a normal tx from the EOA (tx.origin = msg.sender = user) never runs the delegate's code
        vm.prank(user, user);
        usdc.transfer(thief, 1_000e6);
        assertEq(usdc.balanceOf(thief), 1_000e6);
    }

    // ---- L: uint192 truncation in the day ring lets a huge-supply token skip the daily cap ----
    function test_REV_L_uint192_truncation_skips_daily_cap() public {
        Sanctum s = _sanctum(0);
        RvToken big = new RvToken();
        uint256 supply = uint256(1) << 210;
        big.mint(address(s), supply);
        uint256 before = supply;
        for (uint256 i; i < 6; ++i) {
            // just under 5% of the balance, rounded down to a multiple of 2^192: truncates to 0 in uint192
            uint256 step = (big.balanceOf(address(s)) * 490 / 10_000 >> 192) << 192;
            vm.prank(user);
            uint256 id = s.withdraw(address(big), thief, step);
            assertEq(id, type(uint256).max); // paid at once, not queued
            assertEq(s.daySpentRolling(address(big)), 0);
            vm.warp(block.timestamp + 1 hours + 1);
        }
        // 6 hours: 6 x 4.69% = 28% of the balance left at once, the daily cap is 10%
        assertGt(big.balanceOf(thief) * 100 / before, 25);
    }

    // ---- M: the Blacklist oracle (dev EOA) can brick the raid game: BountyCold cannot change the blacklist ----
    function test_REV_M_blacklist_oracle_bricks_raid_probes() public {
        vm.deal(dev, 1 ether);
        address[] memory g = new address[](0);
        vm.prank(dev);
        BountyCold bc = new BountyCold{value: 0.5 ether}(dev, address(factory), g, 0);
        BountySanctum b = bc.bounty();
        uint256 room = b.probeRoom();
        address vault = address(b.sanctum());
        vm.prank(dev);
        bl.flag(vault, true, "grief");
        vm.prank(thief);
        vm.expectRevert(bytes("blacklisted"));
        b.withdraw(address(0), vault, room);
        // BountyCold exposes no setBlacklist: only the Blacklist owner/oracle can undo it
    }

    // ---- M: before the destination is set, the FeeCollector owner decides where every fee goes (incl. itself) ----
    function test_REV_M_feecollector_owner_can_route_fees_to_self_via_forwarder() public {
        Sanctum s = _sanctum(10 ether);
        vm.prank(user);
        uint256 id = s.withdraw(address(0), user, 5 ether);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(user); s.executeQueued(id);
        uint256 fee = address(fc).balance;
        assertEq(fee, 5 ether * 25 / 10_000);
        vm.prank(dev);
        RvForwarder fw = new RvForwarder(dev);
        vm.prank(dev); fc.setDestination(address(fw));
        uint256 before = dev.balance;
        fc.forwardETH();
        assertEq(dev.balance - before, fee);
    }

    // ---- L: Subscription accepts a 23h-old price (Base feed heartbeat is ~20 min) and pays for any address ----
    function test_REV_L_subscription_stale_price_and_unregistered_target() public {
        vm.warp(block.timestamp + 2 days);
        feed.set(2285e8, block.timestamp - 23 hours);
        uint256 p = sub.monthlyPriceWei();
        assertGt(p, 0); // accepted
        address eoa = makeAddr("someone-pays-for-an-eoa-by-mistake");
        vm.deal(address(this), 1 ether);
        sub.pay{value: p}(eoa, 1);
        assertTrue(sub.isCovered(eoa));
        assertFalse(sub.registered(eoa));
    }

    // ---- M: challenge base: honest deposits >= prize/2 hide a full house drain from the solve check ----
    function test_REV_M_challenge_solve_check_griefed_by_deposits() public {
        ChallengeRegistry reg = new ChallengeRegistry(dev);
        vm.deal(dev, 1 ether);
        vm.prank(dev);
        MockLevel lv = new MockLevel{value: 0.1 ether}(address(reg), uint64(block.timestamp));
        vm.prank(dev); reg.addLevel(address(lv));
        address griefer = makeAddr("griefer");
        vm.deal(griefer, 0.05 ether);
        vm.prank(griefer); lv.deposit{value: 0.05 ether}();
        address solver = makeAddr("solver");
        vm.prank(solver, solver); lv.takeHouse(solver);
        assertEq(solver.balance, 0.1 ether);  // whole house taken
        assertEq(lv.solvedBy(), address(0)); // ...but not "solved": balance 0.05 = prize/2
        // the griefer leaves afterwards; a solve is only checked inside _pay, so it is credited to whoever pays out next
        vm.prank(griefer, griefer); lv.withdrawOwn(0.05 ether);
        assertEq(lv.solvedBy(), griefer);
    }

    // ---- L: tx.origin credit: whoever triggers a permissionless payout takes the leaderboard credit ----
    function test_REV_L_challenge_credit_goes_to_trigger_not_payee() public {
        ChallengeRegistry reg = new ChallengeRegistry(dev);
        vm.deal(dev, 1 ether);
        vm.prank(dev);
        MockLevel lv = new MockLevel{value: 0.1 ether}(address(reg), uint64(block.timestamp));
        vm.prank(dev); reg.addLevel(address(lv));
        address solver = makeAddr("solver");
        address copier = makeAddr("copier");
        lv.setPayee(solver);
        vm.prank(copier, copier); lv.releaseHouseTo();
        assertEq(solver.balance, 0.1 ether);
        assertEq(lv.solvedBy(), copier);
        assertEq(reg.solves(copier), 1);
    }
}
