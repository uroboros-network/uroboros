// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Sanctum7702 — the EIP-7702 delegate for a hot EOA.
/// Once an EOA delegates to this contract, the only thing its key can do through the EOA is
/// move money into its Sanctum, and anyone can sweep stray balances into the vault.
/// The bulk of the funds therefore never sits in the EOA that a sweeper could drain.
///
/// Honest limit: a 7702 authorization is applied by the protocol before any code runs, so no
/// delegate can block a compromised key from re-delegating. That is why the money lives in the
/// Sanctum (rate-limited, delayed, freezable) and not in the EOA. Guardians and watchers watch for re-delegations
/// of guarded EOAs and raise Panic on the Sanctum.
contract Sanctum7702 {
    using SafeERC20 for IERC20;

    // ERC-7201 namespaced slot so the EOA's storage never collides with another delegate's.
    // keccak256(abi.encode(uint256(keccak256("sanctum.7702.storage")) - 1)) & ~0xff
    bytes32 private constant SLOT = 0xa03061a946d8080ed95c98169f3ff203def10761cbfa5ea84a832ad996cabe00;

    struct S {
        address vault;
    }

    /// ETH left in the EOA when a third party sweeps, so a griefer cannot strand the owner without gas.
    uint256 public constant GAS_RESERVE = 0.01 ether;

    event Initialized(address eoa, address vault);
    event Swept(address token, uint256 amount);

    function _s() private pure returns (S storage s) {
        bytes32 slot = SLOT;
        assembly { s.slot := slot }
    }

    /// Called by the EOA itself (msg.sender == address(this) under 7702) exactly once.
    function init(address vault) external {
        require(msg.sender == address(this), "self");
        S storage s = _s();
        require(s.vault == address(0), "init");
        require(vault != address(0), "vault");
        s.vault = vault;
        emit Initialized(address(this), vault);
    }

    function vault() external view returns (address) { return _s().vault; }

    /// Move ETH or an ERC-20 sitting in the EOA into the vault. Permissionless on purpose:
    /// a watcher, a keeper or the owner can sweep the moment funds land.
    function sweep(address token) external {
        address v = _s().vault;
        require(v != address(0), "init");
        if (token == address(0)) {
            uint256 bal = address(this).balance;
            if (msg.sender != address(this)) bal = bal > GAS_RESERVE ? bal - GAS_RESERVE : 0;
            (bool ok,) = v.call{value: bal}("");
            require(ok, "eth");
            emit Swept(token, bal);
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(v, bal);
            emit Swept(token, bal);
        }
    }

    /// The EOA's key may only call its own vault. Everything else reverts.
    function execute(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(this), "self");
        require(to == _s().vault, "only vault");
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        require(ok, "call");
        return ret;
    }

    // Without these, a delegated EOA rejects every safeTransferFrom of an NFT.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }
    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external pure returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    receive() external payable {}
}
