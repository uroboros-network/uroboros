// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FeeBridge} from "../src/FeeBridge.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {SanctumFactory} from "../src/SanctumFactory.sol";
import {Subscription} from "../src/Subscription.sol";
import {DeploySanctumChain} from "../script/DeploySanctumChain.s.sol";
import {MockERC20} from "./Fixture.sol";

contract MockL1Bridge {
    address public lastTo;
    uint32 public lastGas;
    bytes public lastExtra;
    uint256 public lastValue;
    uint256 public calls;

    function depositETHTo(address _to, uint32 _minGasLimit, bytes calldata _extraData) external payable {
        lastTo = _to; lastGas = _minGasLimit; lastExtra = _extraData; lastValue = msg.value; calls++;
    }
}

/// Sanctums pay the fee with a plain call carrying all gas; a contract paying with 2300 gas (transfer) must work too.
contract StipendPayer {
    function pay(address to) external payable { payable(to).transfer(msg.value); }
}

contract FeeBridgeTest is Test {
    MockL1Bridge l1;
    FeeBridge fb;
    MockERC20 tok;
    address router = makeAddr("baseFeeRouter");
    address sink = makeAddr("ethSafe");

    function setUp() public {
        l1 = new MockL1Bridge();
        fb = new FeeBridge(address(l1), router, sink, 0.02 ether);
        tok = new MockERC20();
    }

    function test_constructor_checks() public {
        vm.expectRevert(bytes("bridge")); new FeeBridge(makeAddr("noCode"), router, sink, 1);
        vm.expectRevert(bytes("addr")); new FeeBridge(address(l1), address(0), sink, 1);
        vm.expectRevert(bytes("addr")); new FeeBridge(address(l1), router, address(0), 1);
        vm.expectRevert(bytes("min")); new FeeBridge(address(l1), router, sink, 0);
        assertEq(fb.minBridge(), 0.02 ether);
        assertEq(fb.MIN_GAS_LIMIT(), 200_000);
    }

    function test_receive_never_reverts_even_with_2300_gas() public {
        (bool ok,) = address(fb).call{value: 1 wei}("");
        assertTrue(ok);
        StipendPayer p = new StipendPayer();
        p.pay{value: 5 wei}(address(fb));
        assertEq(address(fb).balance, 6);
    }

    function test_bridge_below_min_reverts() public {
        vm.deal(address(fb), 0.02 ether - 1);
        vm.expectRevert(bytes("below min")); fb.bridge();
        assertEq(l1.calls(), 0);
    }

    function test_bridge_sends_whole_balance_to_base_feeRouter_anyone() public {
        vm.deal(address(fb), 0.5 ether);
        vm.prank(makeAddr("anyone"));
        assertEq(fb.bridge(), 0.5 ether);
        assertEq(l1.lastTo(), router);
        assertEq(l1.lastGas(), 200_000);
        assertEq(l1.lastExtra().length, 0);
        assertEq(l1.lastValue(), 0.5 ether);
        assertEq(address(fb).balance, 0);
        vm.expectRevert(bytes("below min")); fb.bridge(); // nothing left
    }

    function testFuzz_bridge_threshold(uint96 bal) public {
        vm.deal(address(fb), bal);
        if (bal < 0.02 ether) { vm.expectRevert(bytes("below min")); fb.bridge(); }
        else { fb.bridge(); assertEq(l1.lastValue(), bal); assertEq(address(fb).balance, 0); }
    }

    function test_forwardToken_to_sink_anyone() public {
        tok.mint(address(fb), 7e18);
        vm.prank(makeAddr("anyone"));
        assertEq(fb.forwardToken(address(tok)), 7e18);
        assertEq(tok.balanceOf(sink), 7e18);
        vm.expectRevert(bytes("empty")); fb.forwardToken(address(tok));
    }
}

