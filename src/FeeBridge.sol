// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// Base's official L1StandardBridge on Ethereum (proxy 0x3154Cf16ccdb4C6d922629664174b904d80F2C35).
interface IL1StandardBridge {
    function depositETHTo(address _to, uint32 _minGasLimit, bytes calldata _extraData) external payable;
}

/// @title FeeBridge — the local `feeRouter` of Sanctums on a chain other than Base (Ethereum at launch).
/// Sanctums pay their 0.25% queued-transfer fee here and `Subscription` pays coverage here, exactly as they pay the
/// fee collector on Base. `receive()` is storage-free and never reverts, so a Sanctum's `executeQueued` is never blocked.
///
/// `bridge()` (anyone): once the ETH balance reaches `minBridge`, sends ALL of it to the fee destination on Base through
/// Base's L1StandardBridge `depositETHTo(feeRouterOnBase, MIN_GAS_LIMIT, "")`. The ETH arrives on Base as a plain
/// call to the destination's `receive()` (it must stay far below MIN_GAS_LIMIT).
/// The threshold keeps a caller from wasting L1 gas on dust.
///
/// ERC-20 fees (queued fee in the moved asset, USDC coverage) are not bridged: `forwardToken(token)` (anyone) sends
/// the whole balance of `token` to the immutable `tokenSink`, set at deploy (the team's Ethereum Safe).
/// No owner, no admin, no upgrade: every address and the threshold are immutable.
contract FeeBridge {
    using SafeERC20 for IERC20;

    uint32 public constant MIN_GAS_LIMIT = 200_000;

    IL1StandardBridge public immutable l1Bridge;
    address public immutable feeRouterOnBase;
    address public immutable tokenSink;
    uint256 public immutable minBridge;

    event Bridged(address indexed caller, uint256 amount);
    event TokenForwarded(address indexed token, address to, uint256 amount);

    constructor(address _l1Bridge, address _feeRouterOnBase, address _tokenSink, uint256 _minBridge) {
        require(_l1Bridge.code.length > 0, "bridge");
        require(_feeRouterOnBase != address(0) && _tokenSink != address(0), "addr");
        require(_minBridge > 0, "min");
        l1Bridge = IL1StandardBridge(_l1Bridge);
        feeRouterOnBase = _feeRouterOnBase;
        tokenSink = _tokenSink;
        minBridge = _minBridge;
    }

    /// Never reverts, writes nothing: a Sanctum's queue release and a coverage payment can always pay their fee.
    receive() external payable {}

    /// Anyone: bridge the whole ETH balance to the fee destination on Base. Reverts below `minBridge`.
    function bridge() external returns (uint256 amount) {
        amount = address(this).balance;
        require(amount >= minBridge, "below min");
        l1Bridge.depositETHTo{value: amount}(feeRouterOnBase, MIN_GAS_LIMIT, "");
        emit Bridged(msg.sender, amount);
    }

    /// Anyone: send the whole balance of an ERC-20 fee to `tokenSink`.
    function forwardToken(address token) external returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
        require(amount > 0, "empty");
        IERC20(token).safeTransfer(tokenSink, amount);
        emit TokenForwarded(token, tokenSink, amount);
    }
}
