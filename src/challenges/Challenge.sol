// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IChallengeRegistry {
    function recordSolve(address solver) external;
}

/// @title Challenge — base of every weekly Sanctum challenge level (CHALLENGES.md).
/// A level is a self-contained vault that holds an ETH prize in its "house" account. No key can move the house
/// account. The level opens at `opensAt`; before that every vault function reverts.
///
/// SOLVE: a level counts as solved the moment its ETH balance falls below half of `prize` — i.e. more than half of
/// the house prize (net of anything the solver deposited) has left the contract. Every ETH payment of a level goes
/// through `_pay`, which checks this after each payment. The solver of record is `tx.origin` of the transaction that
/// crossed the line (so a solve through your own attack contract is credited to the EOA that sent it). It is written
/// here (`solvedBy`, `solvedAt`) and reported to the registry, once. Whoever took the ETH keeps it; nothing is paid
/// or clawed back by this contract.
///
/// Isolation: a level holds only its own prize and its players' deposits. It has no owner, no admin, no withdrawal
/// for the team, no approvals and no link to any other contract of the protocol except the write-only call to the
/// registry. An unsolved prize stays in the level.
abstract contract Challenge {
    IChallengeRegistry public immutable registry;
    uint64 public immutable opensAt;
    uint256 public prize;     // ETH put into the house account (constructor value + `fund`)
    address public solvedBy;
    uint64 public solvedAt;

    event Funded(address indexed from, uint256 amount, uint256 prize);
    event Solved(address indexed solver, uint256 balanceLeft);

    constructor(address _registry, uint64 _opensAt) payable {
        require(_registry != address(0), "registry");
        registry = IChallengeRegistry(_registry);
        opensAt = _opensAt;
        if (msg.value > 0) _fund();
    }

    modifier whenOpen() {
        require(block.timestamp >= opensAt, "closed");
        _;
    }

    /// Anyone may add to the prize of an unsolved level (the team funds it from the treasury / bounty share).
    function fund() external payable {
        require(msg.value > 0, "value");
        require(solvedBy == address(0), "solved");
        _fund();
    }

    function isOpen() external view returns (bool) { return block.timestamp >= opensAt; }

    function _fund() internal {
        prize += msg.value;
        _creditHouse(msg.value);
        emit Funded(msg.sender, msg.value, prize);
    }

    /// The level's own accounting of the house account.
    function _creditHouse(uint256 amount) internal virtual;

    /// Every ETH payment of a level goes through here.
    function _pay(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "send");
        _checkSolved();
    }

    /// Gas reserved for the registry's `recordSolve` (it writes at most ~6 slots). The solving transaction must carry
    /// it: with less, the payment that crosses the line reverts ("gas"), so a solve can never be recorded in the
    /// level while silently missing from the registry (a caught out-of-gas would otherwise do exactly that).
    uint256 public constant RECORD_GAS = 250_000;

    function _checkSolved() internal {
        if (solvedBy != address(0) || address(this).balance * 2 >= prize) return;
        solvedBy = tx.origin;
        solvedAt = uint64(block.timestamp);
        emit Solved(tx.origin, address(this).balance);
        require(gasleft() > RECORD_GAS + RECORD_GAS / 63 + 5_000, "gas");
        // with the gas guaranteed, only a registry-side refusal (e.g. a level that was never registered) is caught
        try registry.recordSolve{gas: RECORD_GAS}(tx.origin) {} catch {}
    }
}
