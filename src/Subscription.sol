// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// Chainlink AggregatorV3 subset. Base ETH/USD: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70 (8 decimals).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title Subscription — $5/month of watcher coverage per Sanctum, priced in USD, paid in ETH or USDC.
/// This is a ledger, not a gate: `coveredUntil(sanctum)` is what watchers read to decide whom to cover.
/// The Sanctum contract never calls this and never stops working when unpaid (SPEC §1.5).
///  - 7-day free trial at registration (factory only), and ONLY if (a) the Sanctum was created with the factory's
///    DEFAULT rules (`trialEligible`, AUDIT-2 L2: custom 100%-cap rules could pull the deposit back out in the same
///    block) and (b) it already holds ≥ $100 of ETH (AUDIT-1 S1/A11, SPEC §11): an empty Sanctum gets no trial. The
///    factory's `create` is payable so the first deposit can travel in the creation tx. A stale feed means no trial,
///    never a failed creation. Remaining limit: with the default rules 10% of the $100 may leave per 24 h and the
///    rest only through the 6 h queue, so one $100 note can still start a new trial roughly every 6 hours — one
///    trial per ~6 h of locked capital instead of unlimited trials per block.
///  - `pay(sanctum, months)` in ETH, `payUsdc(sanctum, months)` in USDC (6 decimals, $5.000000/month, no oracle):
///    anyone may pay for any address. Months stack on top of the current coverage, or on now if it has lapsed.
///    Excess ETH is refunded, the price goes straight to `feeRouter` (ETH) / is transferred to it (USDC).
///  - ETH price = `PRICE_USD` × 10^feedDecimals / ETHUSD. The feed must be fresh (`updatedAt` within 24h) and
///    positive, otherwise `pay` reverts: a stale oracle must never sell coverage at a wrong price.
/// Honest limits: a month is a fixed 30 days; prices are quoted at the block of payment (no TWAP) so the
/// ETH amount moves with ETH. The registry trusts `factory` — a one-shot setting by the deployer.
contract Subscription {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_USD = 5e18;          // $5.00, 18 decimals
    uint256 public constant PRICE_USDC = 5e6;          // $5.000000, 6 decimals
    uint256 public constant TRIAL_MIN_USD = 100e18;    // Sanctum must hold ≥ $100 of ETH at registration for a trial
    uint64 public constant TRIAL = 7 days;
    uint64 public constant MONTH = 30 days;
    uint256 public constant MAX_MONTHS = 120;
    uint256 public constant MAX_STALENESS = 24 hours;

    IAggregatorV3 public immutable feed;
    uint8 public immutable feedDecimals;
    address public immutable feeRouter;
    IERC20 public immutable usdc;
    address public immutable deployer;
    address public factory;

    mapping(address => uint64) public paidUntil;
    mapping(address => bool) public registered;

    event FactorySet(address factory);
    event Registered(address sanctum, uint64 trialUntil);
    event Paid(address sanctum, address payer, uint256 months, uint256 weiPaid, uint64 coveredUntil);
    event PaidUsdc(address sanctum, address payer, uint256 months, uint256 usdcPaid, uint64 coveredUntil);

    constructor(address _feed, address _feeRouter, address _usdc) {
        require(_feed != address(0) && _feeRouter != address(0) && _usdc != address(0), "addr");
        feed = IAggregatorV3(_feed);
        feedDecimals = IAggregatorV3(_feed).decimals();
        feeRouter = _feeRouter;
        usdc = IERC20(_usdc);
        deployer = msg.sender;
    }

    /// One shot: the deployer names the factory allowed to start trials.
    function setFactory(address f) external {
        require(msg.sender == deployer, "deployer");
        require(factory == address(0) && f != address(0), "set");
        factory = f;
        emit FactorySet(f);
    }

    /// Factory only, once per Sanctum. Starts the 7-day trial only if the factory marks the Sanctum eligible
    /// (default rules) AND it holds ≥ $100 of ETH right now (feed must be fresh; otherwise no trial).
    /// `trialUntil` = 0 in the event means registered without a trial.
    function register(address sanctum, bool trialEligible) external {
        require(msg.sender == factory, "factory");
        if (registered[sanctum]) return;
        registered[sanctum] = true;
        uint64 until = 0;
        if (trialEligible && _usdValueOfEth(sanctum.balance) >= TRIAL_MIN_USD) {
            until = uint64(block.timestamp) + TRIAL;
            paidUntil[sanctum] = until;
        }
        emit Registered(sanctum, until);
    }

    /// Timestamp until which `sanctum` has watcher coverage (0 = never had any).
    function coveredUntil(address sanctum) external view returns (uint64) { return paidUntil[sanctum]; }

    function isCovered(address sanctum) external view returns (bool) { return paidUntil[sanctum] >= block.timestamp; }

    /// Current ETH price of one month, from the feed. Reverts on a stale or non-positive answer.
    function monthlyPriceWei() public view returns (uint256) {
        return PRICE_USD * (10 ** feedDecimals) / _freshAnswer();
    }

    function priceWei(uint256 months) public view returns (uint256) {
        require(months > 0 && months <= MAX_MONTHS, "months");
        return monthlyPriceWei() * months;
    }

    function priceUsdc(uint256 months) public pure returns (uint256) {
        require(months > 0 && months <= MAX_MONTHS, "months");
        return PRICE_USDC * months;
    }

    function pay(address sanctum, uint256 months) external payable {
        require(sanctum != address(0), "sanctum");
        uint256 cost = priceWei(months);
        require(msg.value >= cost, "underpaid");
        uint64 until = _extend(sanctum, months);
        (bool ok,) = feeRouter.call{value: cost}("");
        require(ok, "router");
        uint256 excess = msg.value - cost;
        if (excess > 0) {
            (ok,) = msg.sender.call{value: excess}("");
            require(ok, "refund");
        }
        emit Paid(sanctum, msg.sender, months, cost, until);
    }

    /// Same coverage, paid in USDC (caller approves `priceUsdc(months)` first). No oracle involved.
    function payUsdc(address sanctum, uint256 months) external {
        require(sanctum != address(0), "sanctum");
        uint256 cost = priceUsdc(months);
        uint64 until = _extend(sanctum, months);
        usdc.safeTransferFrom(msg.sender, feeRouter, cost);
        emit PaidUsdc(sanctum, msg.sender, months, cost, until);
    }

    function _extend(address sanctum, uint256 months) internal returns (uint64 until) {
        uint64 base = paidUntil[sanctum] > block.timestamp ? paidUntil[sanctum] : uint64(block.timestamp);
        until = base + uint64(months) * MONTH;
        paidUntil[sanctum] = until;
    }

    function _freshAnswer() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        require(answer > 0, "feed");
        require(updatedAt <= block.timestamp && block.timestamp - updatedAt <= MAX_STALENESS, "stale");
        return uint256(answer);
    }

    /// USD value (18 decimals) of `weiAmount` at the feed price; 0 if the feed is stale or invalid.
    function _usdValueOfEth(uint256 weiAmount) internal view returns (uint256) {
        if (weiAmount == 0) return 0;
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > MAX_STALENESS) return 0;
        return weiAmount * uint256(answer) / (10 ** feedDecimals);
    }
}
