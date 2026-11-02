// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {BountySanctum} from "./BountySanctum.sol";
import {Sanctum} from "./Sanctum.sol";

/// @title BountyCold — the cold key of the "Raid the Sanctum" bounty Sanctum (AUDIT-3 M1).
/// A locker: it holds the Sanctum's cold-key role and can do only what cannot move or unlock the prize.
/// Its constructor deploys the `BountySanctum` (public hot key) with THIS contract as cold, so the Sanctum's cold key
/// is this contract from the first block, and forwards msg.value as the first prize.
///
/// Exposed (owner = dev EOA, two-step, handed to the Safe on day 30):
///   `panic`, `unfreeze`, `setGuardians` — freeze/unfreeze the game and manage the admin-chosen guardians.
/// Guardian recovery is OFF on the bounty Sanctum: the constructor calls `sanctum.setRecoveryOff(true)` right after
///   deploying it and nothing here can switch it back, so guardians can never vote in a new cold key (proposeCold
///   reverts "recovery off"). Guardians keep only their panic. (The step-3 public `cancelRecovery` was removed: with
///   recovery off there is never a recovery to cancel.)
/// Deliberately ABSENT (no code path calls them, no generic call/delegatecall exists): `withdraw`, `coldWithdraw`,
/// `coldSetRules`, `proposeRules`/`applyRules`, `setAllowlist`, `setOwner`, `setCold`, `setBlacklist`,
/// `setWatcherRegistry`/`setWatchersOn`, `setRequireApproval`, `approveQueued`, `executeQueued`, `cancel`,
/// `setRecoveryOff` (only ever called once, with `true`, in the constructor), `cancelRecovery`.
/// So the rules stay 1%/h · 2%/24h forever, the hot key stays the BountySanctum forever, and the prize leaves only
/// through raids, and the cold key stays this contract forever. Residual trust: the owner can freeze the game (panic,
/// renewable) and choose guardians (who can only panic).
/// No `receive`: this contract never holds ETH. ERC-20s swept here by `BountySanctum.sweep` stay here.
contract BountyCold is Ownable2Step {
    BountySanctum public immutable bounty;
    Sanctum public immutable sanctum;

    constructor(address _owner, address factory, address[] memory guardians, uint8 threshold)
        payable
        Ownable(_owner)
    {
        bounty = new BountySanctum{value: msg.value}(factory, address(this), guardians, threshold);
        sanctum = bounty.sanctum();
        require(sanctum.cold() == address(this) && sanctum.owner() == address(bounty), "keys");
        sanctum.setRecoveryOff(true); // closes the recovery gap: guardians can never replace this locker
    }

    /// Freeze the game for 24 h (the cold key's panic is never muted and may be renewed).
    function panic() external onlyOwner { sanctum.panic(); }

    /// End a freeze now. Mutes the guardians for 24 h (Sanctum rule).
    function unfreeze() external onlyOwner { sanctum.unfreeze(); }

    /// Replace the guardian set (≤ 5; threshold 0 = default). Voids any running recovery.
    function setGuardians(address[] calldata g, uint8 threshold) external onlyOwner { sanctum.setGuardians(g, threshold); }

    /// Ownership can be handed over (two-step) but never renounced: without an owner nobody could end a freeze.
    function renounceOwnership() public pure override { revert("no renounce"); }
}
