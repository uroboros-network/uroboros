// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";

/// AUDIT-2 PoCs (product part). Tests named `_FIXED_` were written as `_BUG_` against the property the code SHOULD
/// have (they failed on the step-2 code — the proofs) and pass since STEP2-FIXES.

/// LOW — L2 (FIXED). The trial is only granted to Sanctums created with the factory's DEFAULT rules (the factory
/// passes `trialEligible`); `createWithRules` registers without a trial, so 100%-cap rules cannot recycle one $100
/// note per block. Remaining limit (documented in Subscription.sol): with the default rules 10%/24h leaves at once
/// and the rest only via the 6 h queue, so a $100 note can still start a new trial roughly every 6 hours.
contract Audit2SubscriptionTest is Fixture {
    function setUp() public { _base(); }

    /// FIXED (Low): custom-rules Sanctums get no trial; the default-rules trial cannot be drained in the same block.
    function test_FIXED_L2_trial_only_for_default_rules() public {
        vm.deal(hot, 1 ether);
        Sanctum.Rules memory loose = Sanctum.Rules({capBps: 10_000, dayCapBps: 10_000, delayBps: 10_000, delay: 0, allowlistOn: false});
        vm.prank(hot);
        Sanctum s1 = Sanctum(payable(factory.createWithRules{value: 0.04 ether}(cold, _none(), 0, loose))); // $120
        assertTrue(sub.registered(address(s1)));
        assertFalse(sub.isCovered(address(s1)), "custom rules: registered, no trial");
        vm.prank(cold);
        s1.coldWithdraw(address(0), hot, 0.04 ether); // caps 100%: everything leaves — but there was no trial to keep
        vm.prank(hot);
        Sanctum s2 = Sanctum(payable(factory.createWithRules{value: 0.04 ether}(cold, _none(), 0, loose)));
        assertFalse(sub.isCovered(address(s2)), "L2: no trial from recycled funds with custom rules");
        // default rules: trial granted, and the $100 cannot leave in the same block (5%/h, 10%/24h, queue 6 h)
        vm.prank(hot);
        Sanctum s3 = Sanctum(payable(factory.create{value: 0.04 ether}(cold, _none(), 0)));
        assertTrue(sub.isCovered(address(s3)));
        vm.prank(cold);
        vm.expectRevert();
        s3.coldWithdraw(address(0), hot, 0.04 ether);
        vm.prank(cold);
        s3.coldWithdraw(address(0), hot, 0.002 ether); // 5% is what the cold key can take now
        assertEq(address(s3).balance, 0.038 ether);
    }
}
