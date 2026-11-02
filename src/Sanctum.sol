// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBlacklist {
    function isFlagged(address a) external view returns (bool);
}

/// Watcher market registry (step 5). Any address it reports as a watcher may panic a Sanctum whose cold key
/// has opted in with `watchersOn`.
interface IWatcherRegistry {
    function isWatcher(address a) external view returns (bool);
}

/// @title Sanctum — rate-limited, delayed, freezable treasury for one wallet (Base).
/// Funds live here, not in the hot EOA. A stolen hot key can move at most `capBps` of each asset per hour
/// and `dayCapBps` per rolling 24 hours; anything above `delayBps` waits `delay` seconds in a queue the cold
/// key can cancel (and then executes in full, minus the queued-transfer fee); nothing goes to a blacklisted
/// address, and anyone with standing can hit Panic.
///
/// Caps, queue, panic, cold-approve, tighten-only and a rolling 24h ring. Sanctum v1 features:
///  - **Guardians** (0–5, cold-set). Any ONE guardian can `panic()`: re-panic only in the last hour of a
///    running freeze, and muted for 24h after a cold unfreeze. Only the cold key unfreezes.
///  - **Recovery (M-of-N)**: `threshold` distinct guardians voting `proposeCold(newCold)` start a 7-day timer;
///    the cold key can `cancelRecovery()` any time; after 7 days anyone calls `executeRecovery()`. Only one
///    recovery can be active at a time. Changing the guardian set or the cold key voids the running recovery.
///    The cold key can switch recovery off entirely (`setRecoveryOff`, default on): no votes, running one cancelled.
///    Honest limit: with threshold 2 of 5, two colluding guardians can keep re-proposing; the cold key must
///    cancel and should then shrink the set. A lost cold key plus colluding guardians is a lost Sanctum.
///  - **Watchers opt-in**: when `watchersOn` (cold-set, default off), addresses the `IWatcherRegistry`
///    reports as watchers may panic as if they were guardians (`WatcherPanic` event for settlement).
///  - **Queued-transfer fee**: `FEE_BPS` (0.25%) of every transfer released by `executeQueued`, taken in the
///    same asset and sent to the immutable `feeRouter`. Direct capped `withdraw` and `coldWithdraw` are free.
///    The recipient receives `amount - fee`; the queued `amount` is the gross figure.
///  - `requireApproval` is kept as an advisory flag for watchers. The contract itself does not gate on it.
///  - The Sanctum never reads the subscription contract: unpaid means no watcher coverage, never a lock-out.
contract Sanctum {
    using SafeERC20 for IERC20;

    address public constant ETH = address(0);

    struct Rules {
        uint16 capBps;      // max outflow per asset per hour, in bps of balance at hourly-window start
        uint16 dayCapBps;   // max outflow per asset per 24 hours, in bps of balance at daily-window start
        uint16 delayBps;    // transfers above this share of balance are queued
        uint32 delay;       // seconds a queued transfer waits
        bool allowlistOn;   // only allowlisted destinations
    }

    struct Queued {
        address token;
        address to;
        uint256 amount;
        uint64 readyAt;
        bool done;
    }

    address public owner;   // hot key
    address public cold;    // cold key: cancel, unfreeze, change rules, manage guardians
    IBlacklist public blacklist;
    IWatcherRegistry public watchers;
    address public immutable feeRouter;
    Rules public rules;
    Rules public pendingRules;
    uint64 public rulesReadyAt;

    uint64 public frozenUntil;
    uint64 public guardianMutedUntil; // after a cold-key unfreeze, guardians and watchers cannot re-freeze for 24h
    uint64 public lastPanicAt;        // a panic voids every transfer queued at or before it
    uint32 public constant MIN_RULES_DELAY = 3 days; // hot-key rule changes never apply faster than this
    uint16 public constant FEE_BPS = 25;             // 0.25% of every executed queued transfer, to feeRouter
    mapping(address => bool) public allowlisted;
    mapping(address => uint64) public windowStart;
    mapping(address => uint256) public windowBalance;
    mapping(address => uint256) public windowSpent;
    struct HourSlot { uint64 hour; uint192 spent; }
    mapping(address => HourSlot[25]) internal daySlots; // ring of hourly outflow totals: current hour + the 24 before it
    Queued[] public queue;
    mapping(uint256 => uint64) public queuedAt;
    mapping(uint256 => bool) public approved;  // cold-key approval of a queued transfer
    bool public requireApproval;                // watchers read this: panic on unapproved queue items near readyAt
    bool public watchersOn;                     // cold opt-in: registered watchers may panic

    // ---- guardians + recovery
    uint8 public constant MAX_GUARDIANS = 5;
    uint64 public constant RECOVERY_DELAY = 7 days;
    address[] public guardians;
    mapping(address => bool) public isGuardian;
    uint8 public threshold;                     // guardian votes needed to start a recovery (0 = no guardians)
    uint256 public recoveryEpoch;               // bumped whenever votes should be forgotten
    mapping(uint256 => mapping(address => uint8)) public votesFor;                     // epoch => candidate => votes
    mapping(uint256 => mapping(address => mapping(address => bool))) public hasVoted;  // epoch => candidate => guardian
    address public proposedCold;                // candidate of the active recovery (0 when none)
    uint64 public recoveryReadyAt;              // when the active recovery may execute (0 when none)
    bool public recoveryOff;                    // cold opt-out: guardians cannot propose a new cold key (default false)

    event Deposited(address token, uint256 amount);
    event Sent(address token, address to, uint256 amount);
    event QueuedTransfer(uint256 id, address token, address to, uint256 amount, uint64 readyAt);
    event QueuedFee(uint256 id, address token, uint256 fee);
    event Cancelled(uint256 id, address by);
    event Panic(address by, uint64 until);
    event GuardianPanic(address sanctum, address guardian);
    event WatcherPanic(address sanctum, address watcher); // watcher standing: settled by the cold key off this contract
    event Unfrozen(address by);
    event RulesProposed(Rules r, uint64 readyAt);
    event RulesApplied(Rules r);
    event Allowlist(address a, bool on);
    event Approved(uint256 id, address by);
    event OwnerSet(address oldOwner, address newOwner);
    event ColdSet(address oldCold, address newCold);
    event BlacklistSet(address oldBlacklist, address newBlacklist);
    event WatcherRegistrySet(address oldRegistry, address newRegistry);
    event WatchersOnSet(bool on);
    event RequireApprovalSet(bool on);
    event GuardiansSet(address[] guardians, uint8 threshold);
    event RecoveryVote(address guardian, address newCold, uint8 votes, uint8 threshold);
    event RecoveryStarted(address newCold, uint64 readyAt);
    event RecoveryCancelled(address by);
    event RecoveryExecuted(address oldCold, address newCold);
    event RecoveryOffSet(bool off);

    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }
    modifier onlyCold() { require(msg.sender == cold, "cold"); _; }
    modifier ownerOrCold() { require(msg.sender == owner || msg.sender == cold, "owner/cold"); _; }
    modifier notFrozen() { require(block.timestamp >= frozenUntil, "frozen"); _; }

    constructor(
        address _owner,
        address _cold,
        address _blacklist,
        address _watchers,
        address _feeRouter,
        address[] memory _guardians,
        uint8 _threshold,
        Rules memory r
    ) {
        require(_owner != address(0) && _cold != address(0), "keys");
        require(_feeRouter != address(0), "feeRouter");
        owner = _owner;
        cold = _cold;
        blacklist = IBlacklist(_blacklist);
        watchers = IWatcherRegistry(_watchers);
        feeRouter = _feeRouter;
        _checkRules(r);
        rules = r;
        emit RulesApplied(r);
        _setGuardians(_guardians, _threshold);
    }

    receive() external payable { emit Deposited(ETH, msg.value); }

    function deposit(address token, uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(token, amount);
    }

    function balanceOf(address token) public view returns (uint256) {
        return token == ETH ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    // ---- outflows -------------------------------------------------------------------------

    /// Hot-key withdrawal. Small amounts go now (inside the hourly AND daily caps); large ones are queued.
    function withdraw(address token, address to, uint256 amount) external onlyOwner notFrozen returns (uint256 id) {
        _checkDestination(to);
        uint256 bal = balanceOf(token);
        require(amount <= bal, "balance");
        // Big transfers, and anything the hourly/daily caps can't pay right now, wait in the queue
        // instead of reverting: the owner never gets a dead end, a thief still has to wait out the delay.
        if (amount * 10_000 > bal * rules.delayBps || amount > capRoom(token)) {
            id = queue.length;
            uint64 readyAt = uint64(block.timestamp + rules.delay);
            queue.push(Queued(token, to, amount, readyAt, false));
            queuedAt[id] = uint64(block.timestamp);
            emit QueuedTransfer(id, token, to, amount, readyAt);
            return id;
        }
        _spendWindow(token, amount, bal);
        _send(token, to, amount);
        return type(uint256).max;
    }

    /// After the delay, either key can release a queued transfer in full: the delay (during which the
    /// cold key can cancel or anyone with standing can panic) replaces the hourly and daily caps. Freeze and
    /// blacklist still apply. A panic voids everything queued before it (a 24h freeze alone would only
    /// postpone a thief's queued drain until the freeze ends); the owner re-queues legitimate transfers.
    /// `FEE_BPS` of the amount goes to `feeRouter` in the same asset; the recipient gets the rest.
    /// Honest limit: if `feeRouter` rejects ETH the ETH queue cannot be released; the fee router is a plain
    /// payable contract under the project's admin, and the cold key can still move funds out under the caps.
    function executeQueued(uint256 id) external ownerOrCold notFrozen {
        Queued storage q = queue[id];
        require(!q.done, "done");
        require(queuedAt[id] > lastPanicAt, "voided by panic");
        // queued while guardian panics were muted (after a cold unfreeze): only the cold key can let it through
        require(approved[id] || queuedAt[id] >= guardianMutedUntil, "needs cold approval");
        require(block.timestamp >= q.readyAt, "waiting");
        _checkDestination(q.to);
        q.done = true;
        uint256 bal = balanceOf(q.token);
        require(q.amount <= bal, "balance");
        uint256 fee = q.amount * FEE_BPS / 10_000;
        if (fee > 0) {
            _send(q.token, feeRouter, fee);
            emit QueuedFee(id, q.token, fee);
        }
        _send(q.token, q.to, q.amount - fee);
    }

    /// Cold key vouches for a queued transfer: required for items queued inside a mute window, and on
    /// `requireApproval` Sanctums it tells watchers not to panic on it. Does not skip the delay, freeze or a panic void.
    function approveQueued(uint256 id) external onlyCold {
        Queued storage q = queue[id];
        require(!q.done, "done");
        approved[id] = true;
        emit Approved(id, msg.sender);
    }

    function cancel(uint256 id) external ownerOrCold {
        Queued storage q = queue[id];
        require(!q.done, "done");
        q.done = true;
        emit Cancelled(id, msg.sender);
    }

    /// Cold-key withdrawal: bypasses the delay queue but never the hourly/daily caps, blacklist or freeze. No fee.
    function coldWithdraw(address token, address to, uint256 amount) external onlyCold notFrozen {
        _checkDestination(to);
        uint256 bal = balanceOf(token);
        require(amount <= bal, "balance");
        _spendWindow(token, amount, bal);
        _send(token, to, amount);
    }

    // ---- panic ----------------------------------------------------------------------------

    /// Owner, cold key, any guardian, or (when `watchersOn`) any registered watcher can freeze all outflows
    /// for 24 hours. Guardian and watcher panics are attributed by event so the watcher market can settle them.
    function panic() external {
        if (msg.sender != owner && msg.sender != cold) {
            if (isGuardian[msg.sender]) {
                emit GuardianPanic(address(this), msg.sender);
            } else {
                require(watchersOn && address(watchers) != address(0) && watchers.isWatcher(msg.sender), "standing");
                emit WatcherPanic(address(this), msg.sender);
            }
            require(block.timestamp >= guardianMutedUntil, "muted");
            // sticky panic: a guardian may only re-panic in the last hour of a running freeze, never stack 24h freezes
            require(block.timestamp + 1 hours >= frozenUntil, "frozen: last hour only");
        }
        frozenUntil = uint64(block.timestamp + 24 hours);
        lastPanicAt = uint64(block.timestamp);
        rulesReadyAt = 0; // a panic also kills any pending hot-key rule change
        emit Panic(msg.sender, frozenUntil);
    }

    function unfreeze() external onlyCold {
        frozenUntil = 0;
        guardianMutedUntil = uint64(block.timestamp + 24 hours);
        emit Unfrozen(msg.sender);
    }

    // ---- guardians ------------------------------------------------------------------------

    /// Replace the guardian set. `_threshold` 0 picks the default (2 if >= 3 guardians, else all).
    /// Any running recovery and all pending votes are voided: the set that voted no longer exists.
    function setGuardians(address[] calldata g, uint8 _threshold) external onlyCold {
        _setGuardians(g, _threshold);
        _clearRecovery();
    }

    function guardianCount() external view returns (uint256) { return guardians.length; }
    function getGuardians() external view returns (address[] memory) { return guardians; }

    function _setGuardians(address[] memory g, uint8 _threshold) internal {
        require(g.length <= MAX_GUARDIANS, "max 5");
        for (uint256 i; i < guardians.length; ++i) isGuardian[guardians[i]] = false;
        delete guardians;
        for (uint256 i; i < g.length; ++i) {
            address a = g[i];
            require(a != address(0), "guardian 0");
            require(!isGuardian[a], "duplicate");
            isGuardian[a] = true;
            guardians.push(a);
        }
        if (g.length == 0) {
            require(_threshold == 0, "threshold");
            threshold = 0;
        } else {
            if (_threshold == 0) _threshold = g.length >= 3 ? 2 : uint8(g.length);
            require(_threshold <= g.length, "threshold");
            threshold = _threshold;
        }
        emit GuardiansSet(g, threshold);
    }

    // ---- recovery -------------------------------------------------------------------------

    /// A guardian votes to replace the cold key. The `threshold`-th distinct vote for the same candidate
    /// starts the 7-day timer. Votes are per candidate; they are forgotten on cancel, execute, a guardian-set
    /// change or a cold-key change. While a recovery is running no further votes are accepted.
    function proposeCold(address newCold) external {
        require(!recoveryOff, "recovery off");
        require(isGuardian[msg.sender], "guardian");
        require(newCold != address(0) && newCold != cold, "newCold");
        require(recoveryReadyAt == 0, "recovery active");
        uint256 e = recoveryEpoch;
        require(!hasVoted[e][newCold][msg.sender], "voted");
        hasVoted[e][newCold][msg.sender] = true;
        uint8 v = ++votesFor[e][newCold];
        emit RecoveryVote(msg.sender, newCold, v, threshold);
        if (v >= threshold) {
            proposedCold = newCold;
            recoveryReadyAt = uint64(block.timestamp + RECOVERY_DELAY);
            emit RecoveryStarted(newCold, recoveryReadyAt);
        }
    }

    /// The current cold key stops a recovery (and forgets every pending vote) at any time before it executes.
    function cancelRecovery() external onlyCold {
        require(recoveryReadyAt != 0, "no recovery");
        _clearRecovery();
        emit RecoveryCancelled(msg.sender);
    }

    /// Cold key switches guardian recovery off (or back on). Switching it off cancels any running recovery and
    /// forgets every pending vote; while off, `proposeCold` reverts. Personal Sanctums default to on; the bounty
    /// Sanctum's cold key (BountyCold) switches it off in its constructor and has no way to switch it back.
    function setRecoveryOff(bool off) external onlyCold {
        recoveryOff = off;
        if (off) {
            if (recoveryReadyAt != 0) emit RecoveryCancelled(msg.sender);
            _clearRecovery();
        }
        emit RecoveryOffSet(off);
    }

    /// Anyone, once the 7 days are up. The new cold key inherits everything (it can unfreeze, rotate the hot key).
    function executeRecovery() external {
        require(recoveryReadyAt != 0, "no recovery");
        require(block.timestamp >= recoveryReadyAt, "waiting");
        address oldCold = cold;
        address newCold = proposedCold;
        cold = newCold;
        _clearRecovery();
        emit ColdSet(oldCold, newCold);
        emit RecoveryExecuted(oldCold, newCold);
    }

    function _clearRecovery() internal {
        proposedCold = address(0);
        recoveryReadyAt = 0;
        recoveryEpoch++;
    }

    // ---- rules ----------------------------------------------------------------------------

    /// Hot key proposes new rules; they apply after max(current delay, 3 days). Cold key applies at once.
    /// Tighten-only for EVERY field on the hot-key path: capBps / dayCapBps / delayBps may only go down, delay only
    /// up, and the allowlist can't be switched off. A stolen hot key that waits out the 3 days gains nothing.
    function proposeRules(Rules calldata r) external onlyOwner notFrozen {
        _checkRules(r);
        _tightenOnly(r);
        pendingRules = r;
        uint256 d = rules.delay > MIN_RULES_DELAY ? rules.delay : MIN_RULES_DELAY;
        rulesReadyAt = uint64(block.timestamp + d);
        emit RulesProposed(r, rulesReadyAt);
    }

    function applyRules() external onlyOwner notFrozen {
        require(rulesReadyAt != 0 && block.timestamp >= rulesReadyAt, "waiting");
        _tightenOnly(pendingRules); // re-checked: the cold key may have tightened in between
        rules = pendingRules;
        rulesReadyAt = 0;
        emit RulesApplied(rules);
    }

    function coldSetRules(Rules calldata r) external onlyCold {
        _checkRules(r);
        rules = r;
        rulesReadyAt = 0;
        emit RulesApplied(r);
    }

    function setAllowlist(address a, bool on) external onlyCold {
        allowlisted[a] = on;
        emit Allowlist(a, on);
    }

    /// A cold-key rotation also voids any running recovery: the new cold key starts clean.
    function setCold(address c) external onlyCold { require(c != address(0), "cold"); emit ColdSet(cold, c); cold = c; _clearRecovery(); }
    function setOwner(address o) external onlyCold { require(o != address(0), "owner"); emit OwnerSet(owner, o); owner = o; }
    function setBlacklist(address b) external onlyCold { emit BlacklistSet(address(blacklist), b); blacklist = IBlacklist(b); }
    /// Replace the watcher registry, or address(0) to make `watchersOn` a no-op.
    function setWatcherRegistry(address w) external onlyCold { emit WatcherRegistrySet(address(watchers), w); watchers = IWatcherRegistry(w); }
    function setWatchersOn(bool on) external onlyCold { watchersOn = on; emit WatchersOnSet(on); }
    function setRequireApproval(bool on) external onlyCold { requireApproval = on; emit RequireApprovalSet(on); }

    function queueLength() external view returns (uint256) { return queue.length; }

    // ---- internals ------------------------------------------------------------------------

    function _checkRules(Rules memory r) internal pure {
        require(r.capBps <= 10_000 && r.dayCapBps <= 10_000 && r.delayBps <= 10_000, "bps");
    }

    function _tightenOnly(Rules memory r) internal view {
        Rules memory c = rules;
        require(r.dayCapBps <= c.dayCapBps, "day cap: tighten only");
        // a shorter delay is a loosening too: delay 0 + low delayBps would queue-and-execute in one block
        require(r.delay >= c.delay, "delay: tighten only");
        require(r.capBps <= c.capBps, "cap: tighten only");
        require(r.delayBps <= c.delayBps, "delayBps: tighten only");
        require(!(c.allowlistOn && !r.allowlistOn), "allowlist: tighten only");
    }

    function _checkDestination(address to) internal view {
        require(to != address(0), "to");
        if (address(blacklist) != address(0)) require(!blacklist.isFlagged(to), "blacklisted");
        if (rules.allowlistOn) require(allowlisted[to], "not allowlisted");
    }

    /// Two limits per asset: a fixed one-hour window (capBps, measured against the balance at the window's
    /// start) and a ROLLING 24 hours (dayCapBps) kept as hourly buckets: every outflow counts for at least
    /// 24 hours after it, so there is no boundary where two days' allowance can be taken back to back.
    /// The daily cap is measured against current balance + what left in the last 24h (the balance a day
    /// ago, ignoring deposits), so spending in small pieces does not shrink or raise the allowance.
    function _spendWindow(address token, uint256 amount, uint256 bal) internal {
        if (block.timestamp >= windowStart[token] + 1 hours) {
            windowStart[token] = uint64(block.timestamp);
            windowBalance[token] = bal;
            windowSpent[token] = 0;
        }
        uint256 cap = windowBalance[token] * rules.capBps / 10_000;
        require(windowSpent[token] + amount <= cap, "hourly cap");
        windowSpent[token] += amount;

        uint64 h = uint64(block.timestamp / 1 hours);
        uint256 spent24 = daySpentRolling(token);
        uint256 dayCap = (bal + spent24) * rules.dayCapBps / 10_000;
        require(spent24 + amount <= dayCap, "daily cap");
        HourSlot storage sl = daySlots[token][h % 25];
        if (sl.hour != h) { sl.hour = h; sl.spent = 0; }
        sl.spent += uint192(amount);
    }

    /// How much of `token` can leave right now without hitting the hourly or the daily cap.
    function capRoom(address token) public view returns (uint256) {
        uint256 bal = balanceOf(token);
        uint256 hourBal = block.timestamp >= windowStart[token] + 1 hours ? bal : windowBalance[token];
        uint256 hourSpent = block.timestamp >= windowStart[token] + 1 hours ? 0 : windowSpent[token];
        uint256 hourCap = hourBal * rules.capBps / 10_000;
        uint256 hRoom = hourCap > hourSpent ? hourCap - hourSpent : 0;
        uint256 spent24 = daySpentRolling(token);
        uint256 dayCap = (bal + spent24) * rules.dayCapBps / 10_000;
        uint256 dRoom = dayCap > spent24 ? dayCap - spent24 : 0;
        return hRoom < dRoom ? hRoom : dRoom;
    }

    /// Immediate (capped) outflow of `token` over the current rolling 24 hours: the current hour bucket plus the
    /// 24 before it, so every outflow stays counted for AT LEAST 24 wall-clock hours (24–25h, depending on where in
    /// its hour it happened). A 24-bucket ring ([h-23, h]) would forget an outflow after 23–24h and let a
    /// strict 24h window hold one extra hourly cap (found by the step-3 bounty robber simulation).
    function daySpentRolling(address token) public view returns (uint256 sum) {
        uint64 h = uint64(block.timestamp / 1 hours);
        HourSlot[25] storage slots = daySlots[token];
        for (uint256 i; i < 25; ++i) {
            HourSlot memory sl = slots[i];
            if (sl.hour + 25 > h) sum += sl.spent; // hours [h-24, h]
        }
    }

    function _send(address token, address to, uint256 amount) internal {
        if (token == ETH) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "eth send");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Sent(token, to, amount);
    }
}
