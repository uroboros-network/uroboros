// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture, MockAggregator, FeeSink, MockUSDC} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {Subscription} from "../src/Subscription.sol";

/// SPEC §3.1(a) + §11: $5/month per Sanctum in ETH via Chainlink or in USDC, 7-day trial only for Sanctums holding
/// ≥ $100 at registration, `coveredUntil` view, never a gate.
contract SubscriptionTest is Fixture {
    event Registered(address sanctum, uint64 trialUntil);
    event Paid(address sanctum, address payer, uint256 months, uint256 weiPaid, uint64 coveredUntil);
    event PaidUsdc(address sanctum, address payer, uint256 months, uint256 usdcPaid, uint64 coveredUntil);

    address payer = makeAddr("payer");

    function setUp() public { _base(); vm.deal(payer, 100 ether); usdc.mint(payer, 10_000e6); }

    // $5 at $3000/ETH = 5/3000 ETH
    function _month() internal pure returns (uint256) { return 5e18 * 1e8 / uint256(3000e8); }

    function test_trial_starts_at_creation_when_funded() public {
        vm.deal(hot, 1 ether);
        vm.prank(hot);
        vm.expectEmit(false, false, false, false, address(sub)); // address unknown before creation
        emit Registered(address(0), 0);
        Sanctum v = Sanctum(payable(factory.create{value: 0.04 ether}(cold, _one(), 0))); // $120 at $3000
        assertEq(address(v).balance, 0.04 ether);
        assertEq(sub.coveredUntil(address(v)), block.timestamp + 7 days);
        assertTrue(sub.isCovered(address(v)));
        assertTrue(sub.registered(address(v)));
        vm.warp(block.timestamp + 7 days);
        assertTrue(sub.isCovered(address(v)));
        vm.warp(block.timestamp + 1);
        assertFalse(sub.isCovered(address(v)));
        assertEq(sub.coveredUntil(makeAddr("nobody")), 0);
    }

    /// AUDIT-1 S1 / SPEC §11: an empty or under-$100 Sanctum is registered but gets no trial.
    function test_no_trial_below_100_usd() public {
        Sanctum empty = _emptySanctum();
        assertTrue(sub.registered(address(empty)));
        assertEq(sub.coveredUntil(address(empty)), 0);
        assertFalse(sub.isCovered(address(empty)));
        vm.deal(hot, 1 ether);
        vm.prank(hot);
        Sanctum low = Sanctum(payable(factory.create{value: 0.03 ether}(cold, _one(), 0))); // $90
        assertEq(sub.coveredUntil(address(low)), 0);
        // the first wei amount that values to ≥ $100 qualifies (floor division: $100/3000 ETH rounds just under)
        uint256 wei100 = uint256(100e18) * 1e8 / uint256(3000e8);
        vm.prank(hot);
        Sanctum under = Sanctum(payable(factory.create{value: wei100}(cold, _one(), 0)));
        assertEq(sub.coveredUntil(address(under)), 0);
        vm.prank(hot);
        Sanctum edge = Sanctum(payable(factory.create{value: wei100 + 1}(cold, _one(), 0)));
        assertEq(sub.coveredUntil(address(edge)), block.timestamp + 7 days);
        // funding AFTER registration does not start a trial (one check, at registration)
        vm.deal(address(empty), 50 ether);
        assertEq(sub.coveredUntil(address(empty)), 0);
    }

    /// A stale feed cannot block Sanctum creation: it only costs the trial.
    function test_stale_feed_means_no_trial_not_a_revert() public {
        feed.set(3000e8, block.timestamp - 25 hours);
        vm.deal(hot, 1 ether);
        vm.prank(hot);
        Sanctum v = Sanctum(payable(factory.create{value: 0.5 ether}(cold, _one(), 0)));
        assertEq(sub.coveredUntil(address(v)), 0);
        assertEq(address(v).balance, 0.5 ether);
        feed.set(0, block.timestamp);
        vm.prank(hot);
        Sanctum w = Sanctum(payable(factory.create{value: 0.5 ether}(cold, _one(), 0)));
        assertEq(sub.coveredUntil(address(w)), 0);
    }

    function test_pay_in_usdc() public {
        Sanctum v = _sanctum();
        uint64 trialEnd = sub.coveredUntil(address(v));
        assertEq(sub.priceUsdc(3), 15e6);
        vm.expectRevert(bytes("months")); sub.priceUsdc(0);
        vm.prank(payer); vm.expectRevert(); sub.payUsdc(address(v), 3); // no allowance
        vm.prank(payer); usdc.approve(address(sub), 15e6);
        vm.expectEmit(address(sub)); emit PaidUsdc(address(v), payer, 3, 15e6, trialEnd + 90 days);
        vm.prank(payer); sub.payUsdc(address(v), 3);
        assertEq(sub.coveredUntil(address(v)), trialEnd + 90 days);
        assertEq(usdc.balanceOf(address(feeRouter)), 15e6);
        assertEq(usdc.balanceOf(payer), 10_000e6 - 15e6);
        assertEq(usdc.balanceOf(address(sub)), 0);
        // USDC never touches the oracle
        feed.set(0, block.timestamp);
        vm.prank(payer); usdc.approve(address(sub), 5e6);
        vm.prank(payer); sub.payUsdc(address(v), 1);
        assertEq(sub.coveredUntil(address(v)), trialEnd + 120 days);
        vm.prank(payer); vm.expectRevert(bytes("sanctum")); sub.payUsdc(address(0), 1);
    }

    function test_register_factory_only_and_idempotent() public {
        address s = makeAddr("s");
        vm.prank(hot); vm.expectRevert(bytes("factory")); sub.register(s, true);
        vm.prank(deployer); vm.expectRevert(bytes("factory")); sub.register(s, true);
        vm.deal(s, 1 ether);
        vm.prank(address(factory)); sub.register(s, true);
        uint64 u = sub.coveredUntil(s);
        assertEq(u, block.timestamp + 7 days);
        vm.warp(block.timestamp + 1 days);
        vm.prank(address(factory)); sub.register(s, true); // no-op: the trial does not restart
        assertEq(sub.coveredUntil(s), u);
        // an unfunded registration is also final: funding later + re-register gives nothing
        address e = makeAddr("e");
        vm.prank(address(factory)); sub.register(e, true);
        vm.deal(e, 1 ether);
        vm.prank(address(factory)); sub.register(e, true);
        assertEq(sub.coveredUntil(e), 0);
        // funded but not eligible (custom rules): registered, no trial (AUDIT-2 L2)
        address c = makeAddr("c");
        vm.deal(c, 1 ether);
        vm.prank(address(factory)); sub.register(c, false);
        assertTrue(sub.registered(c));
        assertEq(sub.coveredUntil(c), 0);
    }

    function test_setFactory_one_shot_deployer_only() public {
        Subscription s2 = new Subscription(address(feed), address(feeRouter), address(usdc));
        vm.prank(hot); vm.expectRevert(bytes("deployer")); s2.setFactory(hot);
        vm.expectRevert(bytes("set")); s2.setFactory(address(0));
        s2.setFactory(address(factory));
        assertEq(s2.factory(), address(factory));
        vm.expectRevert(bytes("set")); s2.setFactory(hot);
        // the live one is already bound
        vm.prank(deployer); vm.expectRevert(bytes("set")); sub.setFactory(hot);
    }

    function test_price_from_feed() public {
        assertEq(sub.monthlyPriceWei(), _month());
        assertEq(sub.priceWei(3), _month() * 3);
        assertApproxEqRel(sub.monthlyPriceWei(), 0.001666 ether, 1e15);
        feed.set(1500e8, block.timestamp);
        assertEq(sub.monthlyPriceWei(), 5e18 * 1e8 / uint256(1500e8)); // ETH halves, you pay twice the ETH
        vm.expectRevert(bytes("months")); sub.priceWei(0);
        vm.expectRevert(bytes("months")); sub.priceWei(121);
        sub.priceWei(120);
    }

    function test_pay_extends_from_trial_end_and_forwards_eth() public {
        Sanctum v = _sanctum();
        uint64 trialEnd = sub.coveredUntil(address(v));
        uint256 cost = _month() * 3;
        uint256 routerBefore = address(feeRouter).balance;
        vm.expectEmit(address(sub)); emit Paid(address(v), payer, 3, cost, trialEnd + 90 days);
        vm.prank(payer); sub.pay{value: cost}(address(v), 3);
        assertEq(sub.coveredUntil(address(v)), trialEnd + 90 days);
        assertEq(address(feeRouter).balance - routerBefore, cost);
        assertEq(payer.balance, 100 ether - cost);
        assertEq(address(sub).balance, 0);
    }

    function test_pay_refunds_excess() public {
        Sanctum v = _sanctum();
        uint256 cost = _month();
        vm.prank(payer); sub.pay{value: 1 ether}(address(v), 1);
        assertEq(payer.balance, 100 ether - cost);
        assertEq(feeRouter.received(), cost);
        assertEq(address(sub).balance, 0);
    }

    function test_pay_underpaid_reverts() public {
        Sanctum v = _sanctum();
        uint256 cost = _month() * 2;
        vm.prank(payer); vm.expectRevert(bytes("underpaid")); sub.pay{value: cost - 1}(address(v), 2);
        vm.prank(payer); vm.expectRevert(bytes("months")); sub.pay{value: 1 ether}(address(v), 0);
        vm.prank(payer); vm.expectRevert(bytes("sanctum")); sub.pay{value: 1 ether}(address(0), 1);
    }

    function test_pay_after_lapse_starts_from_now() public {
        Sanctum v = _sanctum();
        vm.warp(block.timestamp + 60 days); // trial long gone
        feed.set(ETH_USD, block.timestamp);  // the feed kept updating meanwhile
        assertFalse(sub.isCovered(address(v)));
        vm.prank(payer); sub.pay{value: _month()}(address(v), 1);
        assertEq(sub.coveredUntil(address(v)), block.timestamp + 30 days);
        assertTrue(sub.isCovered(address(v)));
    }

    function test_anyone_can_pay_for_any_address() public {
        address s = makeAddr("unregistered");
        assertEq(sub.coveredUntil(s), 0);
        vm.prank(payer); sub.pay{value: _month() * 12}(s, 12);
        assertEq(sub.coveredUntil(s), block.timestamp + 360 days);
    }

    function test_stale_feed_reverts_pay_not_views_of_coverage() public {
        Sanctum v = _sanctum();
        feed.set(3000e8, block.timestamp - 24 hours); // exactly 24h old is still fine
        sub.monthlyPriceWei();
        feed.set(3000e8, block.timestamp - 24 hours - 1);
        vm.expectRevert(bytes("stale")); sub.monthlyPriceWei();
        vm.prank(payer); vm.expectRevert(bytes("stale")); sub.pay{value: 1 ether}(address(v), 1);
        // a future timestamp is also refused; a non-positive answer too
        feed.set(3000e8, block.timestamp + 1);
        vm.expectRevert(bytes("stale")); sub.monthlyPriceWei();
        feed.set(0, block.timestamp);
        vm.expectRevert(bytes("feed")); sub.monthlyPriceWei();
        feed.set(-1, block.timestamp);
        vm.expectRevert(bytes("feed")); sub.monthlyPriceWei();
        // coverage views never touch the feed
        assertTrue(sub.isCovered(address(v)));
        assertGt(sub.coveredUntil(address(v)), 0);
        assertEq(payer.balance, 100 ether);
    }

    /// The Sanctum itself never reads the subscription: lapsed coverage changes nothing on chain.
    function test_unpaid_sanctum_keeps_working() public {
        Sanctum v = _sanctum();
        vm.warp(block.timestamp + 400 days);
        assertFalse(sub.isCovered(address(v)));
        vm.prank(hot); v.withdraw(address(0), hot, 4 ether);
        vm.prank(g1); v.panic();
        vm.prank(cold); v.unfreeze();
        vm.prank(cold); v.coldWithdraw(address(0), cold, 1 ether);
        assertEq(hot.balance, 4 ether);
        assertEq(cold.balance, 1 ether);
    }

    function test_constructor_checks() public {
        vm.expectRevert(bytes("addr")); new Subscription(address(0), address(feeRouter), address(usdc));
        vm.expectRevert(bytes("addr")); new Subscription(address(feed), address(0), address(usdc));
        vm.expectRevert(bytes("addr")); new Subscription(address(feed), address(feeRouter), address(0));
        Subscription s2 = new Subscription(address(feed), address(feeRouter), address(usdc));
        assertEq(s2.feedDecimals(), 8);
        assertEq(s2.PRICE_USD(), 5e18);
        assertEq(s2.PRICE_USDC(), 5e6);
        assertEq(s2.TRIAL_MIN_USD(), 100e18);
        assertEq(address(s2.usdc()), address(usdc));
        assertEq(s2.TRIAL(), 7 days);
        assertEq(s2.MONTH(), 30 days);
        assertEq(s2.MAX_STALENESS(), 24 hours);
    }

    function testFuzz_pay_math(uint256 months, int256 price, uint256 extra) public {
        months = bound(months, 1, 120);
        price = int256(bound(uint256(price), 100e8, 100_000e8)); // $100 .. $100k per ETH
        extra = bound(extra, 0, 10 ether);
        feed.set(price, block.timestamp);
        uint256 cost = 5e18 * 1e8 / uint256(price) * months;
        assertEq(sub.priceWei(months), cost);
        Sanctum v = _sanctum();
        uint64 before = sub.coveredUntil(address(v));
        vm.deal(payer, cost + extra);
        vm.prank(payer); sub.pay{value: cost + extra}(address(v), months);
        assertEq(payer.balance, extra);
        assertEq(feeRouter.received(), cost);
        assertEq(sub.coveredUntil(address(v)), before + months * 30 days);
    }
}
