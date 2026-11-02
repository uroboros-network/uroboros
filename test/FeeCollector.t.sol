// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {Blacklist} from "../src/Blacklist.sol";
import {Subscription} from "../src/Subscription.sol";
import {SanctumFactory} from "../src/SanctumFactory.sol";
import {Sanctum} from "../src/Sanctum.sol";

contract FCToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// ERC-20 whose transfer calls back into the receiver (ERC-777 style hook) to try reentrancy.
contract HookToken is ERC20 {
    constructor() ERC20("Hook", "HOOK") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
    function _update(address from, address to, uint256 v) internal override {
        super._update(from, to, v);
        if (to.code.length > 0 && from != address(0)) Reenterer(payable(to)).onToken();
    }
}

contract FCFeed {
    int256 public answer = 3000e8;
    function decimals() external pure returns (uint8) { return 8; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }
}

/// A plain fee-destination stand-in: accepts ETH and tokens.
contract Sink {
    receive() external payable {}
}

/// Destination that tries to re-enter the collector while being paid.
contract Reenterer {
    FeeCollector public fc;
    address public token;
    bool public tried;
    bool public reentryOk;
    bytes public reentryErr;

    function setFc(FeeCollector f, address t) external { fc = f; token = t; }

    receive() external payable {
        if (address(fc) == address(0) || tried) return;
        tried = true;
        try fc.forwardETH() { reentryOk = true; } catch (bytes memory e) { reentryErr = e; }
    }

    function onToken() external {
        if (tried || address(fc) == address(0)) return;
        tried = true;
        try fc.forwardToken(token) { reentryOk = true; } catch (bytes memory e) { reentryErr = e; }
    }
}