/// Ethereum mainnet fork: the chain stage exactly as script/DeploySanctumChain.s.sol runs it, then a Sanctum with a
/// queued transfer whose 0.25% fee lands in FeeBridge, then bridge() through Base's real L1StandardBridge.
///   ETH_RPC=https://ethereum-rpc.publicnode.com forge test --match-contract EthForkTest
contract EthForkTest is Test {
    address constant L1_BRIDGE = 0x3154Cf16ccdb4C6d922629664174b904d80F2C35;
    address constant OPTIMISM_PORTAL = 0x49048044D57e1C92A77f79988d21Fa8fAF74E97e; // Base's portal on Ethereum
    string constant FILE = "deployments/test-eth-fork.json";
    address router = makeAddr("baseFeeRouter");
    address sink = makeAddr("ethSafe");

    event ETHDepositInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData);

    receive() external payable {} // Subscription refunds the excess

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC", string(""));
        if (bytes(rpc).length == 0) { vm.skip(true); return; }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 1, "not Ethereum");
    }

    function _deployStage() internal returns (string memory j) {
        if (vm.isFile(FILE)) vm.removeFile(FILE);
        vm.setEnv("DEPLOYMENT_FILE", FILE);
        vm.setEnv("STEP", "sanctum-chain");
        vm.setEnv("FEE_ROUTER_BASE", vm.toString(router));
        vm.setEnv("TOKEN_SINK", vm.toString(sink));
        DeploySanctumChain s = new DeploySanctumChain();
        s.run();
        j = vm.readFile(FILE);
        // re-run is a no-op (resumable)
        s = new DeploySanctumChain();
        s.run();
        assertEq(vm.readFile(FILE), j, "second run changes nothing");
        vm.removeFile(FILE);
    }

    function _a(string memory j, string memory k) internal pure returns (address) {
        return vm.parseAddress(vm.parseJsonString(j, string.concat(".", k)));
    }

    function test_eth_fork_stage_sanctum_fee_and_bridge() public {
        string memory j = _deployStage();
        FeeBridge fb = FeeBridge(payable(_a(j, "feeBridge")));
        SanctumFactory f = SanctumFactory(_a(j, "factory"));
        Subscription sub = Subscription(_a(j, "subscription"));
        assertEq(address(fb.l1Bridge()), L1_BRIDGE);
        assertEq(fb.feeRouterOnBase(), router);
        assertEq(f.feeRouter(), address(fb));
        assertEq(f.watcherRegistry(), address(0), "no watcher registry on Ethereum yet");
        assertEq(sub.feeRouter(), address(fb));
        assertEq(sub.factory(), address(f));
        assertEq(address(sub.feed()), 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
        assertEq(address(sub.usdc()), 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertGt(_a(j, "sanctum7702").code.length, 0);
        assertEq(vm.parseUint(vm.parseJsonString(j, ".chainId")), 1);

        // a user Sanctum with default rules: 10 ETH, withdraw 5 ETH (> 10%) → queued 6h → released, 0.25% fee
        address hot = makeAddr("eth.hot");
        address cold = makeAddr("eth.cold");
        address dest = makeAddr("eth.dest");
        vm.deal(hot, 11 ether);
        address[] memory g = new address[](0);
        vm.prank(hot);
        Sanctum s = Sanctum(payable(f.create{value: 10 ether}(cold, g, 0)));
        assertFalse(s.recoveryOff(), "personal Sanctum: recovery on by default");
        vm.prank(hot);
        uint256 id = s.withdraw(address(0), dest, 5 ether);
        assertEq(id, 0, "queued");
        vm.warp(block.timestamp + 6 hours);
        vm.prank(hot);
        s.executeQueued(id);
        uint256 fee = 5 ether * 25 / 10_000;
        assertEq(address(fb).balance, fee, "0.25% fee in FeeBridge");
        assertEq(dest.balance, 5 ether - fee);

        // below the 0.02 ETH threshold: refused
        vm.expectRevert(bytes("below min")); fb.bridge();

        // coverage paid in ETH on Ethereum also lands in FeeBridge
        uint256 before = address(fb).balance;
        vm.deal(address(this), 1 ether);
        sub.pay{value: 0.01 ether}(address(s), 1);
        assertGt(address(fb).balance, before, "subscription ETH to FeeBridge");

        // top up to the threshold and bridge through the REAL L1StandardBridge
        vm.deal(address(fb), address(fb).balance + 0.02 ether);
        uint256 amt = address(fb).balance;
        uint256 portalBefore = OPTIMISM_PORTAL.balance;
        vm.expectEmit(true, true, false, true, L1_BRIDGE);
        emit ETHDepositInitiated(address(fb), router, amt, "");
        vm.recordLogs();
        fb.bridge();
        assertEq(address(fb).balance, 0);
        assertEq(OPTIMISM_PORTAL.balance, portalBefore + amt, "ETH locked in Base's OptimismPortal");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool deposit;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == OPTIMISM_PORTAL && logs[i].topics[0] == keccak256("TransactionDeposited(address,address,uint256,bytes)")) deposit = true;
        }
        assertTrue(deposit, "TransactionDeposited emitted for Base");
    }
}
