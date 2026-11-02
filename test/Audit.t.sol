// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {Sanctum7702} from "../src/Sanctum7702.sol";

/// Vault + 7702 regression tests for the pre-launch audit fixes.
/// No fork needed: the delegate and vault are self-contained.
contract AuditTest is Fixture {
    function setUp() public { _base(); }

    function _tight(address hot_, address cold_, address[] memory g) internal returns (Sanctum) {
        return new Sanctum(hot_, cold_, address(blacklist), address(registry), address(feeRouter), g, 0,
            Sanctum.Rules({capBps: 200, dayCapBps: 1000, delayBps: 1000, delay: 1 hours, allowlistOn: false}));
    }

    // H: one guardian could re-panic every 24h and freeze any Sanctum (incl. the cold key) forever
    function test_fix_guardian_cannot_refreeze_after_cold_unfreeze() public {
        address griefer = makeAddr("griefer");
        address[] memory g = new address[](1); g[0] = griefer;
        Sanctum v = _tight(hot, cold, g);
        vm.deal(address(v), 10 ether);
        vm.prank(griefer); v.panic();
        vm.prank(cold); v.unfreeze();
        vm.prank(griefer); vm.expectRevert(bytes("muted")); v.panic();
        vm.prank(cold); v.coldWithdraw(address(0), cold, 0.2 ether);
        assertEq(cold.balance, 0.2 ether);
        vm.prank(hot); v.panic(); // owner/cold are never muted
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(griefer); v.panic(); // guardians regain the right after the mute
    }

    // H: stolen hot key could lift the cap to 100% one `delay` (1h) after proposing, then drain
    function test_fix_hot_key_rule_change_slow_and_panic_cancels() public {
        address thief = makeAddr("thief");
        Sanctum v = _tight(hot, cold, _one());
        vm.deal(address(v), 10 ether);
        Sanctum.Rules memory open_ = Sanctum.Rules({capBps: 10_000, dayCapBps: 1000, delayBps: 10_000, delay: 1 hours, allowlistOn: false});
        vm.prank(hot); vm.expectRevert(bytes("cap: tighten only")); v.proposeRules(open_);
        open_ = Sanctum.Rules({capBps: 100, dayCapBps: 1000, delayBps: 1000, delay: 1 hours, allowlistOn: false});
        vm.prank(hot); v.proposeRules(open_);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(hot); vm.expectRevert(bytes("waiting")); v.applyRules();
        // a guardian spots the proposal and panics: pending change is dropped
        vm.prank(g1); v.panic();
        assertEq(v.rulesReadyAt(), 0);
        vm.warp(block.timestamp + 3 days);
        vm.prank(hot); vm.expectRevert(bytes("waiting")); v.applyRules();
        // over the 2% hourly cap: queued (not paid), and the cold key cancels it
        vm.prank(hot); uint256 qid = v.withdraw(address(0), thief, 1 ether);
        assertTrue(qid != type(uint256).max);
        assertEq(thief.balance, 0);
        (,, uint256 qamt,,) = v.queue(qid);
        assertEq(qamt, 1 ether);
        vm.prank(cold); v.cancel(qid);
        // legit path still works: 3 days, no panic
        vm.prank(hot); v.proposeRules(open_);
        vm.warp(block.timestamp + 3 days);
        vm.prank(hot); v.applyRules();
        (uint16 capBps,,,,) = v.rules();
        assertEq(capBps, 100);
    }

    // frozen: every outflow path and the hot-key rule path are closed; cold admin still works
    function test_frozen_blocks_all_outflows_but_not_cold_admin() public {
        Sanctum v = _sanctum();
        vm.prank(hot); uint256 id = v.withdraw(address(0), hot, 50 ether);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(g1); v.panic();
        vm.prank(hot); vm.expectRevert(bytes("frozen")); v.withdraw(address(0), hot, 1);
        vm.prank(hot); vm.expectRevert(bytes("frozen")); v.executeQueued(id);
        vm.prank(cold); vm.expectRevert(bytes("frozen")); v.coldWithdraw(address(0), cold, 1);
        vm.prank(hot); vm.expectRevert(bytes("frozen")); v.proposeRules(_defaults());
        vm.prank(hot); vm.expectRevert(bytes("frozen")); v.applyRules();
        vm.prank(cold); v.cancel(id);
        vm.prank(cold); v.coldSetRules(_defaults());
        vm.prank(cold); v.setOwner(makeAddr("newHot"));
        assertEq(address(v).balance, 100 ether);
        vm.prank(cold); v.unfreeze();
        vm.prank(cold); v.coldWithdraw(address(0), cold, 1 ether);
        assertEq(cold.balance, 1 ether);
    }

    // M: anyone could sweep the guarded EOA to 0 ETH, leaving the owner unable to pay gas
    function test_fix_sweep_leaves_gas_reserve_and_nft_receipt() public {
        uint256 pk = 0xA11CE; address eoa = vm.addr(pk);
        Sanctum v = _tight(eoa, cold, _one());
        Sanctum7702 g = new Sanctum7702();
        vm.signAndAttachDelegation(address(g), pk);
        vm.prank(eoa); Sanctum7702(payable(eoa)).init(address(v));
        vm.deal(eoa, 1 ether);
        Sanctum7702(payable(eoa)).sweep(address(0)); // stranger
        assertEq(eoa.balance, 0.01 ether);
        assertEq(address(v).balance, 0.99 ether);
        vm.prank(eoa); Sanctum7702(payable(eoa)).sweep(address(0)); // owner can sweep all
        assertEq(eoa.balance, 0);
        assertEq(Sanctum7702(payable(eoa)).onERC721Received(address(0), address(0), 0, ""), bytes4(0x150b7a02));
    }
}
