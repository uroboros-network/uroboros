// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title FeeCollector — the immutable `feeRouter` of the Sanctum product on Base; it decides, once, where fees end up.
/// SanctumFactory and Subscription stamp their `feeRouter` immutably, so the product that ships first
/// points here. Sanctums pay their 0.25% queued-transfer fee here (in the moved asset: ETH or any ERC-20) and
/// Subscription pays coverage here (ETH, or USDC by transferFrom). Everything simply accumulates.
///
/// Once the fee destination exists, the owner names it ONCE with `setDestination` (write-once, must be a contract).
/// The destination is generic: a fee splitter on Base OR a bridge/forwarder contract (e.g. a CCTP/USDC forwarder
/// to another chain). The collector only sends it ETH by a plain call and ERC-20s by `transfer`: no destination-specific
/// interface is assumed, so the destination must simply accept plain ETH and hold/forward tokens itself.
/// From then on ANYONE can push the whole ETH balance (`forwardETH`) or a token's whole balance (`forwardToken`)
/// to that destination. The owner has no other power: it can never withdraw, never change the destination, and
/// cannot renounce before the destination is set (that would strand the fees forever).
///
/// `receive()` is empty: no storage, no event, never reverts, so a Sanctum's `executeQueued` and a coverage payment
/// can always pay their fee (even with a 2300-gas stipend).
contract FeeCollector is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Where every fee ends up (a fee splitter or a bridge/forwarder contract). Zero until set; set exactly once.
    address public destination;

    event DestinationSet(address indexed destination);
    event ForwardedETH(address indexed caller, address indexed destination, uint256 amount);
    event ForwardedToken(address indexed caller, address indexed token, address indexed destination, uint256 amount);

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// Never reverts, writes nothing.
    receive() external payable {}

    /// Owner, once: name the contract that receives every fee. Cannot be changed afterwards.
    function setDestination(address d) external onlyOwner {
        require(destination == address(0), "destination set");
        require(d != address(this) && d.code.length > 0, "destination must be a contract");
        destination = d;
        emit DestinationSet(d);
    }

    /// Anyone: push the whole ETH balance to `destination`.
    function forwardETH() external nonReentrant returns (uint256 amount) {
        address d = destination;
        require(d != address(0), "no destination");
        amount = address(this).balance;
        require(amount > 0, "empty");
        (bool ok,) = d.call{value: amount}("");
        require(ok, "send");
        emit ForwardedETH(msg.sender, d, amount);
    }

    /// Anyone: push the whole balance of `token` to `destination`.
    function forwardToken(address token) external nonReentrant returns (uint256 amount) {
        address d = destination;
        require(d != address(0), "no destination");
        amount = IERC20(token).balanceOf(address(this));
        require(amount > 0, "empty");
        IERC20(token).safeTransfer(d, amount);
        emit ForwardedToken(msg.sender, token, d, amount);
    }

    /// Renouncing before the destination exists would strand every fee: refused.
    function renounceOwnership() public override onlyOwner {
        require(destination != address(0), "set destination first");
        super.renounceOwnership();
    }
}
