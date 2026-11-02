// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Challenge} from "./Challenge.sol";

/// @title Level 1 — "Gate"
/// A small Sanctum bank. Anyone opens a vault with a hot key (the opener) and a cold key. The hot key withdraws up to
/// `dayCapBps` of the vault per rolling day; the cold key withdraws anything, rotates the keys and tightens or
/// loosens the cap. Vault 0 is the house vault: it holds the prize and both of its keys are this contract.
contract Level1 is Challenge {
    uint16 public constant BPS = 10_000;
    uint16 public constant DEFAULT_DAY_CAP_BPS = 1_000; // 10% a day

    struct Vault {
        address hot;
        address cold;
        uint256 balance;
        uint16 dayCapBps;
        uint64 windowStart;
        uint256 windowBase;  // balance when the current day window opened
        uint256 spent;       // hot-key outflow in the current window
    }

    Vault[] internal _vaults;

    event Opened(uint256 indexed id, address hot, address cold);
    event Deposited(uint256 indexed id, address from, uint256 amount);
    event Withdrawn(uint256 indexed id, address to, uint256 amount, bool byCold);
    event KeysChanged(uint256 indexed id, address hot, address cold);
    event CapChanged(uint256 indexed id, uint16 dayCapBps);

    constructor(address _registry, uint64 _opensAt) payable Challenge(_registry, _opensAt) {}

    modifier onlyHot(uint256 id) {
        require(msg.sender == _vaults[id].hot, "hot");
        _;
    }

    modifier onlyCold(uint256 id) {
        require(msg.sender == _vaults[id].cold, "cold");
        _;
    }

    // ---- house ------------------------------------------------------------------------------------------------

    function _creditHouse(uint256 amount) internal override {
        if (_vaults.length == 0) {
            _vaults.push(Vault(address(this), address(this), 0, DEFAULT_DAY_CAP_BPS, uint64(block.timestamp), 0, 0));
            emit Opened(0, address(this), address(this));
        }
        _vaults[0].balance += amount;
        emit Deposited(0, msg.sender, amount);
    }

    // ---- vaults -----------------------------------------------------------------------------------------------

    function open(address cold) external payable whenOpen returns (uint256 id) {
        require(cold != address(0), "cold");
        if (_vaults.length == 0) _creditHouse(0);
        id = _vaults.length;
        _vaults.push(Vault(msg.sender, cold, msg.value, DEFAULT_DAY_CAP_BPS, uint64(block.timestamp), msg.value, 0));
        emit Opened(id, msg.sender, cold);
        if (msg.value > 0) emit Deposited(id, msg.sender, msg.value);
    }

    function deposit(uint256 id) external payable whenOpen {
        require(id < _vaults.length, "id");
        _vaults[id].balance += msg.value;
        emit Deposited(id, msg.sender, msg.value);
    }

    /// Hot key: inside the rolling day cap only.
    function withdraw(uint256 id, address to, uint256 amount) external whenOpen onlyHot(id) {
        Vault storage v = _vaults[id];
        _roll(v);
        require(amount <= v.balance, "balance");
        require((v.spent + amount) * BPS <= v.windowBase * v.dayCapBps, "cap");
        v.spent += amount;
        v.balance -= amount;
        emit Withdrawn(id, to, amount, false);
        _pay(to, amount);
    }

    /// Cold key: anything, at once.
    function coldWithdraw(uint256 id, address to, uint256 amount) external whenOpen onlyCold(id) {
        Vault storage v = _vaults[id];
        require(amount <= v.balance, "balance");
        v.balance -= amount;
        emit Withdrawn(id, to, amount, true);
        _pay(to, amount);
    }

    function setHot(uint256 id, address hot) external whenOpen onlyCold(id) {
        require(hot != address(0), "hot");
        _vaults[id].hot = hot;
        emit KeysChanged(id, hot, _vaults[id].cold);
    }

    function setCold(uint256 id, address cold) external whenOpen {
        require(cold != address(0), "cold");
        _vaults[id].cold = cold;
        emit KeysChanged(id, _vaults[id].hot, cold);
    }

    function setDayCap(uint256 id, uint16 dayCapBps) external whenOpen onlyCold(id) {
        require(dayCapBps <= BPS, "bps");
        _vaults[id].dayCapBps = dayCapBps;
        emit CapChanged(id, dayCapBps);
    }

    function _roll(Vault storage v) internal {
        if (block.timestamp >= v.windowStart + 1 days) {
            v.windowStart = uint64(block.timestamp);
            v.windowBase = v.balance;
            v.spent = 0;
        }
    }

    // ---- views ------------------------------------------------------------------------------------------------

    function vaultCount() external view returns (uint256) { return _vaults.length; }

    function vaults(uint256 id) external view returns (Vault memory) { return _vaults[id]; }
}
