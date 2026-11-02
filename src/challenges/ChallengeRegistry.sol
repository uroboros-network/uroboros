// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

interface IChallengeLevel {
    function registry() external view returns (address);
    function prize() external view returns (uint256);
    function opensAt() external view returns (uint64);
    function solvedBy() external view returns (address);
}

/// @title ChallengeRegistry — the weekly Sanctum challenge ladder (CHALLENGES.md).
/// Records every level (id, contract, prize, opensAt, solvedBy, solvedAt) and keeps an on-chain leaderboard: solves
/// per address and each solver's first-solve time. A level reports its own solve (`recordSolve`), once; the owner
/// only adds levels. The registry never holds or moves ETH: each level holds its own prize, isolated from every
/// other contract of the protocol.
/// Owner = dev EOA (two-step ownership; handed to the Safe with the rest on day 30).
contract ChallengeRegistry is Ownable2Step {
    struct Level {
        address challenge;
        uint96 prize;      // prize at registration, refreshed by `syncPrize` and at the solve
        uint64 opensAt;
        address solvedBy;  // tx.origin of the draining transaction (see Challenge)
        uint64 solvedAt;
    }

    Level[] internal _levels;                       // id = index + 1
    mapping(address => uint256) public levelOf;     // challenge contract → id (0 = not registered)
    mapping(address => uint256) public solves;      // solver → levels solved
    mapping(address => uint64) public firstSolveAt; // solver → time of their first solve
    address[] public solvers;                       // every address that solved at least one level, in order

    event LevelAdded(uint256 indexed id, address indexed challenge, uint256 prize, uint64 opensAt);
    event PrizeSynced(uint256 indexed id, uint256 prize);
    event Solved(uint256 indexed id, address indexed solver, uint256 prize, uint64 solvedAt);

    constructor(address _owner) Ownable(_owner) {}

    /// Registers a deployed level. The level must name this registry and be unsolved.
    function addLevel(address challenge) external onlyOwner returns (uint256 id) {
        require(challenge.code.length > 0, "code");
        require(levelOf[challenge] == 0, "added");
        IChallengeLevel c = IChallengeLevel(challenge);
        require(c.registry() == address(this), "registry");
        require(c.solvedBy() == address(0), "solved");
        _levels.push(Level(challenge, uint96(c.prize()), c.opensAt(), address(0), 0));
        id = _levels.length;
        levelOf[challenge] = id;
        emit LevelAdded(id, challenge, c.prize(), c.opensAt());
    }

    /// Anyone: refresh the stored prize of an unsolved level (it grows when the level is funded again).
    function syncPrize(uint256 id) external {
        Level storage l = _level(id);
        require(l.solvedBy == address(0), "solved");
        l.prize = uint96(IChallengeLevel(l.challenge).prize());
        emit PrizeSynced(id, l.prize);
    }

    /// Called by a registered level, once, when its prize has been taken.
    function recordSolve(address solver) external {
        uint256 id = levelOf[msg.sender];
        require(id != 0, "level");
        Level storage l = _levels[id - 1];
        require(l.solvedBy == address(0), "solved");
        require(solver != address(0), "solver");
        l.solvedBy = solver;
        l.solvedAt = uint64(block.timestamp);
        l.prize = uint96(IChallengeLevel(msg.sender).prize());
        if (solves[solver] == 0) {
            firstSolveAt[solver] = uint64(block.timestamp);
            solvers.push(solver);
        }
        solves[solver] += 1;
        emit Solved(id, solver, l.prize, uint64(block.timestamp));
    }

    // ---- views ----------------------------------------------------------------------------------------------

    function levelCount() external view returns (uint256) { return _levels.length; }

    function level(uint256 id) external view returns (Level memory) { return _level(id); }

    function solverCount() external view returns (uint256) { return solvers.length; }

    /// Every solver with their solve count and first-solve time (sort off-chain: solves desc, first solve asc).
    function leaderboard() external view returns (address[] memory who, uint256[] memory count, uint64[] memory first) {
        uint256 n = solvers.length;
        who = new address[](n);
        count = new uint256[](n);
        first = new uint64[](n);
        for (uint256 i; i < n; ++i) {
            address s = solvers[i];
            who[i] = s;
            count[i] = solves[s];
            first[i] = firstSolveAt[s];
        }
    }

    function _level(uint256 id) internal view returns (Level storage) {
        require(id != 0 && id <= _levels.length, "id");
        return _levels[id - 1];
    }
}
