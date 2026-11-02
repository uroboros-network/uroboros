// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture, RejectingSink} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {SanctumFactory} from "../src/SanctumFactory.sol";

/// SPEC §3.1(b): 0.25% of every executed queued transfer, same asset, to feeRouter. Nothing else pays a fee.
contract FeeTest is Fixture {
    event QueuedFee(uint256 id, address token, uint256 fee);
    event Sent(address token, address to, uint256 amount);

    address to = makeAddr("to");

    function setUp() public { _base(); }

    function test_fee_constant() public {
        Sanctum v = _sanctum();
        assertEq(v.FEE_BPS(), 25);
        assertEq(_fee(100 ether), 0.25 ether);
    }

    function test_eth_fee_exact_to_router() public {
        Sanctum v = _sanctum();
        vm.prank(hot); uint256 id = v.withdraw(address(0), to, 40 ether);
        vm.warp(block.timestamp + 6 hours);
        uint256 fee = 40 ether * 25 / 10_000; // 0.1 ETH
        assertEq(fee, 0.1 ether);
        vm.expectEmit(address(v)); emit Sent(address(0), address(feeRouter), fee);
        vm.expectEmit(address(v)); emit QueuedFee(id, address(0), fee);
        vm.expectEmit(address(v)); emit Sent(address(0), to, 40 ether - fee);
        vm.prank(hot); v.executeQueued(id);
        assertEq(to.balance, 39.9 ether);
        assertEq(address(feeRouter).balance, 0.1 ether);
        assertEq(feeRouter.received(), 0.1 ether);
        assertEq(address(v).balance, 60 ether);
    }

    function test_erc20_fee_exact_to_router() public {
        Sanctum v = _sanctum();
        token.mint(address(v), 1_000_000e18);
        vm.prank(hot); uint256 id = v.withdraw(address(token), to, 400_000e18);
        vm.warp(block.timestamp + 6 hours);
        uint256 fee = 400_000e18 * 25 / 10_000; // 1000 tokens
        assertEq(fee, 1_000e18);
        vm.expectEmit(address(v)); emit QueuedFee(id, address(token), fee);
        vm.prank(cold); v.executeQueued(id);
        assertEq(token.balanceOf(to), 399_000e18);
        assertEq(token.balanceOf(address(feeRouter)), 1_000e18);
        assertEq(token.balanceOf(address(v)), 600_000e18);
        assertEq(address(feeRouter).balance, 0); // nothing crossed assets
    }

    /// Fee is floor(amount * 25 / 10000); recipient + router always equal the gross amount, nothing is lost.
    function testFuzz_fee_conserves_amount(uint256 amount) public {
        Sanctum v = _sanctum();
        amount = bound(amount, 10.01 ether, 100 ether); // always queued
        vm.prank(hot); uint256 id = v.withdraw(address(0), to, amount);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hot); v.executeQueued(id);
        uint256 fee = amount * 25 / 10_000;
        assertEq(feeRouter.received(), fee);
        assertEq(to.balance, amount - fee);
        assertEq(to.balance + feeRouter.received(), amount);
        assertEq(address(v).balance, 100 ether - amount);
    }

    function test_tiny_queued_amount_pays_no_fee() public {
        Sanctum v = _sanctum();
        // 399 wei * 25 / 10000 rounds to 0: queue it by first using up the hourly cap
        vm.prank(hot); v.withdraw(address(0), to, 5 ether);
        vm.prank(hot); uint256 id = v.withdraw(address(0), to, 399);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hot); v.executeQueued(id);
        assertEq(feeRouter.received(), 0);
        assertEq(to.balance, 5 ether + 399);
    }

    function test_direct_withdraw_pays_no_fee() public {
        Sanctum v = _sanctum();
        vm.prank(hot); uint256 id = v.withdraw(address(0), to, 5 ether);
        assertEq(id, type(uint256).max);
        assertEq(to.balance, 5 ether);
        assertEq(feeRouter.received(), 0);
        token.mint(address(v), 1000e18);
        vm.prank(hot); v.withdraw(address(token), to, 50e18);
        assertEq(token.balanceOf(to), 50e18);
        assertEq(token.balanceOf(address(feeRouter)), 0);
    }

    function test_cold_withdraw_pays_no_fee() public {
        Sanctum v = _sanctum();
        vm.prank(cold); v.coldWithdraw(address(0), to, 5 ether);
        assertEq(to.balance, 5 ether);
        assertEq(feeRouter.received(), 0);
        token.mint(address(v), 1000e18);
        vm.prank(cold); v.coldWithdraw(address(token), to, 50e18);
        assertEq(token.balanceOf(to), 50e18);
        assertEq(token.balanceOf(address(feeRouter)), 0);
    }

    function test_cold_cannot_bypass_fee_by_executing_queue() public {
        Sanctum v = _sanctum();
        vm.prank(hot); uint256 id = v.withdraw(address(0), to, 50 ether);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(cold); v.executeQueued(id);
        assertEq(feeRouter.received(), _fee(50 ether));
    }

    /// Honest limit: a fee router that refuses ETH blocks ETH queue releases. ERC-20 releases are unaffected,
    /// and the cold key can still drain under the caps.
    function test_rejecting_router_blocks_eth_queue_only() public {
        RejectingSink bad = new RejectingSink();
        Sanctum v = new Sanctum(hot, cold, address(blacklist), address(registry), address(bad), _one(), 0, _defaults());
        vm.deal(address(v), 100 ether);
        token.mint(address(v), 1000e18);
        vm.prank(hot); uint256 id = v.withdraw(address(0), to, 50 ether);
        vm.prank(hot); uint256 tid = v.withdraw(address(token), to, 500e18);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hot); vm.expectRevert(bytes("eth send")); v.executeQueued(id);
        vm.prank(hot); v.executeQueued(tid);
        assertEq(token.balanceOf(address(bad)), 500e18 * 25 / 10_000);
        vm.prank(cold); v.coldWithdraw(address(0), cold, 5 ether);
        assertEq(cold.balance, 5 ether);
    }

    function test_fee_router_immutable_and_required() public {
        vm.expectRevert(bytes("feeRouter"));
        new Sanctum(hot, cold, address(blacklist), address(registry), address(0), _one(), 0, _defaults());
        vm.expectRevert(bytes("addr"));
        new SanctumFactory(address(blacklist), address(registry), address(0), address(sub));
        vm.expectRevert(bytes("addr"));
        new SanctumFactory(address(blacklist), address(registry), address(feeRouter), address(0));
    }
}
