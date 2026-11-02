// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Blacklist} from "../src/Blacklist.sol";
import {Subscription} from "../src/Subscription.sol";
import {SanctumFactory} from "../src/SanctumFactory.sol";
import {Sanctum7702} from "../src/Sanctum7702.sol";
import {FeeBridge} from "../src/FeeBridge.sol";

/// Sanctum stack on a chain other than Base (Ethereum mainnet first). This chain gets only what a user needs to run a
/// Sanctum; its ETH fees are bridged to a fee destination on Base by FeeBridge.
///
///   STEP=sanctum-chain  forge script script/DeploySanctumChain.s.sol --rpc-url $ETH_RPC --private-key $PK [--broadcast]
///   STEP=verify         forge script script/DeploySanctumChain.s.sol --rpc-url $ETH_RPC   (prints Etherscan verify commands)
///   STEP=status         forge script script/DeploySanctumChain.s.sol --rpc-url $ETH_RPC
///
/// Order: FeeBridge (local feeRouter) → Blacklist → Subscription(feed, FeeBridge, USDC) → SanctumFactory(blacklist,
/// no watcher registry, FeeBridge, subscription) → Subscription.setFactory → Sanctum7702. Resumable: each address is
/// saved as soon as it exists and skipped on a re-run if it has code. Without --broadcast nothing is sent or written.
///
/// env:  FEE_ROUTER_BASE=0x…  fee destination on Base that FeeBridge bridges ETH to (REQUIRED, no default)
///       TOKEN_SINK=0x…       where ERC-20 fees on this chain are forwarded (REQUIRED; the team's Safe on this chain)
///       MIN_BRIDGE_WEI=20000000000000000   bridge() threshold (default 0.02 ETH)
///       L1_BRIDGE=0x3154Cf16ccdb4C6d922629664174b904d80F2C35   Base L1StandardBridge proxy (default on chain 1 only)
///       ETH_USD_FEED=0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419  Chainlink ETH/USD (default on chain 1 only)
///       USDC=0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48          USDC (default on chain 1 only)
///       DEPLOYMENT_FILE=deployments/<chainId>.json
contract DeploySanctumChain is Script {
    string file;
    string json;
    address deployer;

    function run() external {
        file = vm.envOr("DEPLOYMENT_FILE", string.concat("deployments/", vm.toString(block.chainid), ".json"));
        require(block.chainid != 8453, "Base runs script/DeployProduct.s.sol");
        _load();
        string memory step = vm.envOr("STEP", string("status"));
        if (_eq(step, "status")) { _status(); return; }
        if (_eq(step, "verify")) { _verify(); return; }
        require(_eq(step, "sanctum-chain"), "STEP must be sanctum-chain|verify|status");

        (address bridgeAddr, address router, address sink, uint256 minBridge, address feed, address usdc) = _inputs();

        vm.startBroadcast();
        (, deployer,) = vm.readCallers();
        console2.log("chain", block.chainid, "deployer", deployer);
        console2.log("deployer nonce", vm.getNonce(deployer));
        if (sink.code.length == 0) console2.log("WARNING: TOKEN_SINK has no code (EOA):", sink);

        address fb = _addr("feeBridge");
        if (!_live(fb)) {
            fb = address(new FeeBridge(bridgeAddr, router, sink, minBridge));
            _save("feeBridge", fb);
            _saveUint("chainId", block.chainid);
            _saveUint("deployedAt", block.timestamp);
            _saveUint("deployedBlock", block.number);
            _save("feeRouterBase", router);
            _save("l1Bridge", bridgeAddr);
            _save("tokenSink", sink);
            _saveUint("minBridge", minBridge);
            _save("ethUsdFeed", feed);
            _save("usdc", usdc);
        }
        FeeBridge b = FeeBridge(payable(fb));
        require(address(b.l1Bridge()) == bridgeAddr && b.feeRouterOnBase() == router, "FeeBridge wired elsewhere");

        address bl = _addr("blacklist");
        if (!_live(bl)) { bl = address(new Blacklist()); _save("blacklist", bl); }

        address sub = _addr("subscription");
        if (!_live(sub)) { sub = address(new Subscription(feed, fb, usdc)); _save("subscription", sub); }

        address factory = _addr("factory");
        if (!_live(factory)) {
            factory = address(new SanctumFactory(bl, address(0), fb, sub)); // no watcher registry on this chain yet
            _save("factory", factory);
        }
        if (Subscription(sub).factory() == address(0)) Subscription(sub).setFactory(factory);
        require(Subscription(sub).factory() == factory, "subscription bound to another factory");

        address d7702 = _addr("sanctum7702");
        if (!_live(d7702)) { d7702 = address(new Sanctum7702()); _save("sanctum7702", d7702); }
        vm.stopBroadcast();

        require(SanctumFactory(factory).feeRouter() == fb && Subscription(sub).feeRouter() == fb, "fees must go to FeeBridge");
        console2.log("feeBridge -> Base fee destination", router, "min (wei)", minBridge);
        console2.log("sanctum chain ready: factory", factory);
    }

    function _inputs()
        internal
        view
        returns (address bridgeAddr, address router, address sink, uint256 minBridge, address feed, address usdc)
    {
        bool eth = block.chainid == 1;
        bridgeAddr = vm.envOr("L1_BRIDGE", eth ? address(0x3154Cf16ccdb4C6d922629664174b904d80F2C35) : address(0));
        feed = vm.envOr("ETH_USD_FEED", eth ? address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419) : address(0));
        usdc = vm.envOr("USDC", eth ? address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) : address(0));
        router = vm.envOr("FEE_ROUTER_BASE", address(0));
        sink = vm.envOr("TOKEN_SINK", address(0));
        minBridge = vm.envOr("MIN_BRIDGE_WEI", uint256(0.02 ether));
        string memory missing;
        if (router == address(0)) missing = string.concat(missing, " FEE_ROUTER_BASE");
        if (sink == address(0)) missing = string.concat(missing, " TOKEN_SINK");
        if (bridgeAddr == address(0)) missing = string.concat(missing, " L1_BRIDGE");
        if (feed == address(0)) missing = string.concat(missing, " ETH_USD_FEED");
        if (usdc == address(0)) missing = string.concat(missing, " USDC");
        if (bytes(missing).length > 0) {
            console2.log(string.concat("MISSING env:", missing));
            revert("missing env, nothing sent");
        }
        require(bridgeAddr.code.length > 0 && feed.code.length > 0 && usdc.code.length > 0, "no code at L1_BRIDGE / ETH_USD_FEED / USDC");
    }

    // ---- verify / status -------------------------------------------------------------------------------------

    function _verify() internal view {
        console2.log("# Etherscan verification (needs ETHERSCAN_API_KEY). Constructor inputs from the state file.");
        _v("feeBridge", "src/FeeBridge.sol:FeeBridge",
            abi.encode(_addr("l1Bridge"), _addr("feeRouterBase"), _addr("tokenSink"), _uint("minBridge")));
        _v("blacklist", "src/Blacklist.sol:Blacklist", "");
        _v("subscription", "src/Subscription.sol:Subscription", abi.encode(_addr("ethUsdFeed"), _addr("feeBridge"), _addr("usdc")));
        _v("factory", "src/SanctumFactory.sol:SanctumFactory",
            abi.encode(_addr("blacklist"), address(0), _addr("feeBridge"), _addr("subscription")));
        _v("sanctum7702", "src/Sanctum7702.sol:Sanctum7702", "");
    }

    function _v(string memory key, string memory path, bytes memory args) internal view {
        address a = _addr(key);
        if (!_live(a)) return;
        string memory solc = vm.envOr("SOLC_VERSION", string("v0.8.28+commit.7893614a"));
        string memory chain = vm.envOr("VERIFY_CHAIN", block.chainid == 1 ? string("mainnet") : vm.toString(block.chainid));
        console2.log(string.concat(
            "forge verify-contract --chain ", chain, " --watch --compiler-version ", solc,
            " --evm-version prague --optimizer-runs 200",
            args.length > 0 ? string.concat(" --constructor-args ", vm.toString(args)) : "",
            " ", vm.toString(a), " ", path
        ));
    }

    function _status() internal view {
        console2.log("state file:", file);
        string[5] memory ks = ["feeBridge", "blacklist", "subscription", "factory", "sanctum7702"];
        for (uint256 i; i < 5; ++i) {
            address a = _addr(ks[i]);
            console2.log(string.concat("  ", ks[i]), a, _live(a) ? "code" : "NO CODE");
        }
        address fb = _addr("feeBridge");
        if (_live(fb)) console2.log("  feeBridge balance (wei)", fb.balance, "min", FeeBridge(payable(fb)).minBridge());
    }

    // ---- state file (flat JSON, every value a string) -----------------------------------------------------------

    function _load() internal {
        string memory old = vm.isFile(file) ? vm.readFile(file) : "{}";
        string[] memory keys = vm.parseJsonKeys(old, ".");
        json = "{}";
        for (uint256 i = 0; i < keys.length; i++) {
            json = vm.serializeString("chainDeployment", keys[i], vm.parseJsonString(old, string.concat(".", keys[i])));
        }
    }

    function _has(string memory k) internal view returns (bool) { return vm.keyExistsJson(json, string.concat(".", k)); }

    function _addr(string memory k) internal view returns (address) {
        return _has(k) ? vm.parseAddress(vm.parseJsonString(json, string.concat(".", k))) : address(0);
    }

    function _uint(string memory k) internal view returns (uint256) {
        return _has(k) ? vm.parseUint(vm.parseJsonString(json, string.concat(".", k))) : 0;
    }

    function _live(address a) internal view returns (bool) { return a != address(0) && a.code.length > 0; }

    function _save(string memory k, address v) internal {
        console2.log(string.concat("  ", k), v);
        _put(k, vm.toString(v));
    }

    function _saveUint(string memory k, uint256 v) internal { _put(k, vm.toString(v)); }

    function _put(string memory k, string memory v) internal {
        json = vm.serializeString("chainDeployment", k, v);
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) return;
        vm.writeJson(json, file);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) { return keccak256(bytes(a)) == keccak256(bytes(b)); }
}
