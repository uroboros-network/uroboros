// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Sanctum} from "./Sanctum.sol";

interface ISanctumFactory {
    function createWithRules(address cold, address[] calldata guardians, uint8 threshold, Sanctum.Rules memory r)
        external payable returns (address);
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @title BountySanctum — "Raid the Sanctum", main vault = BREAK-THE-CAPS bounty (SPEC §3.2, STEP 4 redesign).
/// This contract IS the hot key (`Sanctum.owner`) of the Sanctum it creates in its
/// constructor and lets ANYONE act as that hot key from their own wallet, paying their own gas, exactly as a thief
/// with a stolen key would.
///
/// THE GAME (2 Nov 2026): every outflow this key allows is sent back INTO the bounty Sanctum. `withdraw`
/// accepts exactly one destination, the Sanctum itself (`to == sanctum`), ETH only. So anyone can use the public key
/// to probe the caps, the freeze and the rules for real, on mainnet, but nothing the rules allow ever leaves: the
/// prize only grows (seed + top-ups). There is NO legitimate exit
/// for anyone, the team included (the cold key is `BountyCold`: panic / unfreeze / setGuardians only, guardian
/// recovery switched off for good). The only way to get ETH out to your own address is to break the contracts.
///
/// THE PRIZE: whoever gets ETH out of the bounty Sanctum keeps it. In addition the team promises, OFF-CHAIN, a bounty
/// for a public post-mortem of how it was done. That promise is not enforced by any contract: there is no on-chain
/// payout, claim or escrow for it.
///
/// Rules, set at creation: capBps 100 (1%/h) · dayCapBps 200 (2% per rolling 24h) · delayBps 10000 (queue
/// disabled) · allowlist off · watchersOn off. A probe uses the Sanctum's cap room like a real withdrawal (the money
/// leaves and comes straight back), so the caps and the freeze answer exactly as they would for a thief; probes
/// above the room revert ("over cap") BEFORE reaching the Sanctum, so nothing is ever queued.
///
/// TRUST (AUDIT-3 M1): the Sanctum's cold key could, with any other cold key, change or loosen the rules, withdraw
/// the prize, replace this contract as the hot key, unfreeze and change guardians. In production the cold key is
/// `BountyCold`, where none of the fund-moving or loosening calls is reachable.
///
/// Deliberately NOT exposed: panic (an owner panic is never muted, so anyone could freeze the game forever),
/// cancel, executeQueued, proposeRules / applyRules, anything touching owner / cold. Holds no funds: ETH sent here
/// (`receive`, `topUp`) is forwarded to the Sanctum at once; stray ERC-20s are swept to the cold key (BountyCold,
/// where they stay).
contract BountySanctum {
    address public constant ETH = address(0);
    Sanctum public immutable sanctum;
    address public immutable factory;
    address public immutable cold;
    uint64 public lastAttemptAt;   // last successful probe through this key
    uint256 public attempts;       // successful probes through this key
    uint256 public totalCycled;    // ETH ever sent out and straight back in through this key

    /// One event per successful probe: `amount` left the Sanctum and came straight back; `prize` is the Sanctum's
    /// ETH balance after the probe (never lower than before it).
    event Attempt(address indexed caller, uint256 amount, uint256 prize);
    event TopUp(address indexed from, uint256 amount, uint256 prize);
    event Swept(address token, address to, uint256 amount);

    /// Creates the Sanctum via the factory (this contract becomes its hot key) and forwards msg.value as the first
    /// prize. `guardians` = admin-chosen (team watcher + named watchers), `threshold` 0 = factory default.
    constructor(address _factory, address _cold, address[] memory guardians, uint8 threshold) payable {
        require(_factory != address(0) && _cold != address(0), "addr");
        factory = _factory;
        cold = _cold;
        Sanctum.Rules memory r = Sanctum.Rules({capBps: 100, dayCapBps: 200, delayBps: 10_000, delay: 24 hours, allowlistOn: false});
        sanctum = Sanctum(payable(ISanctumFactory(_factory).createWithRules{value: msg.value}(_cold, guardians, threshold, r)));
        require(sanctum.owner() == address(this) && sanctum.cold() == _cold, "keys");
    }

    // ---- the game ---------------------------------------------------------------------------

    /// Probe: anyone, from any wallet. `token` must be ETH and `to` must be the bounty Sanctum itself: the amount
    /// leaves through the real Sanctum `withdraw` (hourly + rolling-daily caps, freeze, blacklist all apply) and
    /// lands back in the Sanctum in the same call. Above the caps or while frozen it reverts (nothing is queued).
    /// The Sanctum's balance is checked after the call and may never be lower than before it.
    function withdraw(address token, address to, uint256 amount) external returns (uint256 cycled) {
        require(token == ETH, "eth only");
        require(to == address(sanctum), "to");
        require(amount > 0, "amount");
        require(block.timestamp >= sanctum.frozenUntil(), "frozen");
        require(amount <= sanctum.capRoom(token), "over cap"); // queue disabled: above the caps = revert, not wait
        uint256 before = address(sanctum).balance;
        uint256 id = sanctum.withdraw(token, to, amount);
        require(id == type(uint256).max, "queued"); // can't happen after the guard above; kept as the invariant
        require(address(sanctum).balance >= before, "leak");
        lastAttemptAt = uint64(block.timestamp);
        attempts += 1;
        totalCycled += amount;
        emit Attempt(msg.sender, amount, address(sanctum).balance);
        return amount;
    }

    // ---- prize ------------------------------------------------------------------------------

    /// Current prize: ETH inside the Sanctum.
    function prize() public view returns (uint256) { return address(sanctum).balance; }

    /// How much ETH a probe can cycle right now (hourly room, daily room and freeze all applied). This is what the
    /// caps would let a thief take; here it only goes round trip.
    function probeRoom() external view returns (uint256) {
        if (block.timestamp < sanctum.frozenUntil()) return 0;
        return sanctum.capRoom(ETH);
    }

    /// Anyone adds to the prize (a fee splitter may point here or at the Sanctum directly; both work).
    function topUp() external payable { _topUp(); }
    receive() external payable { _topUp(); }

    function _topUp() internal {
        require(msg.value > 0, "value");
        (bool ok,) = address(sanctum).call{value: msg.value}("");
        require(ok, "topUp");
        emit TopUp(msg.sender, msg.value, prize());
    }

    // ---- housekeeping -----------------------------------------------------------------------

    /// ERC-20s sent here by mistake (the Sanctum is the deposit address) go to the Sanctum's current cold key.
    function sweep(address token) external {
        address to = sanctum.cold();
        uint256 a = IERC20Like(token).balanceOf(address(this));
        (bool ok, bytes memory r) = token.call(abi.encodeCall(IERC20Like.transfer, (to, a)));
        require(ok && (r.length == 0 || abi.decode(r, (bool))), "sweep");
        emit Swept(token, to, a);
    }
}
