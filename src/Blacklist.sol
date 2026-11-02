// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title Blacklist — flagged addresses every Sanctum refuses to pay.
/// v1: the oracle key (the team, then the node quorum) flags addresses directly.
/// v2 replaces this with a Merkle root posted by the Canary validator set.
/// Ownership is two-step (AUDIT-3 L4): `transferOwnership` nominates, the new owner calls `acceptOwnership`.
contract Blacklist is Ownable2Step {
    mapping(address => bool) public isFlagged;
    mapping(address => bool) public oracle;

    event Flagged(address a, bool on, string reason);

    constructor() Ownable(msg.sender) { oracle[msg.sender] = true; }

    function setOracle(address a, bool on) external onlyOwner { oracle[a] = on; }

    function flag(address a, bool on, string calldata reason) external {
        require(oracle[msg.sender], "oracle");
        isFlagged[a] = on;
        emit Flagged(a, on, reason);
    }

    function flagMany(address[] calldata a, string calldata reason) external {
        require(oracle[msg.sender], "oracle");
        for (uint256 i; i < a.length; i++) { isFlagged[a[i]] = true; emit Flagged(a[i], true, reason); }
    }
}
