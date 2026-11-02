// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SanctumFactory} from "../src/SanctumFactory.sol";
import {BountySanctum} from "../src/BountySanctum.sol";
import {BountyCold} from "../src/BountyCold.sol";
import {Sanctum} from "../src/Sanctum.sol";
import {ChallengeRegistry} from "../src/challenges/ChallengeRegistry.sol";
import {Challenge} from "../src/challenges/Challenge.sol";
import {Level1} from "../src/challenges/Level1.sol";
import {Level2} from "../src/challenges/Level2.sol";
import {Level3} from "../src/challenges/Level3.sol";
import {Level4} from "../src/challenges/Level4.sol";

/// Raid stages on Base, standalone: the break-the-caps bounty
/// Sanctum and the weekly challenge levels. Needs ONLY the Sanctum product (script/DeployProduct.s.sol): it reads the
/// SanctumFactory from deployments/base-product.json and nothing else. Both
/// stages are funded with plain ETH from the deployer. The bounty Sanctum's fees (none in practice: its queue is off)
/// go to the product FeeCollector, because that is the factory's `feeRouter`.
///
///   STEP=bounty    forge script script/DeployRaid.s.sol --rpc-url $BASE_RPC --private-key $PK [--broadcast]
///   STEP=challenge LEVEL=1 PRIZE_WEI=… OPENS_AT=<unix ts> forge script script/DeployRaid.s.sol --rpc-url $BASE_RPC --private-key $PK [--broadcast]
///   STEP=verify    forge script script/DeployRaid.s.sol --rpc-url $BASE_RPC   (prints Basescan verify commands)
///   STEP=status    forge script script/DeployRaid.s.sol --rpc-url $BASE_RPC   (default)
///
/// Without --broadcast nothing is sent and nothing is written. Resumable: an address already on chain is skipped.
///
/// env:  PRODUCT_FILE=deployments/base-product.json   (read only: `factory`)
///       DEPLOYMENT_FILE=deployments/base-raid.json   (written by this script; read by raid- and challenge-indexer)
///   bounty:
///       BOUNTY_WEI=500000000000000000    prize sent in the creation tx (0.5 ETH)
///       BOUNTY_COLD_OWNER=0x…            owner of BountyCold (default: deployer; two-step hand-over to the Safe)
///       BOUNTY_GUARDIANS=0x…,0x…         admin-chosen guardians, 0–5 (they can only panic)
///       BOUNTY_THRESHOLD=0               0 = factory default (recovery is off on the bounty anyway)
///   challenge:
///       LEVEL=1..4 · PRIZE_WEI=<wei> · OPENS_AT=<unix ts> · CHALLENGE_OWNER=0x… (registry owner on first deploy)
contract DeployRaid is Script {
    string file;
    string json;
    address deployer;

    function run() external {
        require(block.chainid == 8453, "DeployRaid is Base only (chain 8453); an anvil fork must use --chain-id 8453");
        file = vm.envOr("DEPLOYMENT_FILE", string("deployments/base-raid.json"));
        _load();
        string memory step = vm.envOr("STEP", string("status"));
        if (_eq(step, "status")) { _status(); return; }
        if (_eq(step, "verify")) { _verify(); return; }
        require(_eq(step, "bounty") || _eq(step, "challenge"), "STEP must be bounty|challenge|verify|status");
        if (_eq(step, "bounty")) _factory(); // resolve the product factory before anything is broadcast
        vm.startBroadcast();
        (, deployer,) = vm.readCallers();
        console2.log("chain", block.chainid, "deployer", deployer);
        if (_eq(step, "bounty")) _bounty();
        else _challenge();
        vm.stopBroadcast();
        _status();
    }

    /// The SanctumFactory of the product deploy (deployments/base-product.json), checked on chain.
    function _factory() internal returns (address f) {
        f = _addr("factory");
        if (!_live(f)) {
            string memory pf = vm.envOr("PRODUCT_FILE", string("deployments/base-product.json"));
            require(vm.isFile(pf), "PRODUCT_FILE missing: run script/DeployProduct.s.sol first");
            string memory pj = vm.readFile(pf);
            require(vm.keyExistsJson(pj, ".factory"), "PRODUCT_FILE has no factory");
            f = vm.parseJsonAddress(pj, ".factory");
            require(_live(f), "no code at the product factory");
            _save("factory", f);
            _save("feeCollector", SanctumFactory(f).feeRouter());
        }
    }

    // ---- bounty: break-the-caps main vault -------------------------------------------------------------------

    function _bounty() internal {
        address factory = _factory();
        address coldOwner = vm.envOr("BOUNTY_COLD_OWNER", deployer);
        address[] memory guardians = vm.envOr("BOUNTY_GUARDIANS", ",", new address[](0));
        uint8 threshold = uint8(vm.envOr("BOUNTY_THRESHOLD", uint256(0)));
        uint256 prizeWei = vm.envOr("BOUNTY_WEI", uint256(0.5 ether));

        address cold = _addr("bountyCold");
        if (!_live(cold)) {
            require(deployer.balance > prizeWei, "not enough ETH for the prize");
            cold = address(new BountyCold{value: prizeWei}(coldOwner, factory, guardians, threshold));
            _save("bountyCold", cold);
            _save("bounty", address(BountyCold(cold).bounty()));
            _save("bountySanctum", address(BountyCold(cold).sanctum()));
            _saveUint("bountySeededAt", block.timestamp);
            _saveUint("bountySeededBlock", block.number);
            _save("ctorOwner_bountyCold", coldOwner);
            _put("bountyGuardians", _joinAddrs(guardians));
            _saveUint("bountyThreshold", threshold);
        }
        BountySanctum b = BountyCold(cold).bounty();
        Sanctum s = b.sanctum();
        require(s.owner() == address(b) && b.cold() == cold && s.cold() == cold, "bounty wiring");
        require(s.recoveryOff(), "bounty Sanctum: guardian recovery must be off");
        require(b.factory() == factory, "bounty made by another factory");
        if (b.prize() < prizeWei) b.topUp{value: prizeWei - b.prize()}(); // resume: a crashed first run left it short
        console2.log("bounty prize (wei)", b.prize(), "probe room now", b.probeRoom());
        console2.log("bounty withdraw: to must be the bounty Sanctum (every allowed outflow cycles back)");
        console2.log("bountyCold owner", BountyCold(cold).owner());
        console2.log("bounty Sanctum recoveryOff", s.recoveryOff());
    }

    // ---- challenge: one weekly level ------------------------------------------------------------------------

    function _challenge() internal {
        uint256 n = vm.envOr("LEVEL", uint256(0));
        require(n >= 1 && n <= 4, "set LEVEL=1..4");
        uint256 prizeWei = vm.envOr("PRIZE_WEI", uint256(0));
        uint256 opensAt = vm.envOr("OPENS_AT", uint256(0));
        require(prizeWei > 0, "set PRIZE_WEI=<wei> (the level's prize)");
        require(opensAt > 0 && opensAt < type(uint64).max, "set OPENS_AT=<unix timestamp>");

        address reg = _addr("challengeRegistry");
        if (!_live(reg)) {
            address owner_ = vm.envOr("CHALLENGE_OWNER", deployer);
            reg = address(new ChallengeRegistry(owner_));
            _save("challengeRegistry", reg);
            _save("ctorOwner_challengeRegistry", owner_);
            _saveUint("challengeRegistryBlock", block.number);
        }
        ChallengeRegistry r = ChallengeRegistry(reg);
        string memory k = string.concat("challengeL", vm.toString(n));
        address lvl = _addr(k);
        if (!_live(lvl)) {
            require(deployer.balance > prizeWei, "not enough ETH for the prize");
            if (n == 1) lvl = address(new Level1{value: prizeWei}(reg, uint64(opensAt)));
            else if (n == 2) lvl = address(new Level2{value: prizeWei}(reg, uint64(opensAt)));
            else if (n == 3) lvl = address(new Level3{value: prizeWei}(reg, uint64(opensAt)));
            else lvl = address(new Level4{value: prizeWei}(reg, uint64(opensAt)));
            _save(k, lvl);
            _saveUint(string.concat(k, "OpensAt"), opensAt);
            _saveUint(string.concat(k, "Prize"), prizeWei);
            _saveUint(string.concat(k, "Block"), block.number);
        } else {
            console2.log("level already deployed", lvl);
        }
        require(address(Challenge(lvl).registry()) == reg, "level points to another registry");
        if (r.levelOf(lvl) == 0) {
            require(r.owner() == deployer, "ChallengeRegistry owner must add the level");
            r.addLevel(lvl);
        }
        console2.log("level", n, lvl);
        console2.log("  registry id", r.levelOf(lvl), "prize (wei)", Challenge(lvl).prize());
        console2.log("  opensAt", uint256(Challenge(lvl).opensAt()));
    }

    // ---- verify / status ------------------------------------------------------------------------------------

    function _verify() internal view {
        console2.log("# Basescan verification (needs ETHERSCAN_API_KEY). Constructor inputs from the state file.");
        if (_live(_addr("bountyCold"))) {
            address[] memory g = _parseAddrs(_str("bountyGuardians"));
            uint8 th = uint8(_uint("bountyThreshold"));
            address f = _addr("factory");
            _v("bountyCold", "src/BountyCold.sol:BountyCold", abi.encode(_addr("ctorOwner_bountyCold"), f, g, th));
            _v("bounty", "src/BountySanctum.sol:BountySanctum", abi.encode(f, _addr("bountyCold"), g, th));
            _v("bountySanctum", "src/Sanctum.sol:Sanctum", abi.encode(
                _addr("bounty"), _addr("bountyCold"), SanctumFactory(f).blacklist(), SanctumFactory(f).watcherRegistry(),
                SanctumFactory(f).feeRouter(), g, th,
                Sanctum.Rules({capBps: 100, dayCapBps: 200, delayBps: 10_000, delay: 24 hours, allowlistOn: false})
            ));
        }
        if (_live(_addr("challengeRegistry"))) {
            _v("challengeRegistry", "src/challenges/ChallengeRegistry.sol:ChallengeRegistry", abi.encode(_addr("ctorOwner_challengeRegistry")));
            for (uint256 n = 1; n <= 4; n++) {
                string memory k = string.concat("challengeL", vm.toString(n));
                _v(k, string.concat("src/challenges/Level", vm.toString(n), ".sol:Level", vm.toString(n)),
                    abi.encode(_addr("challengeRegistry"), uint64(_uint(string.concat(k, "OpensAt")))));
            }
        }
    }

    function _v(string memory key, string memory path, bytes memory args) internal view {
        address a = _addr(key);
        if (!_live(a)) return;
        string memory solc = vm.envOr("SOLC_VERSION", string("v0.8.28+commit.7893614a"));
        console2.log(string.concat(
            "forge verify-contract --chain base --watch --compiler-version ", solc,
            " --evm-version prague --optimizer-runs 200 --constructor-args ", vm.toString(args), " ", vm.toString(a), " ", path
        ));
    }

    function _status() internal view {
        console2.log("state file:", file);
        address b = _addr("bounty");
        if (_live(b)) {
            BountySanctum bs = BountySanctum(payable(b));
            console2.log("  bounty", b, "sanctum", address(bs.sanctum()));
            console2.log("  bounty.prize", bs.prize(), "probeRoom", bs.probeRoom());
            console2.log("  bounty.attempts", bs.attempts(), "totalCycled", bs.totalCycled());
            console2.log("  bountySanctum.recoveryOff", bs.sanctum().recoveryOff());
        }
        address reg = _addr("challengeRegistry");
        if (_live(reg)) {
            ChallengeRegistry r = ChallengeRegistry(reg);
            console2.log("  challengeRegistry", reg, "levels", r.levelCount());
            for (uint256 i = 1; i <= r.levelCount(); i++) {
                ChallengeRegistry.Level memory l = r.level(i);
                console2.log(string.concat("  level ", vm.toString(i), " ", vm.toString(l.challenge), " prize ",
                    vm.toString(Challenge(l.challenge).prize()), " balance ", vm.toString(l.challenge.balance),
                    " opensAt ", vm.toString(uint256(l.opensAt)),
                    l.solvedBy == address(0) ? " unsolved" : string.concat(" SOLVED by ", vm.toString(l.solvedBy))));
            }
        }
    }

    // ---- state file (flat JSON, every value a string) ----------------------------

    function _load() internal {
        string memory old = vm.isFile(file) ? vm.readFile(file) : "{}";
        string[] memory keys = vm.parseJsonKeys(old, ".");
        json = "{}";
        for (uint256 i = 0; i < keys.length; i++) {
            json = vm.serializeString("raid", keys[i], vm.parseJsonString(old, string.concat(".", keys[i])));
        }
    }

    function _has(string memory k) internal view returns (bool) { return vm.keyExistsJson(json, string.concat(".", k)); }
    function _addr(string memory k) internal view returns (address) { return _has(k) ? vm.parseAddress(_str(k)) : address(0); }
    function _uint(string memory k) internal view returns (uint256) { return _has(k) ? vm.parseUint(_str(k)) : 0; }
    function _str(string memory k) internal view returns (string memory) { return _has(k) ? vm.parseJsonString(json, string.concat(".", k)) : ""; }
    function _live(address a) internal view returns (bool) { return a != address(0) && a.code.length > 0; }

    function _save(string memory k, address v) internal { console2.log(string.concat("  ", k), v); _put(k, vm.toString(v)); }
    function _saveUint(string memory k, uint256 v) internal { _put(k, vm.toString(v)); }

    function _put(string memory k, string memory v) internal {
        json = vm.serializeString("raid", k, v);
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) return;
        vm.writeJson(json, file);
    }

    function _joinAddrs(address[] memory a) internal pure returns (string memory out) {
        for (uint256 i = 0; i < a.length; i++) out = string.concat(out, i == 0 ? "" : ",", vm.toString(a[i]));
    }

    function _parseAddrs(string memory str) internal pure returns (address[] memory a) {
        if (bytes(str).length == 0) return new address[](0);
        string[] memory parts = vm.split(str, ",");
        a = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) a[i] = vm.parseAddress(parts[i]);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) { return keccak256(bytes(a)) == keccak256(bytes(b)); }
}
