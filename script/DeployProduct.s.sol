// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Blacklist} from "../src/Blacklist.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {Subscription} from "../src/Subscription.sol";
import {SanctumFactory} from "../src/SanctumFactory.sol";
import {Sanctum7702} from "../src/Sanctum7702.sol";

interface IFeedInfo {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IErc20Info {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

/// The Sanctum PRODUCT on Base: only what a user needs to run a Sanctum. Every fee (0.25% queued-transfer fee,
/// coverage payments) goes to FeeCollector, which forwards to a destination once its owner names it (write-once).
///
///   STEP=deploy   forge script script/DeployProduct.s.sol --rpc-url $BASE_RPC --private-key $PK [--broadcast [--verify]]
///   STEP=verify   forge script script/DeployProduct.s.sol --rpc-url $BASE_RPC   (prints forge verify-contract commands)
///   STEP=status   forge script script/DeployProduct.s.sol --rpc-url $BASE_RPC   (default)
///
/// Order: Blacklist → FeeCollector(owner) → Subscription(ETH/USD feed, FeeCollector, USDC) → SanctumFactory(blacklist,
/// watcherRegistry = 0, FeeCollector, subscription) → Subscription.setFactory(factory) → Sanctum7702.
/// Resumable: each address is saved to the deployment file as soon as it exists and skipped on a re-run when it has
/// code. Without --broadcast nothing is sent and nothing is written. Any wiring mismatch aborts with a message.
///
/// env:  DEPLOYMENT_FILE=deployments/base-product.json
///       ETH_USD_FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70   Chainlink ETH/USD on Base (8 decimals)
///       USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913           native USDC on Base (6 decimals)
///       FEE_COLLECTOR_OWNER=0x…   initial owner of FeeCollector (default: the deployer; Ownable2Step afterwards)
///       SOLC_VERSION=v0.8.28+commit.7893614a   STEP=verify override (default: read from the deployed bytecode)
contract DeployProduct is Script {
    address constant BASE_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    string file;
    // deployment state (all optional until deployed)
    address blacklist;
    address feeCollector;
    address subscription;
    address factory;
    address sanctum7702;
    address feed;
    address usdc;
    address ctorOwnerFc; // FeeCollector constructor owner (EOA; `ctorOwner_` prefix is skipped by site/verify.sh)
    uint256 deployedAt;
    uint256 deployedBlock;

    function run() external {
        require(block.chainid == 8453, "DeployProduct is Base only (chain 8453); an anvil fork must use --chain-id 8453");
        file = vm.envOr("DEPLOYMENT_FILE", string("deployments/base-product.json"));
        _load();
        string memory step = vm.envOr("STEP", string("status"));
        if (_eq(step, "status")) { _status(); return; }
        if (_eq(step, "verify")) { _verify(); return; }
        require(_eq(step, "deploy"), "STEP must be deploy | verify | status");
        _deploy();
    }

    // ---- deploy -------------------------------------------------------------------------------------------

    function _deploy() internal {
        address f = vm.envOr("ETH_USD_FEED", BASE_FEED);
        address u = vm.envOr("USDC", BASE_USDC);
        _checkInputs(f, u);
        if (feed != address(0)) require(feed == f, "deployment file was made with another ETH_USD_FEED: abort");
        if (usdc != address(0)) require(usdc == u, "deployment file was made with another USDC: abort");
        feed = f;
        usdc = u;

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address fcOwner = vm.envOr("FEE_COLLECTOR_OWNER", deployer);
        console2.log("chain", block.chainid);
        console2.log("deployer", deployer);
        console2.log("deployer nonce", vm.getNonce(deployer));
        console2.log("deployer balance (wei)", deployer.balance);

        if (!_live(blacklist)) { blacklist = address(new Blacklist()); _stamp(); _save("blacklist", blacklist); }
        if (!_live(feeCollector)) {
            feeCollector = address(new FeeCollector(fcOwner));
            ctorOwnerFc = fcOwner;
            _stamp();
            _save("feeCollector", feeCollector);
        }
        if (!_live(subscription)) {
            subscription = address(new Subscription(feed, feeCollector, usdc));
            _stamp();
            _save("subscription", subscription);
        }
        if (!_live(factory)) {
            factory = address(new SanctumFactory(blacklist, address(0), feeCollector, subscription));
            _stamp();
            _save("factory", factory);
        }
        Subscription sub = Subscription(subscription);
        if (sub.factory() == address(0)) {
            require(sub.deployer() == deployer, "Subscription was deployed by another key: only it can setFactory. Use that key.");
            sub.setFactory(factory);
            console2.log("  subscription.setFactory", factory);
        }
        if (!_live(sanctum7702)) { sanctum7702 = address(new Sanctum7702()); _stamp(); _save("sanctum7702", sanctum7702); }
        vm.stopBroadcast();

        _checkWiring(true);
        console2.log("product live on Base: factory", factory);
        console2.log("deployment file", file);
    }

    function _checkInputs(address f, address u) internal view {
        require(f.code.length > 0, string.concat("ETH_USD_FEED ", vm.toString(f), " has no code on this chain: abort"));
        require(u.code.length > 0, string.concat("USDC ", vm.toString(u), " has no code on this chain: abort"));
        require(IFeedInfo(f).decimals() == 8, "ETH_USD_FEED decimals != 8: abort");
        (, int256 ans,, uint256 upd,) = IFeedInfo(f).latestRoundData();
        require(ans > 0, "ETH_USD_FEED answer <= 0: abort");
        require(upd <= block.timestamp && block.timestamp - upd <= 24 hours, "ETH_USD_FEED is stale (> 24h): abort");
        require(IErc20Info(u).decimals() == 6, "USDC decimals != 6: abort");
        require(_eq(IErc20Info(u).symbol(), "USDC"), "USDC symbol is not USDC: abort");
        console2.log("feed", f, IFeedInfo(f).description());
        console2.log("  ETH/USD (8 dec)", uint256(ans), "updated", upd);
        console2.log("usdc", u, "decimals 6");
    }

    /// Every immutable and one-shot setting must point where this file says. `strict` aborts, otherwise it prints.
    function _checkWiring(bool strict) internal view returns (bool ok) {
        ok = true;
        SanctumFactory fa = SanctumFactory(factory);
        Subscription sub = Subscription(subscription);
        ok = _w(ok, strict, fa.blacklist() == blacklist, "factory.blacklist != blacklist");
        ok = _w(ok, strict, fa.watcherRegistry() == address(0), "factory.watcherRegistry != address(0)");
        ok = _w(ok, strict, fa.feeRouter() == feeCollector, "factory.feeRouter != feeCollector");
        ok = _w(ok, strict, fa.subscription() == subscription, "factory.subscription != subscription");
        ok = _w(ok, strict, sub.factory() == factory, "subscription.factory != factory (bound to another factory?)");
        ok = _w(ok, strict, sub.feeRouter() == feeCollector, "subscription.feeRouter != feeCollector");
        ok = _w(ok, strict, address(sub.feed()) == feed, "subscription.feed != ETH_USD_FEED");
        ok = _w(ok, strict, sub.feedDecimals() == 8, "subscription.feedDecimals != 8");
        ok = _w(ok, strict, address(sub.usdc()) == usdc, "subscription.usdc != USDC");
        address d = FeeCollector(payable(feeCollector)).destination();
        ok = _w(ok, strict, d == address(0) || d.code.length > 0, "feeCollector.destination has no code");
        ok = _w(ok, strict, _live(sanctum7702), "sanctum7702 has no code");
    }

    function _w(bool ok, bool strict, bool cond, string memory what) internal pure returns (bool) {
        if (cond) return ok;
        if (strict) revert(string.concat("WIRING MISMATCH: ", what, " -- abort, nothing after this point is trusted"));
        console2.log("  WIRING MISMATCH:", what);
        return false;
    }

    // ---- verify / status ----------------------------------------------------------------------------------

    function _verify() internal view {
        console2.log("# Basescan verification: export ETHERSCAN_API_KEY (an Etherscan v2 key covers Base) and run each line.");
        _v(blacklist, "src/Blacklist.sol:Blacklist", "");
        if (_live(feeCollector)) {
            _v(feeCollector, "src/FeeCollector.sol:FeeCollector", abi.encode(_ctorOwner()));
        }
        _v(subscription, "src/Subscription.sol:Subscription", abi.encode(feed, feeCollector, usdc));
        _v(factory, "src/SanctumFactory.sol:SanctumFactory", abi.encode(blacklist, address(0), feeCollector, subscription));
        _v(sanctum7702, "src/Sanctum7702.sol:Sanctum7702", "");
    }

    /// FeeCollector's constructor owner: from the deployment file, else the current owner (right if never transferred).
    function _ctorOwner() internal view returns (address o) {
        o = ctorOwnerFc;
        if (o == address(0)) o = FeeCollector(payable(feeCollector)).owner();
    }

    function _v(address a, string memory path, bytes memory args) internal view {
        if (!_live(a)) { console2.log("# skip (no code):", path); return; }
        (string memory solc, string memory evm) = _compiler(a);
        console2.log(string.concat(
            "forge verify-contract --chain base --watch --compiler-version ", solc,
            " --evm-version ", evm, " --optimizer-runs 200",
            args.length > 0 ? string.concat(" --constructor-args ", vm.toString(args)) : "",
            " ", vm.toString(a), " ", path
        ));
    }

    /// The solc version is in the CBOR metadata at the end of the runtime code: …64 'solc' 43 <maj> <min> <patch> <len:2>.
    function _compiler(address a) internal view returns (string memory solc, string memory evm) {
        solc = vm.envOr("SOLC_VERSION", string(""));
        bytes memory c = a.code;
        uint256 n = c.length;
        uint8 minor = uint8(c[n - 4]);
        uint8 patch = uint8(c[n - 3]);
        if (bytes(solc).length == 0) {
            require(uint8(c[n - 5]) == 0 && minor == 8, "cannot read solc version from bytecode: set SOLC_VERSION");
            string memory commit = patch == 24 ? "e11b9ed9" : patch == 25 ? "b61c2a91" : patch == 26 ? "8a97fa7a"
                : patch == 27 ? "40a35a09" : patch == 28 ? "7893614a" : patch == 29 ? "ab55807c" : patch == 30 ? "73712a01" : "";
            require(bytes(commit).length > 0, "unknown solc patch version in bytecode: set SOLC_VERSION");
            solc = string.concat("v0.8.", vm.toString(patch), "+commit.", commit);
        }
        // foundry.toml asks for prague; solc older than 0.8.28 is silently built for cancun
        evm = vm.envOr("EVM_VERSION", string(patch >= 28 ? "prague" : "cancun"));
    }

    function _status() internal view {
        console2.log("state file:", file);
        _line("blacklist", blacklist);
        _line("feeCollector", feeCollector);
        _line("subscription", subscription);
        _line("factory", factory);
        _line("sanctum7702", sanctum7702);
        _line("ethUsdFeed", feed);
        _line("usdc", usdc);
        if (!_live(factory) || !_live(subscription) || !_live(feeCollector) || !_live(blacklist)) {
            console2.log("status: NOT COMPLETE (run STEP=deploy)");
            return;
        }
        bool ok = _checkWiring(false);
        FeeCollector fc = FeeCollector(payable(feeCollector));
        console2.log("  feeCollector owner", fc.owner(), "pending", fc.pendingOwner());
        console2.log("  feeCollector destination", fc.destination());
        console2.log("  feeCollector ETH (wei)", feeCollector.balance);
        console2.log("  feeCollector USDC (6 dec)", _bal(usdc, feeCollector));
        console2.log("  sanctums created", SanctumFactory(factory).count());
        console2.log("  coverage price (wei/month)", _price());
        console2.log("  blacklist owner", Blacklist(blacklist).owner());
        console2.log(ok ? "status: OK, wiring matches" : "status: WIRING MISMATCH (see above)");
    }

    function _price() internal view returns (uint256 p) {
        try Subscription(subscription).monthlyPriceWei() returns (uint256 x) { p = x; } catch { p = 0; }
    }

    function _bal(address t, address who) internal view returns (uint256 b) {
        (bool ok, bytes memory r) = t.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        if (ok && r.length >= 32) b = abi.decode(r, (uint256));
    }

    function _line(string memory k, address a) internal view {
        console2.log(string.concat("  ", k), a, a == address(0) ? "-" : _live(a) ? "code" : "NO CODE");
    }

    // ---- deployment file ------------------------------------------------------------------------------------
    // Flat keys the site's app.js / sanctum.js read (factory, subscription, blacklist, sanctum7702, chainId, deployedAt).
    // Only contract addresses are stored, so site/verify.sh's "every address has code" check passes on a copy.

    function _load() internal {
        if (!vm.isFile(file)) return;
        string memory j = vm.readFile(file);
        if (vm.keyExistsJson(j, ".chainId")) require(vm.parseJsonUint(j, ".chainId") == block.chainid, "deployment file is for another chain: abort");
        blacklist = _ja(j, "blacklist");
        feeCollector = _ja(j, "feeCollector");
        subscription = _ja(j, "subscription");
        factory = _ja(j, "factory");
        sanctum7702 = _ja(j, "sanctum7702");
        feed = _ja(j, "ethUsdFeed");
        usdc = _ja(j, "usdc");
        ctorOwnerFc = _ja(j, "ctorOwner_feeCollector");
        if (vm.keyExistsJson(j, ".deployedAt")) deployedAt = vm.parseJsonUint(j, ".deployedAt");
        if (vm.keyExistsJson(j, ".deployedBlock")) deployedBlock = vm.parseJsonUint(j, ".deployedBlock");
    }

    function _ja(string memory j, string memory k) internal view returns (address) {
        string memory p = string.concat(".", k);
        return vm.keyExistsJson(j, p) ? vm.parseJsonAddress(j, p) : address(0);
    }

    function _stamp() internal {
        if (deployedAt == 0) { deployedAt = block.timestamp; deployedBlock = block.number; }
    }

    function _save(string memory k, address v) internal {
        console2.log(string.concat("  ", k), v);
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) return;
        string memory o = "product";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "deployedAt", deployedAt);
        vm.serializeUint(o, "deployedBlock", deployedBlock);
        if (blacklist != address(0)) vm.serializeAddress(o, "blacklist", blacklist);
        if (feeCollector != address(0)) vm.serializeAddress(o, "feeCollector", feeCollector);
        if (subscription != address(0)) vm.serializeAddress(o, "subscription", subscription);
        if (factory != address(0)) vm.serializeAddress(o, "factory", factory);
        if (sanctum7702 != address(0)) vm.serializeAddress(o, "sanctum7702", sanctum7702);
        if (ctorOwnerFc != address(0)) vm.serializeAddress(o, "ctorOwner_feeCollector", ctorOwnerFc);
        vm.serializeAddress(o, "usdc", usdc);
        string memory out = vm.serializeAddress(o, "ethUsdFeed", feed);
        vm.writeJson(out, file);
    }

    function _live(address a) internal view returns (bool) { return a != address(0) && a.code.length > 0; }

    function _eq(string memory a, string memory b) internal pure returns (bool) { return keccak256(bytes(a)) == keccak256(bytes(b)); }
}
