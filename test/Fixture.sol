// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {SanctumFactory} from "../src/SanctumFactory.sol";
import {Subscription} from "../src/Subscription.sol";
import {Blacklist} from "../src/Blacklist.sol";

/// Chainlink AggregatorV3 stand-in: 8 decimals like the Base ETH/USD feed.
contract MockAggregator {
    uint8 public decimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    constructor(int256 a) { answer = a; updatedAt = block.timestamp; }
    function set(int256 a, uint256 t) external { answer = a; updatedAt = t; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// Watcher registry stand-in (step 5 ships the real one).
contract MockWatcherRegistry {
    mapping(address => bool) public isWatcher;
    function set(address a, bool on) external { isWatcher[a] = on; }
}

/// Plain payable sink standing in for the fee destination.
contract FeeSink {
    uint256 public received;
    receive() external payable { received += msg.value; }
}

/// A fee router that refuses ETH: used to document the honest limit on executeQueued.
contract RejectingSink {
    receive() external payable { revert("no"); }
}

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// USDC stand-in: 6 decimals.
contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

/// Shared fixture: blacklist + subscription (mock feed) + factory + fee sink + watcher registry, no fork.
abstract contract Fixture is Test {
    address deployer = makeAddr("deployer");
    address hot = makeAddr("hot");
    address cold = makeAddr("cold");
    address g1 = makeAddr("g1");
    address g2 = makeAddr("g2");
    address g3 = makeAddr("g3");
    address g4 = makeAddr("g4");
    address g5 = makeAddr("g5");
    address watcher = makeAddr("watcher");
    Blacklist blacklist;
    Subscription sub;
    SanctumFactory factory;
    FeeSink feeRouter;
    MockAggregator feed;
    MockWatcherRegistry registry;
    MockERC20 token;
    MockUSDC usdc;
    uint256 t0;

    int256 constant ETH_USD = 3000e8; // $3000, 8 decimals

    function _base() internal {
        vm.warp(1_800_000_000);
        t0 = block.timestamp;
        vm.startPrank(deployer);
        blacklist = new Blacklist();
        feeRouter = new FeeSink();
        feed = new MockAggregator(ETH_USD);
        registry = new MockWatcherRegistry();
        usdc = new MockUSDC();
        sub = new Subscription(address(feed), address(feeRouter), address(usdc));
        factory = new SanctumFactory(address(blacklist), address(registry), address(feeRouter), address(sub));
        sub.setFactory(address(factory));
        token = new MockERC20();
        vm.stopPrank();
        registry.set(watcher, true);
    }

    function _none() internal pure returns (address[] memory g) { g = new address[](0); }
    function _one() internal view returns (address[] memory g) { g = new address[](1); g[0] = g1; }
    function _three() internal view returns (address[] memory g) { g = new address[](3); g[0] = g1; g[1] = g2; g[2] = g3; }
    function _five() internal view returns (address[] memory g) {
        g = new address[](5); g[0] = g1; g[1] = g2; g[2] = g3; g[3] = g4; g[4] = g5;
    }

    /// Default Sanctum: hot = `hot`, cold = `cold`, one guardian (g1), 100 ETH deposited in the creation tx
    /// (so it qualifies for the 7-day trial: $300k ≥ $100).
    function _sanctum() internal returns (Sanctum s) { return _sanctumWith(_one(), 0); }

    function _sanctumWith(address[] memory g, uint8 threshold) internal returns (Sanctum s) {
        vm.deal(hot, hot.balance + 100 ether);
        vm.prank(hot);
        s = Sanctum(payable(factory.create{value: 100 ether}(cold, g, threshold)));
    }

    /// A Sanctum created empty (no deposit in the creation tx): registered, no trial.
    function _emptySanctum() internal returns (Sanctum s) {
        vm.prank(hot);
        s = Sanctum(payable(factory.create(cold, _one(), 0)));
    }

    function _defaults() internal pure returns (Sanctum.Rules memory) {
        return Sanctum.Rules({capBps: 500, dayCapBps: 1000, delayBps: 1000, delay: 6 hours, allowlistOn: false});
    }

    /// Fee on a queued gross amount, as the contract computes it.
    function _fee(uint256 amount) internal pure returns (uint256) { return amount * 25 / 10_000; }
}
