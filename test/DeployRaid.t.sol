// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Blacklist} from "../src/Blacklist.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {Subscription} from "../src/Subscription.sol";
import {SanctumFactory} from "../src/SanctumFactory.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {BountySanctum} from "../src/BountySanctum.sol";
import {BountyCold} from "../src/BountyCold.sol";
import {ChallengeRegistry} from "../src/challenges/ChallengeRegistry.sol";
import {Challenge} from "../src/challenges/Challenge.sol";
import {DeployRaid} from "../script/DeployRaid.s.sol";
import {MockAggregator, MockUSDC} from "./Fixture.sol";

/// The raid stages stand alone on the PRODUCT stack (FeeCollector as the factory's
/// feeRouter). Only the Sanctum product exists in this test. script/DeployRaid.s.sol reads the
/// factory from a product file, deploys the bounty and a challenge level, and is resumable.
contract DeployRaidTest is Test {
    string constant PRODUCT = "deployments/test-raid-product.json";
    string constant RAID = "deployments/test-raid.json";
    address dev;
    FeeCollector fc;
    SanctumFactory factory;

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1_800_000_000);
        dev = address(this); // the script's broadcaster in tests is the caller
        Blacklist bl = new Blacklist();
        fc = new FeeCollector(dev);
        MockAggregator feed = new MockAggregator(3000e8);
        MockUSDC usdc = new MockUSDC();
        Subscription sub = new Subscription(address(feed), address(fc), address(usdc));
        factory = new SanctumFactory(address(bl), address(0), address(fc), address(sub));
        sub.setFactory(address(factory));
        if (vm.isFile(RAID)) vm.removeFile(RAID);
        vm.writeFile(PRODUCT, string.concat('{"factory":"', vm.toString(address(factory)), '","feeCollector":"', vm.toString(address(fc)), '"}'));
        vm.setEnv("PRODUCT_FILE", PRODUCT);
        vm.setEnv("DEPLOYMENT_FILE", RAID);
    }

    function _run(string memory step) internal returns (string memory j) {
        vm.setEnv("STEP", step);
        DeployRaid s = new DeployRaid();
        vm.deal(DEFAULT_SENDER, 10 ether); // forge's default broadcaster in tests
        s.run();
        j = vm.readFile(RAID);
    }

    function _a(string memory j, string memory k) internal pure returns (address) {
        return vm.parseAddress(vm.parseJsonString(j, string.concat(".", k)));
    }

    /// One test (vm.setEnv is process-wide; parallel tests would race on it).
    function test_raid_stages_on_the_product_stack_only() public {
        // without the product deploy the stage refuses and sends nothing
        vm.setEnv("PRODUCT_FILE", "deployments/does-not-exist.json");
        vm.setEnv("STEP", "bounty");
        DeployRaid s0 = new DeployRaid();
        vm.expectRevert(bytes("PRODUCT_FILE missing: run script/DeployProduct.s.sol first"));
        s0.run();
        vm.setEnv("PRODUCT_FILE", PRODUCT);

        vm.setEnv("BOUNTY_WEI", "500000000000000000");
        string memory j = _run("bounty");
        assertEq(_a(j, "factory"), address(factory));
        assertEq(_a(j, "feeCollector"), address(fc), "fees of the bounty Sanctum go to the product FeeCollector");
        BountyCold bc = BountyCold(_a(j, "bountyCold"));
        BountySanctum b = BountySanctum(payable(_a(j, "bounty")));
        Sanctum s = Sanctum(payable(_a(j, "bountySanctum")));
        assertEq(address(b.sanctum()), address(s));
        assertEq(s.cold(), address(bc));
        assertTrue(s.recoveryOff());
        assertEq(b.prize(), 0.5 ether);
        assertEq(b.factory(), address(factory));
        // resumable: a second run changes nothing
        assertEq(_run("bounty"), j, "second bounty run changes nothing");
        // probes cycle back on the product stack too
        address prober = makeAddr("prober");
        uint256 room = b.probeRoom();
        vm.prank(prober); vm.expectRevert(bytes("to")); b.withdraw(address(0), prober, room);
        vm.prank(prober); b.withdraw(address(0), address(s), room);
        assertEq(b.prize(), 0.5 ether);
        assertEq(address(fc).balance, 0, "no fee charged on a probe");

        // challenge level, same file, no token stack
        vm.setEnv("LEVEL", "2");
        vm.setEnv("PRIZE_WEI", "100000000000000000");
        vm.setEnv("OPENS_AT", vm.toString(block.timestamp + 1 days));
        j = _run("challenge");
        ChallengeRegistry r = ChallengeRegistry(_a(j, "challengeRegistry"));
        address l2 = _a(j, "challengeL2");
        assertEq(r.levelOf(l2), 1);
        assertEq(Challenge(l2).prize(), 0.1 ether);
        assertEq(Challenge(l2).opensAt(), block.timestamp + 1 days);
        assertEq(_run("challenge"), j, "second challenge run changes nothing");
        assertEq(r.levelCount(), 1);

        vm.removeFile(RAID);
        vm.removeFile(PRODUCT);
    }
}
