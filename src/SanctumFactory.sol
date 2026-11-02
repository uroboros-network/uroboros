// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Sanctum} from "./Sanctum.sol";

interface ISubscription {
    function register(address sanctum, bool trialEligible) external;
}

/// @title SanctumFactory — one call to get a Sanctum with the default rules, a guardian set and a free trial.
/// The caller becomes the hot key. Default rules: 5% per hour, 10% per rolling 24h, queue above 10% for 6 hours,
/// no allowlist (conservative defaults). `feeRouter` and `blacklist` are stamped into every Sanctum;
/// `watcherRegistry` may be address(0) until the watcher market ships (the cold key can set one later).
/// Every new Sanctum is registered with `Subscription`, which starts a 7-day trial only if the Sanctum was created
/// with the DEFAULT rules (`create`; `createWithRules` never gets a trial — AUDIT-2 L2) and already holds ≥ $100 of
/// ETH — so `create` is payable and forwards msg.value to the new Sanctum before registering it (first deposit and
/// trial in one tx). Registration failing would block creation, so the subscription contract must be set and must
/// accept this factory.
contract SanctumFactory {
    address public immutable blacklist;
    address public immutable watcherRegistry;
    address public immutable feeRouter;
    address public immutable subscription;
    address[] public sanctums;
    mapping(address => address[]) public sanctumsOf;
    mapping(address => bool) public isSanctum;

    event SanctumCreated(address sanctum, address owner, address cold, address[] guardians, uint8 threshold);

    constructor(address _blacklist, address _watcherRegistry, address _feeRouter, address _subscription) {
        require(_feeRouter != address(0) && _subscription != address(0), "addr");
        blacklist = _blacklist;
        watcherRegistry = _watcherRegistry;
        feeRouter = _feeRouter;
        subscription = _subscription;
    }

    /// `threshold` 0 picks the default: 2 if >= 3 guardians, else all of them.
    function create(address cold, address[] calldata guardians, uint8 threshold) external payable returns (address) {
        return _create(
            cold, guardians, threshold,
            Sanctum.Rules({capBps: 500, dayCapBps: 1000, delayBps: 1000, delay: 6 hours, allowlistOn: false}),
            true
        );
    }

    /// Custom rules: registered, but no free trial (the rules may let the deposit leave at once).
    function createWithRules(address cold, address[] calldata guardians, uint8 threshold, Sanctum.Rules memory r)
        external payable returns (address)
    {
        return _create(cold, guardians, threshold, r, false);
    }

    function _create(address cold, address[] calldata guardians, uint8 threshold, Sanctum.Rules memory r, bool trialEligible)
        internal returns (address)
    {
        Sanctum s = new Sanctum(msg.sender, cold, blacklist, watcherRegistry, feeRouter, guardians, threshold, r);
        if (msg.value > 0) {
            (bool ok,) = address(s).call{value: msg.value}("");
            require(ok, "deposit");
        }
        sanctums.push(address(s));
        sanctumsOf[msg.sender].push(address(s));
        isSanctum[address(s)] = true;
        ISubscription(subscription).register(address(s), trialEligible);
        emit SanctumCreated(address(s), msg.sender, cold, guardians, s.threshold());
        return address(s);
    }

    function count() external view returns (uint256) { return sanctums.length; }
}
