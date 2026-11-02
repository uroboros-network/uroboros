// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Challenge} from "./Challenge.sol";

/// @title Level 2 — "Cloister"
/// A Sanctum bank with an hourly cap for the hot key, a cold key that can always withdraw, and a batch entry point so
/// a wallet can open, fund and configure a vault in one transaction. Vault 0 is the house vault (the prize); both of
/// its keys are this contract.
contract Level2 is Challenge {
    uint16 public constant BPS = 10_000;
    uint16 public constant HOUR_CAP_BPS = 500; // 5% an hour for the hot key

    struct Vault {
        address hot;
        address cold;
        uint128 balance;
        uint64 hour;      // hour index of `spent`
        uint128 spent;
    }

    mapping(uint256 => Vault) internal _vaults;
    uint256 public nextId = 1;

    event Opened(uint256 indexed id, address hot, address cold);
    event Deposited(uint256 indexed id, address from, uint256 amount);
    event Withdrawn(uint256 indexed id, address to, uint256 amount, bool byCold);
    event HotChanged(uint256 indexed id, address hot);

    constructor(address _registry, uint64 _opensAt) payable Challenge(_registry, _opensAt) {
        _vaults[0].hot = address(this);
        _vaults[0].cold = address(this);
    }

    function _creditHouse(uint256 amount) internal override {
        _vaults[0].balance += uint128(amount);
        emit Deposited(0, msg.sender, amount);
    }

    // ---- batch ------------------------------------------------------------------------------------------------

    /// Runs several calls of this contract in one transaction, as the caller.
    function multicall(bytes[] calldata calls) external payable returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory r) = address(this).delegatecall(calls[i]);
            if (!ok) {
                assembly { revert(add(r, 32), mload(r)) }
            }
            results[i] = r;
        }
    }

    // ---- vaults -----------------------------------------------------------------------------------------------

    /// Opens a vault (hot key = caller) with whatever ETH comes with the call.
    function open(address cold) public payable whenOpen returns (uint256 id) {
        require(cold != address(0), "cold");
        id = nextId++;
        _vaults[id].hot = msg.sender;
        _vaults[id].cold = cold;
        emit Opened(id, msg.sender, cold);
        if (msg.value > 0) {
            _vaults[id].balance = uint128(msg.value);
            emit Deposited(id, msg.sender, msg.value);
        }
    }

    function deposit(uint256 id) public payable whenOpen {
        require(id != 0 && id < nextId, "id");
        require(msg.value > 0, "value");
        _vaults[id].balance += uint128(msg.value);
        emit Deposited(id, msg.sender, msg.value);
    }

    function withdraw(uint256 id, address to, uint256 amount) external whenOpen {
        Vault storage v = _vaults[id];
        require(msg.sender == v.hot, "hot");
        require(amount <= v.balance, "balance");
        uint64 h = uint64(block.timestamp / 1 hours);
        if (v.hour != h) { v.hour = h; v.spent = 0; }
        require((uint256(v.spent) + amount) * BPS <= uint256(v.balance + v.spent) * HOUR_CAP_BPS, "cap");
        v.spent += uint128(amount);
        v.balance -= uint128(amount);
        emit Withdrawn(id, to, amount, false);
        _pay(to, amount);
    }

    function coldWithdraw(uint256 id, address to, uint256 amount) external whenOpen {
        Vault storage v = _vaults[id];
        require(msg.sender == v.cold, "cold");
        require(amount <= v.balance, "balance");
        v.balance -= uint128(amount);
        emit Withdrawn(id, to, amount, true);
        _pay(to, amount);
    }

    function setHot(uint256 id, address hot) public payable whenOpen {
        require(msg.sender == _vaults[id].cold, "cold");
        require(hot != address(0), "hot");
        _vaults[id].hot = hot;
        emit HotChanged(id, hot);
    }

    // ---- views ------------------------------------------------------------------------------------------------

    function vaults(uint256 id) external view returns (Vault memory) { return _vaults[id]; }
}