contract FeeCollectorTest is Test {
    FeeCollector fc;
    Sink sink;
    FCToken tok;
    address owner = makeAddr("owner");
    address anyone = makeAddr("anyone");

    event DestinationSet(address indexed destination);
    event ForwardedETH(address indexed caller, address indexed destination, uint256 amount);
    event ForwardedToken(address indexed caller, address indexed token, address indexed destination, uint256 amount);

    function setUp() public {
        fc = new FeeCollector(owner);
        sink = new Sink();
        tok = new FCToken();
    }

    // ---- write-once destination ----------------------------------------------------------

    function test_destination_writeOnce() public {
        assertEq(fc.destination(), address(0));
        vm.expectEmit(true, false, false, false, address(fc));
        emit DestinationSet(address(sink));
        vm.prank(owner);
        fc.setDestination(address(sink));
        assertEq(fc.destination(), address(sink));

        Sink other = new Sink();
        vm.prank(owner);
        vm.expectRevert(bytes("destination set"));
        fc.setDestination(address(other));
        assertEq(fc.destination(), address(sink));
    }

    function test_destination_onlyOwner() public {
        vm.prank(anyone);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, anyone));
        fc.setDestination(address(sink));
    }

    function test_destination_mustBeContract() public {
        vm.startPrank(owner);
        vm.expectRevert(bytes("destination must be a contract"));
        fc.setDestination(makeAddr("eoa"));
        vm.expectRevert(bytes("destination must be a contract"));
        fc.setDestination(address(0));
        vm.expectRevert(bytes("destination must be a contract"));
        fc.setDestination(address(fc));
        vm.stopPrank();
    }

    function test_twoStepOwnership_newOwnerStillWriteOnce() public {
        address next = makeAddr("next");
        vm.prank(owner);
        fc.transferOwnership(next);
        assertEq(fc.owner(), owner); // not yet
        vm.prank(next);
        fc.acceptOwnership();
        assertEq(fc.owner(), next);
        vm.prank(next);
        fc.setDestination(address(sink));
        Sink other = new Sink();
        vm.prank(next);
        vm.expectRevert(bytes("destination set"));
        fc.setDestination(address(other));
    }

    function test_renounce_onlyAfterDestination() public {
        vm.prank(owner);
        vm.expectRevert(bytes("set destination first"));
        fc.renounceOwnership();
        vm.prank(owner);
        fc.setDestination(address(sink));
        vm.prank(owner);
        fc.renounceOwnership();
        assertEq(fc.owner(), address(0));
        // forwarding still works with no owner
        vm.deal(address(fc), 1 ether);
        fc.forwardETH();
        assertEq(address(sink).balance, 1 ether);
    }

    // ---- no owner withdrawal ---------------------------------------------------------------

    function test_ownerCannotWithdraw() public {
        vm.deal(address(fc), 5 ether);
        tok.mint(address(fc), 100e18);
        uint256 ob = owner.balance;
        vm.startPrank(owner);
        // nothing to call: the usual withdraw/sweep/rescue selectors do not exist
        bytes[4] memory tries = [
            abi.encodeWithSignature("withdraw(uint256)", 1 ether),
            abi.encodeWithSignature("withdraw(address,address,uint256)", address(0), owner, 1 ether),
            abi.encodeWithSignature("sweep(address)", address(tok)),
            abi.encodeWithSignature("rescue(address,address,uint256)", address(tok), owner, 1e18)
        ];
        for (uint256 i; i < tries.length; ++i) {
            (bool ok,) = address(fc).call(tries[i]);
            assertFalse(ok);
        }
        // forwarding before a destination reverts, it never falls back to the owner
        vm.expectRevert(bytes("no destination"));
        fc.forwardETH();
        vm.expectRevert(bytes("no destination"));
        fc.forwardToken(address(tok));
        vm.stopPrank();
        assertEq(owner.balance, ob);
        assertEq(tok.balanceOf(owner), 0);
        assertEq(address(fc).balance, 5 ether);
    }

    function testFuzz_forwardAlwaysGoesToDestination(address caller, uint96 amount) public {
        vm.assume(caller != address(sink) && caller != address(fc) && amount > 0);
        vm.prank(owner);
        fc.setDestination(address(sink));
        vm.deal(address(fc), amount);
        uint256 cb = caller.balance;
        vm.prank(caller);
        fc.forwardETH();
        assertEq(address(sink).balance, amount);
        assertEq(address(fc).balance, 0);
        assertEq(caller.balance, cb);
    }

    // ---- receive never reverts ---------------------------------------------------------------

    function test_receive_neverReverts() public {
        vm.deal(address(this), 10 ether);
        // plain call, before and after a destination exists
        (bool ok,) = address(fc).call{value: 1 ether}("");
        assertTrue(ok);
        // 2300-gas stipend (transfer / send)
        payable(address(fc)).transfer(1 ether);
        assertTrue(payable(address(fc)).send(1 ether));
        vm.prank(owner);
        fc.setDestination(address(sink));
        (ok,) = address(fc).call{value: 1 ether, gas: 2300}("");
        assertTrue(ok);
        assertEq(address(fc).balance, 4 ether);
    }

    function testFuzz_receive(uint96 amount) public {
        vm.deal(address(this), amount);
        (bool ok,) = address(fc).call{value: amount}("");
        assertTrue(ok);
        assertEq(address(fc).balance, amount);
    }

    // ---- forwards --------------------------------------------------------------------------

    function test_forwardETH() public {
        vm.deal(address(fc), 3 ether);
        vm.prank(owner);
        fc.setDestination(address(sink));
        vm.expectEmit(true, true, false, true, address(fc));
        emit ForwardedETH(anyone, address(sink), 3 ether);
        vm.prank(anyone);
        assertEq(fc.forwardETH(), 3 ether);
        assertEq(address(sink).balance, 3 ether);
        assertEq(address(fc).balance, 0);
        vm.expectRevert(bytes("empty"));
        fc.forwardETH();
    }

    function test_forwardToken() public {
        tok.mint(address(fc), 42e18);
        vm.prank(owner);
        fc.setDestination(address(sink));
        vm.expectEmit(true, true, true, true, address(fc));
        emit ForwardedToken(anyone, address(tok), address(sink), 42e18);
        vm.prank(anyone);
        assertEq(fc.forwardToken(address(tok)), 42e18);
        assertEq(tok.balanceOf(address(sink)), 42e18);
        assertEq(tok.balanceOf(address(fc)), 0);
        vm.expectRevert(bytes("empty"));
        fc.forwardToken(address(tok));
    }

    function test_forwardETH_destinationRejects_reverts_fundsStay() public {
        RejectEth r = new RejectEth();
        vm.prank(owner);
        fc.setDestination(address(r));
        vm.deal(address(fc), 1 ether);
        vm.expectRevert(bytes("send"));
        fc.forwardETH();
        assertEq(address(fc).balance, 1 ether);
    }

    // ---- reentrancy ----------------------------------------------------------------------------

    function test_reentrancy_ETH() public {
        Reenterer r = new Reenterer();
        r.setFc(fc, address(0));
        vm.prank(owner);
        fc.setDestination(address(r));
        vm.deal(address(fc), 2 ether);
        fc.forwardETH();
        assertTrue(r.tried());
        assertFalse(r.reentryOk());
        assertEq(bytes4(r.reentryErr()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(address(r).balance, 2 ether);
        assertEq(address(fc).balance, 0);
    }

    function test_reentrancy_token() public {
        HookToken h = new HookToken();
        Reenterer r = new Reenterer();
        r.setFc(fc, address(h));
        vm.prank(owner);
        fc.setDestination(address(r));
        h.mint(address(fc), 7e18);
        fc.forwardToken(address(h));
        assertTrue(r.tried());
        assertFalse(r.reentryOk());
        assertEq(bytes4(r.reentryErr()), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(h.balanceOf(address(r)), 7e18);
    }

    // ---- integration: the product stack pays its fees here ------------------------------------

    function test_integration_sanctumQueuedFee_andSubscription() public {
        Blacklist bl = new Blacklist();
        FCFeed feed = new FCFeed();
        FCToken usdc = new FCToken();
        Subscription sub = new Subscription(address(feed), address(fc), address(usdc));
        SanctumFactory f = new SanctumFactory(address(bl), address(0), address(fc), address(sub));
        sub.setFactory(address(f));

        address hot = makeAddr("hot");
        address cold = makeAddr("cold");
        vm.deal(hot, 10 ether);
        address[] memory g = new address[](0);
        vm.prank(hot);
        Sanctum s = Sanctum(payable(f.create{value: 1 ether}(cold, g, 0)));
        assertEq(s.feeRouter(), address(fc));

        // ETH: 20% queues, executes after 6h, 0.25% lands in the collector
        vm.prank(hot);
        uint256 id = s.withdraw(address(0), hot, 0.2 ether);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hot);
        s.executeQueued(id);
        assertEq(address(fc).balance, 0.2 ether * 25 / 10_000);

        // ERC-20: fee in the moved asset
        tok.mint(hot, 1000e18);
        vm.startPrank(hot);
        tok.approve(address(s), 1000e18);
        s.deposit(address(tok), 1000e18);
        uint256 id2 = s.withdraw(address(tok), hot, 500e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 6 hours);
        vm.prank(cold);
        s.executeQueued(id2);
        assertEq(tok.balanceOf(address(fc)), 500e18 * 25 / 10_000);

        // Subscription pays ETH and USDC coverage here
        uint256 price = sub.priceWei(1);
        vm.prank(hot);
        sub.pay{value: price}(address(s), 1);
        usdc.mint(hot, 5e6);
        vm.startPrank(hot);
        usdc.approve(address(sub), 5e6);
        sub.payUsdc(address(s), 1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(fc)), 5e6);

        // later: the destination exists, anyone forwards
        uint256 ethFees = address(fc).balance;
        vm.prank(owner);
        fc.setDestination(address(sink));
        vm.startPrank(anyone);
        fc.forwardETH();
        fc.forwardToken(address(tok));
        fc.forwardToken(address(usdc));
        vm.stopPrank();
        assertEq(address(sink).balance, ethFees);
        assertEq(tok.balanceOf(address(sink)), 500e18 * 25 / 10_000);
        assertEq(usdc.balanceOf(address(sink)), 5e6);
    }
}

contract RejectEth {
    receive() external payable { revert("no"); }
}
