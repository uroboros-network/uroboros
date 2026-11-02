// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Challenge} from "./Challenge.sol";

/// @title Level 3 — "Crypt"
/// A Sanctum bank with the full Sanctum shape: the hot key withdraws up to 10% of the vault per hour at once; anything
/// bigger waits in a queue for `DELAY` and is then released by anyone; the cold key can cancel a queued transfer
/// (the amount returns to the vault) and freeze its vault. The amount of a queued transfer is reserved when it is
/// queued. Vault 0 is the house vault (the prize); both of its keys are this contract.
contract Level3 is Challenge {
    uint16 public constant BPS = 10_000;
    uint16 public constant HOUR_CAP_BPS = 1_000; // 10% an hour
    uint32 public constant DELAY = 1 hours;
    uint32 public constant FREEZE = 24 hours;

    struct Vault {
        address hot;
        address cold;
        uint256 balance;   // free balance (queued amounts already taken out)
        uint64 hour;
        uint64 frozenUntil;
        uint256 spent;
    }

    struct Queued {
        uint256 vault;
        address to;
        uint256 amount;
        uint64 readyAt;
        bool done;
    }

    Vault[] internal _vaults;
    Queued[] public queue;
    bool private _locked;

    event Opened(uint256 indexed id, address hot, address cold);
    event Deposited(uint256 indexed id, address from, uint256 amount);
    event Withdrawn(uint256 indexed id, address to, uint256 amount);
    event QueuedTransfer(uint256 indexed qid, uint256 indexed vault, address to, uint256 amount, uint64 readyAt);
    event Released(uint256 indexed qid, address to, uint256 amount);
    event Cancelled(uint256 indexed qid);
    event Frozen(uint256 indexed id, uint64 until);

    modifier nonReentrant() {
        require(!_locked, "locked");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address _registry, uint64 _opensAt) payable Challenge(_registry, _opensAt) {}

    function _creditHouse(uint256 amount) internal override {
        if (_vaults.length == 0) {
            _vaults.push(Vault(address(this), address(this), 0, 0, 0, 0));
            emit Opened(0, address(this), address(this));
        }
        _vaults[0].balance += amount;
        emit Deposited(0, msg.sender, amount);
    }

    // ---- vaults -----------------------------------------------------------------------------------------------

    function open(address cold) external payable whenOpen nonReentrant returns (uint256 id) {
        require(cold != address(0), "cold");
        if (_vaults.length == 0) _creditHouse(0);
        id = _vaults.length;
        _vaults.push(Vault(msg.sender, cold, msg.value, 0, 0, 0));
        emit Opened(id, msg.sender, cold);
        if (msg.value > 0) emit Deposited(id, msg.sender, msg.value);
    }

    function deposit(uint256 id) external payable whenOpen nonReentrant {
        require(id < _vaults.length, "id");
        _vaults[id].balance += msg.value;
        emit Deposited(id, msg.sender, msg.value);
    }

    /// Hot key. Inside the hourly cap: paid now. Above it: reserved and queued for `DELAY`.
    function withdraw(uint256 id, address to, uint256 amount) external whenOpen nonReentrant returns (uint256 qid) {
        Vault storage v = _vaults[id];
        require(msg.sender == v.hot, "hot");
        require(block.timestamp >= v.frozenUntil, "frozen");
        require(amount > 0 && amount <= v.balance, "balance");
        uint64 h = uint64(block.timestamp / 1 hours);
        if (v.hour != h) { v.hour = h; v.spent = 0; }
        if ((v.spent + amount) * BPS <= (v.balance + v.spent) * HOUR_CAP_BPS) {
            v.spent += amount;
            v.balance -= amount;
            emit Withdrawn(id, to, amount);
            _pay(to, amount);
            return type(uint256).max;
        }
        v.balance -= amount;
        qid = queue.length;
        uint64 readyAt = uint64(block.timestamp) + DELAY;
        queue.push(Queued(id, to, amount, readyAt, false));
        emit QueuedTransfer(qid, id, to, amount, readyAt);
    }

    /// Anyone, once the delay has passed and the vault is not frozen.
    function release(uint256 qid) external whenOpen {
        Queued storage q = queue[qid];
        require(!q.done, "done");
        require(block.timestamp >= q.readyAt, "delay");
        require(block.timestamp >= _vaults[q.vault].frozenUntil, "frozen");
        _pay(q.to, q.amount);
        q.done = true;
        emit Released(qid, q.to, q.amount);
    }

    /// Cold key: the reserved amount returns to the vault.
    function cancel(uint256 qid) external whenOpen nonReentrant {
        Queued storage q = queue[qid];
        require(msg.sender == _vaults[q.vault].cold, "cold");
        require(!q.done, "done");
        q.done = true;
        _vaults[q.vault].balance += q.amount;
        emit Cancelled(qid);
    }

    /// Cold key: anything, at once (also while frozen).
    function coldWithdraw(uint256 id, address to, uint256 amount) external whenOpen nonReentrant {
        Vault storage v = _vaults[id];
        require(msg.sender == v.cold, "cold");
        require(amount <= v.balance, "balance");
        v.balance -= amount;
        emit Withdrawn(id, to, amount);
        _pay(to, amount);
    }

    function freeze(uint256 id) external whenOpen {
        Vault storage v = _vaults[id];
        require(msg.sender == v.cold || msg.sender == v.hot, "key");
        v.frozenUntil = uint64(block.timestamp) + FREEZE;
        emit Frozen(id, v.frozenUntil);
    }

    // ---- views ------------------------------------------------------------------------------------------------

    function vaultCount() external view returns (uint256) { return _vaults.length; }

    function vaults(uint256 id) external view returns (Vault memory) { return _vaults[id]; }

    function queueLength() external view returns (uint256) { return queue.length; }
}
