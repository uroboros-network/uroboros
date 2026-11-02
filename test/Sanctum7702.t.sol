// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./Fixture.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {Sanctum7702} from "../src/Sanctum7702.sol";

/// Sanctum7702: ERC-7201 namespace "sanctum.7702.storage".
contract Sanctum7702Test is Fixture {
    uint256 pk = 0xA11CE;
    address eoa;
    Sanctum v;
    Sanctum7702 impl;

    event Initialized(address eoa, address vault);
    event Swept(address token, uint256 amount);

    function setUp() public {
        _base();
        eoa = vm.addr(pk);
        vm.prank(eoa);
        v = Sanctum(payable(factory.create(cold, _one(), 0)));
        impl = new Sanctum7702();
        vm.signAndAttachDelegation(address(impl), pk);
    }

    function _d() internal view returns (Sanctum7702) { return Sanctum7702(payable(eoa)); }

    /// ERC-7201: keccak256(abi.encode(uint256(keccak256("sanctum.7702.storage")) - 1)) & ~bytes32(uint256(0xff)).
    function test_erc7201_slot() public {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("sanctum.7702.storage")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(expected, bytes32(0xa03061a946d8080ed95c98169f3ff203def10761cbfa5ea84a832ad996cabe00));
        // and the contract really stores the vault there: init, then read the EOA's storage at that slot
        vm.prank(eoa); _d().init(address(v));
        assertEq(address(uint160(uint256(vm.load(eoa, expected)))), address(v));
        // not a foreign namespace slot
        assertEq(vm.load(eoa, 0x8a74ff036d5d514fc667f53c7a35da1f909259109bb1f377c5c4760cca0db500), bytes32(0));
        assertEq(uint256(expected) & 0xff, 0);
    }

    function test_init_self_once_nonzero() public {
        vm.expectRevert(bytes("self")); _d().init(address(v));
        vm.prank(eoa); vm.expectRevert(bytes("vault")); _d().init(address(0));
        vm.expectEmit(eoa); emit Initialized(eoa, address(v));
        vm.prank(eoa); _d().init(address(v));
        assertEq(_d().vault(), address(v));
        vm.prank(eoa); vm.expectRevert(bytes("init")); _d().init(address(v));
    }

    function test_sweep_eth_reserve_and_erc20() public {
        vm.expectRevert(bytes("init")); _d().sweep(address(0));
        vm.prank(eoa); _d().init(address(v));
        vm.deal(eoa, 1 ether);
        token.mint(eoa, 500e18);
        vm.expectEmit(eoa); emit Swept(address(0), 0.99 ether);
        vm.prank(makeAddr("stranger")); _d().sweep(address(0));
        assertEq(eoa.balance, 0.01 ether);
        assertEq(address(v).balance, 0.99 ether);
        vm.prank(makeAddr("stranger")); _d().sweep(address(0)); // at the reserve: sends 0
        assertEq(eoa.balance, 0.01 ether);
        vm.prank(makeAddr("stranger")); _d().sweep(address(token));
        assertEq(token.balanceOf(address(v)), 500e18);
        assertEq(token.balanceOf(eoa), 0);
        vm.prank(eoa); _d().sweep(address(0)); // owner sweeps the reserve too
        assertEq(eoa.balance, 0);
        assertEq(address(v).balance, 1 ether);
        assertEq(_d().GAS_RESERVE(), 0.01 ether);
    }

    function test_execute_only_vault_and_only_self() public {
        vm.prank(eoa); _d().init(address(v));
        vm.deal(address(v), 100 ether);
        bytes memory data = abi.encodeCall(Sanctum.withdraw, (address(0), eoa, 1 ether));
        vm.expectRevert(bytes("self")); _d().execute(address(v), 0, data);
        vm.prank(eoa); vm.expectRevert(bytes("only vault")); _d().execute(makeAddr("elsewhere"), 0, "");
        vm.prank(eoa); vm.expectRevert(bytes("only vault")); _d().execute(address(token), 0, abi.encodeCall(token.transfer, (hot, 1)));
        vm.prank(eoa); bytes memory ret = _d().execute(address(v), 0, data);
        assertEq(abi.decode(ret, (uint256)), type(uint256).max);
        assertEq(eoa.balance, 1 ether);
        // a failing vault call surfaces as "call"
        vm.prank(eoa); vm.expectRevert(bytes("call")); _d().execute(address(v), 0, abi.encodeCall(Sanctum.withdraw, (address(0), eoa, 1000 ether)));
        // the delegated hot key can still panic its own Sanctum through execute
        vm.prank(eoa); _d().execute(address(v), 0, abi.encodeCall(Sanctum.panic, ()));
        assertGt(v.frozenUntil(), block.timestamp);
    }

    function test_receivers() public view {
        assertEq(_d().onERC721Received(address(0), address(0), 0, ""), bytes4(0x150b7a02));
        assertEq(_d().onERC1155Received(address(0), address(0), 0, 0, ""), bytes4(0xf23a6e61));
        uint256[] memory e = new uint256[](0);
        assertEq(_d().onERC1155BatchReceived(address(0), address(0), e, e, ""), bytes4(0xbc197c81));
    }
}
