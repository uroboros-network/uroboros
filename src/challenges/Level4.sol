// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Challenge} from "./Challenge.sol";

/// @title Level 4 — "Reliquary"
/// A Sanctum bank for wallets that keep the cold key offline. The hot key withdraws up to 2% of its vault per day.
/// The cold key never has to send a transaction: it signs an EIP-712 `ColdWithdraw` (vault, to, amount, nonce,
/// deadline) and anyone relays it, like a sponsored EIP-7702 call. Signatures are bound to this contract and chain,
/// carry a per-vault nonce and a deadline, and must be low-s. Vault 0 is the house vault (the prize).
contract Level4 is Challenge {
    uint16 public constant BPS = 10_000;
    uint16 public constant DAY_CAP_BPS = 200; // 2% a day for the hot key
    bytes32 public constant COLD_WITHDRAW_TYPEHASH =
        keccak256("ColdWithdraw(uint256 vault,address to,uint256 amount,uint256 nonce,uint256 deadline)");
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 private constant HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    struct Vault {
        address hot;
        address cold;
        uint256 balance;
        uint256 nonce;
        uint64 day;
        uint256 spent;
    }

    mapping(uint256 => Vault) internal _vaults;
    uint256 public nextId = 1;

    event Opened(uint256 indexed id, address hot, address cold);
    event Deposited(uint256 indexed id, address from, uint256 amount);
    event Withdrawn(uint256 indexed id, address to, uint256 amount, bool byCold);
    event KeysChanged(uint256 indexed id, address hot, address cold);

    constructor(address _registry, uint64 _opensAt) payable Challenge(_registry, _opensAt) {}

    function _creditHouse(uint256 amount) internal override {
        _vaults[0].balance += amount;
        emit Deposited(0, msg.sender, amount);
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Reliquary"), keccak256("1"), block.chainid, address(this)));
    }

    function coldWithdrawDigest(uint256 id, address to, uint256 amount, uint256 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(COLD_WITHDRAW_TYPEHASH, id, to, amount, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    // ---- vaults -----------------------------------------------------------------------------------------------

    function open(address cold) external payable whenOpen returns (uint256 id) {
        require(cold != address(0), "cold");
        id = nextId++;
        _vaults[id] = Vault(msg.sender, cold, msg.value, 0, 0, 0);
        emit Opened(id, msg.sender, cold);
        if (msg.value > 0) emit Deposited(id, msg.sender, msg.value);
    }

    function deposit(uint256 id) external payable whenOpen {
        require(id != 0 && id < nextId, "id");
        _vaults[id].balance += msg.value;
        emit Deposited(id, msg.sender, msg.value);
    }

    /// Hot key: up to 2% of the vault per UTC day.
    function withdraw(uint256 id, address to, uint256 amount) external whenOpen {
        Vault storage v = _vaults[id];
        require(msg.sender == v.hot, "hot");
        require(amount <= v.balance, "balance");
        uint64 d = uint64(block.timestamp / 1 days);
        if (v.day != d) { v.day = d; v.spent = 0; }
        require((v.spent + amount) * BPS <= (v.balance + v.spent) * DAY_CAP_BPS, "cap");
        v.spent += amount;
        v.balance -= amount;
        emit Withdrawn(id, to, amount, false);
        _pay(to, amount);
    }

    /// Relayed cold-key withdrawal: anything, at once, with the cold key's signature.
    function coldWithdrawWithSig(uint256 id, address to, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        whenOpen
    {
        require(block.timestamp <= deadline, "expired");
        require(v == 27 || v == 28, "v");
        require(uint256(s) <= HALF_N, "s");
        Vault storage vault = _vaults[id];
        bytes32 digest = coldWithdrawDigest(id, to, amount, vault.nonce, deadline);
        require(ecrecover(digest, v, r, s) == vault.cold, "sig");
        require(amount <= vault.balance, "balance");
        vault.nonce += 1;
        vault.balance -= amount;
        emit Withdrawn(id, to, amount, true);
        _pay(to, amount);
    }

    /// Cold key, directly.
    function setKeys(uint256 id, address hot, address cold) external whenOpen {
        Vault storage v = _vaults[id];
        require(msg.sender == v.cold, "cold");
        require(hot != address(0) && cold != address(0), "zero");
        v.hot = hot;
        v.cold = cold;
        emit KeysChanged(id, hot, cold);
    }

    // ---- views ------------------------------------------------------------------------------------------------

    function vaults(uint256 id) external view returns (Vault memory) { return _vaults[id]; }
}
