//! Uroboros Sanctum (Solana): a rate-limited, delayed, freezable vault for one wallet.
//!
//! Port of `src/Sanctum.sol` (behaviour, not code). Funds live in the Sanctum's vault PDA, not in the hot wallet.
//! A stolen hot key can move at most `cap_bps` of each asset per fixed hour and `day_cap_bps` per rolling 24h
//! (25 hourly buckets, so every outflow counts for at least 24h); anything above `delay_bps` of the balance, or
//! above the remaining cap room, waits `delay_secs` in a queue the hot or cold key can cancel. The hot key, the cold
//! key or any guardian can panic (24h freeze, which also voids everything queued before it). Only the cold key
//! unfreezes; guardians are muted for 24h after a cold unfreeze and may only re-panic in the last hour of a freeze.
//!
//! v1 scope (Nov 2026): no protocol fee, no guardian recovery, no allowlist/blacklist, no admin hook on Sanctums.
//!
//! Watcher nodes (v1): operators stake the protocol token (Token-2022) into the program. A staked node may panic a
//! Sanctum ONLY if its cold key switched `watchers_on` (which forces `approval_mode`), and ONLY on a queue item that
//! is live, unapproved by the cold key, and in its final hour. The program checks this, so a false freeze is
//! impossible by construction. Slashing in v1 is decided by the team (admin) key and burns the slashed tokens.
//! Node rewards: none on-chain in v1.
//!
//! Custody:
//!  - SOL: the `vault` PDA (["vault", sanctum]) is a plain system account; the program moves lamports out with a
//!    system transfer signed by the PDA seeds. It keeps the rent-exempt minimum for a 0-byte account; the usable
//!    balance is `lamports - rent_min`.
//!  - SPL Token and Token-2022: the vault PDA's associated token account per mint (authority = vault PDA).
//!    So one address (the vault) receives both SOL and tokens.
use anchor_lang::prelude::*;
use anchor_lang::system_program;
use anchor_spl::associated_token::AssociatedToken;
use anchor_spl::token_interface::{self, Burn, Mint, TokenAccount, TokenInterface, TransferChecked};

declare_id!("C4Q1Q28WEDH7MmGANTZutwB6Bwh278UbgBmLkeBxjVpj");

pub const MAX_GUARDIANS: usize = 3;
pub const HOUR: i64 = 3600;
pub const DAY: i64 = 24 * HOUR;
pub const FREEZE_SECS: i64 = DAY;
pub const MUTE_SECS: i64 = DAY;
pub const MIN_RULES_DELAY: i64 = 3 * DAY;
pub const RING: usize = 25;
/// Mint key used for the SOL cap state and SOL queue items.
pub const SOL_MINT: Pubkey = Pubkey::new_from_array([0u8; 32]);

pub const SANCTUM_SEED: &[u8] = b"sanctum";
pub const VAULT_SEED: &[u8] = b"vault";
pub const CAP_SEED: &[u8] = b"cap";
pub const QUEUE_SEED: &[u8] = b"q";
pub const CONFIG_SEED: &[u8] = b"config";
pub const STAKE_VAULT_SEED: &[u8] = b"stake_vault";
pub const NODE_SEED: &[u8] = b"node";
/// A watcher may panic on an unapproved queue item only in its final hour (now >= ready_at - 1h).
pub const WATCH_WINDOW: i64 = HOUR;

#[program]
pub mod sanctum {
    use super::*;

    /// The hot key creates a Sanctum (PDA per hot key + nonce) and funds the SOL vault's rent-exempt minimum.
    pub fn create(
        ctx: Context<Create>,
        nonce: u64,
        cold: Pubkey,
        guardians: Vec<Pubkey>,
        rules: Option<Rules>,
    ) -> Result<()> {
        let hot = ctx.accounts.hot.key();
        require!(cold != Pubkey::default() && cold != hot, SanctumError::BadKey);
        let rules = rules.unwrap_or_default();
        rules.check()?;
        let s = &mut ctx.accounts.sanctum;
        s.creator = hot;
        s.nonce = nonce;
        s.hot = hot;
        s.cold = cold;
        s.set_guardians(&guardians)?;
        s.rules = rules;
        s.pending_rules = rules;
        s.rules_ready_at = 0;
        s.frozen_until = 0;
        s.last_panic_at = 0;
        s.guardian_muted_until = 0;
        s.panic_epoch = 0;
        s.queue_seq = 0;
        s.bump = ctx.bumps.sanctum;
        s.vault_bump = ctx.bumps.vault;
        s.watchers_on = false;
        s.approval_mode = false;

        // Fund the vault's rent-exempt minimum so every later transfer keeps it a valid system account.
        let rent_min = Rent::get()?.minimum_balance(0);
        let have = ctx.accounts.vault.lamports();
        if have < rent_min {
            system_program::transfer(
                CpiContext::new(
                    ctx.accounts.system_program.key(),
                    system_program::Transfer {
                        from: ctx.accounts.hot.to_account_info(),
                        to: ctx.accounts.vault.to_account_info(),
                    },
                ),
                rent_min - have,
            )?;
        }
        emit!(Created { sanctum: s.key(), hot, cold, vault: ctx.accounts.vault.key() });
        Ok(())
    }

    /// Anyone may deposit SOL (a plain transfer to the vault address works too).
    pub fn deposit_sol(ctx: Context<DepositSol>, amount: u64) -> Result<()> {
        system_program::transfer(
            CpiContext::new(
                ctx.accounts.system_program.key(),
                system_program::Transfer {
                    from: ctx.accounts.depositor.to_account_info(),
                    to: ctx.accounts.vault.to_account_info(),
                },
            ),
            amount,
        )?;
        emit!(Deposited { sanctum: ctx.accounts.sanctum.key(), mint: SOL_MINT, amount });
        Ok(())
    }

    /// Anyone may deposit SPL / Token-2022 tokens; creates the vault's ATA if needed.
    pub fn deposit_token(ctx: Context<DepositToken>, amount: u64) -> Result<()> {
        token_interface::transfer_checked(
            CpiContext::new(
                ctx.accounts.token_program.key(),
                TransferChecked {
                    from: ctx.accounts.from.to_account_info(),
                    mint: ctx.accounts.mint.to_account_info(),
                    to: ctx.accounts.vault_ata.to_account_info(),
                    authority: ctx.accounts.depositor.to_account_info(),
                },
            ),
            amount,
            ctx.accounts.mint.decimals,
        )?;
        emit!(Deposited { sanctum: ctx.accounts.sanctum.key(), mint: ctx.accounts.mint.key(), amount });
        Ok(())
    }

    /// Hot key. Pays now if inside the hourly + daily room and <= delay_bps of balance; otherwise queues.
    pub fn withdraw_sol(ctx: Context<WithdrawSol>, amount: u64) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let s = &ctx.accounts.sanctum;
        require!(now >= s.frozen_until, SanctumError::Frozen);
        let bal = sol_balance(&ctx.accounts.vault.to_account_info())?;
        let to = ctx.accounts.to.key();
        require!(to != ctx.accounts.vault.key(), SanctumError::BadDestination);
        if needs_queue(s, &ctx.accounts.cap, bal, amount, now)? {
            let sanctum_key = s.key();
            open_queued(
                &mut ctx.accounts.sanctum,
                sanctum_key,
                &ctx.accounts.queued,
                &ctx.accounts.hot.to_account_info(),
                &ctx.accounts.system_program.to_account_info(),
                SOL_MINT,
                to,
                amount,
                now,
            )?;
            return Ok(());
        }
        let rules = ctx.accounts.sanctum.rules;
        ctx.accounts.cap.spend(&rules, amount, bal, now)?;
        send_sol(&ctx.accounts.sanctum, &ctx.accounts.vault, &ctx.accounts.to, &ctx.accounts.system_program, amount)?;
        emit!(Sent { sanctum: ctx.accounts.sanctum.key(), mint: SOL_MINT, to, amount });
        Ok(())
    }

    /// Hot key, tokens. Same rules as `withdraw_sol`; `to` must be a token account of the same mint.
    pub fn withdraw_token(ctx: Context<WithdrawToken>, amount: u64) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let s = &ctx.accounts.sanctum;
        require!(now >= s.frozen_until, SanctumError::Frozen);
        let bal = ctx.accounts.vault_ata.amount;
        let to = ctx.accounts.to.key();
        require!(to != ctx.accounts.vault_ata.key(), SanctumError::BadDestination);
        if needs_queue(s, &ctx.accounts.cap, bal, amount, now)? {
            let sanctum_key = s.key();
            open_queued(
                &mut ctx.accounts.sanctum,
                sanctum_key,
                &ctx.accounts.queued,
                &ctx.accounts.hot.to_account_info(),
                &ctx.accounts.system_program.to_account_info(),
                ctx.accounts.mint.key(),
                to,
                amount,
                now,
            )?;
            return Ok(());
        }
        let rules = ctx.accounts.sanctum.rules;
        ctx.accounts.cap.spend(&rules, amount, bal, now)?;
        send_token(
            &ctx.accounts.sanctum,
            &ctx.accounts.vault,
            &ctx.accounts.vault_ata,
            &ctx.accounts.to,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
            amount,
        )?;
        emit!(Sent { sanctum: ctx.accounts.sanctum.key(), mint: ctx.accounts.mint.key(), to, amount });
        Ok(())
    }

    /// Hot or cold, after ready_at, not frozen, not voided by a later panic. Pays in full (the delay replaced the caps).
    pub fn execute_queued_sol(ctx: Context<ExecuteQueuedSol>) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let q = &ctx.accounts.queued;
        check_executable(&ctx.accounts.sanctum, &ctx.accounts.signer.key(), q, now)?;
        require!(q.mint == SOL_MINT, SanctumError::WrongAsset);
        require!(q.to == ctx.accounts.to.key(), SanctumError::BadDestination);
        let bal = sol_balance(&ctx.accounts.vault.to_account_info())?;
        require!(q.amount <= bal, SanctumError::Balance);
        let amount = q.amount;
        send_sol(&ctx.accounts.sanctum, &ctx.accounts.vault, &ctx.accounts.to, &ctx.accounts.system_program, amount)?;
        emit!(QueueExecuted { sanctum: ctx.accounts.sanctum.key(), seq: q.seq, mint: SOL_MINT, to: q.to, amount });
        Ok(())
    }

    pub fn execute_queued_token(ctx: Context<ExecuteQueuedToken>) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let q = &ctx.accounts.queued;
        check_executable(&ctx.accounts.sanctum, &ctx.accounts.signer.key(), q, now)?;
        require!(q.mint == ctx.accounts.mint.key(), SanctumError::WrongAsset);
        require!(q.to == ctx.accounts.to.key(), SanctumError::BadDestination);
        require!(q.amount <= ctx.accounts.vault_ata.amount, SanctumError::Balance);
        let amount = q.amount;
        send_token(
            &ctx.accounts.sanctum,
            &ctx.accounts.vault,
            &ctx.accounts.vault_ata,
            &ctx.accounts.to,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
            amount,
        )?;
        emit!(QueueExecuted { sanctum: ctx.accounts.sanctum.key(), seq: q.seq, mint: q.mint, to: q.to, amount });
        Ok(())
    }

    /// Hot or cold. Closes the queue item (rent back to whoever paid for it). Works on voided items too.
    pub fn cancel_queued(ctx: Context<CancelQueued>) -> Result<()> {
        let s = &ctx.accounts.sanctum;
        let k = ctx.accounts.signer.key();
        require!(k == s.hot || k == s.cold, SanctumError::Unauthorized);
        emit!(QueueCancelled { sanctum: s.key(), seq: ctx.accounts.queued.seq, by: k });
        Ok(())
    }

    /// Cold key vouches for an item queued while guardians were muted (after a cold unfreeze). It still waits
    /// out the delay and is still voided by a later panic.
    pub fn approve_queued(ctx: Context<ApproveQueued>) -> Result<()> {
        ctx.accounts.queued.approved = true;
        emit!(QueueApproved { sanctum: ctx.accounts.sanctum.key(), seq: ctx.accounts.queued.seq });
        Ok(())
    }

    /// Cold-key withdrawal: skips the queue, never the hourly/daily caps or a freeze.
    pub fn cold_withdraw_sol(ctx: Context<ColdWithdrawSol>, amount: u64) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        require!(now >= ctx.accounts.sanctum.frozen_until, SanctumError::Frozen);
        let bal = sol_balance(&ctx.accounts.vault.to_account_info())?;
        require!(ctx.accounts.to.key() != ctx.accounts.vault.key(), SanctumError::BadDestination);
        require!(amount <= bal, SanctumError::Balance);
        let rules = ctx.accounts.sanctum.rules;
        ctx.accounts.cap.spend(&rules, amount, bal, now)?;
        send_sol(&ctx.accounts.sanctum, &ctx.accounts.vault, &ctx.accounts.to, &ctx.accounts.system_program, amount)?;
        emit!(Sent { sanctum: ctx.accounts.sanctum.key(), mint: SOL_MINT, to: ctx.accounts.to.key(), amount });
        Ok(())
    }

    pub fn cold_withdraw_token(ctx: Context<ColdWithdrawToken>, amount: u64) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        require!(now >= ctx.accounts.sanctum.frozen_until, SanctumError::Frozen);
        let bal = ctx.accounts.vault_ata.amount;
        require!(ctx.accounts.to.key() != ctx.accounts.vault_ata.key(), SanctumError::BadDestination);
        require!(amount <= bal, SanctumError::Balance);
        let rules = ctx.accounts.sanctum.rules;
        ctx.accounts.cap.spend(&rules, amount, bal, now)?;
        send_token(
            &ctx.accounts.sanctum,
            &ctx.accounts.vault,
            &ctx.accounts.vault_ata,
            &ctx.accounts.to,
            &ctx.accounts.mint,
            &ctx.accounts.token_program,
            amount,
        )?;
        emit!(Sent { sanctum: ctx.accounts.sanctum.key(), mint: ctx.accounts.mint.key(), to: ctx.accounts.to.key(), amount });
        Ok(())
    }

    /// Hot, cold or any guardian: freeze all outflows for 24h and void everything queued so far.
    /// Guardians: muted for 24h after a cold unfreeze; may only re-panic in the last hour of a running freeze.
    pub fn panic(ctx: Context<Panic>) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let k = ctx.accounts.signer.key();
        let s = &mut ctx.accounts.sanctum;
        let guardian = k != s.hot && k != s.cold;
        if k == s.hot && k != s.cold {
            // a thief holding the hot key could otherwise re-freeze forever after each cold unfreeze
            require!(now >= s.guardian_muted_until, SanctumError::GuardianMuted);
        }
        if guardian {
            require!(s.is_guardian(&k), SanctumError::Unauthorized);
            require!(now >= s.guardian_muted_until, SanctumError::GuardianMuted);
            require!(now + HOUR >= s.frozen_until, SanctumError::FrozenLastHourOnly);
        }
        s.frozen_until = now + FREEZE_SECS;
        s.last_panic_at = now;
        s.panic_epoch = s.panic_epoch.checked_add(1).ok_or(SanctumError::Math)?;
        s.rules_ready_at = 0; // a panic also kills a pending hot-key rule change
        emit!(Panicked { sanctum: s.key(), by: k, guardian, until: s.frozen_until });
        Ok(())
    }

    pub fn unfreeze(ctx: Context<ColdOnly>) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let s = &mut ctx.accounts.sanctum;
        s.frozen_until = 0;
        s.guardian_muted_until = now + MUTE_SECS;
        emit!(Unfrozen { sanctum: s.key(), muted_until: s.guardian_muted_until });
        Ok(())
    }

    /// Cold key: unfreeze and replace the (presumed stolen) hot key in one step, so a thief cannot re-panic.
    pub fn unfreeze_and_rotate(ctx: Context<ColdOnly>, new_hot: Pubkey) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let s = &mut ctx.accounts.sanctum;
        require!(new_hot != Pubkey::default() && new_hot != s.cold, SanctumError::BadKey);
        s.hot = new_hot;
        s.rules_ready_at = 0;
        s.frozen_until = 0;
        s.guardian_muted_until = now + MUTE_SECS;
        emit!(Unfrozen { sanctum: s.key(), muted_until: s.guardian_muted_until });
        emit!(KeysChanged { sanctum: s.key(), hot: s.hot, cold: s.cold, guardian_count: s.guardian_count });
        Ok(())
    }

    pub fn set_guardians(ctx: Context<ColdOnly>, guardians: Vec<Pubkey>) -> Result<()> {
        let s = &mut ctx.accounts.sanctum;
        s.set_guardians(&guardians)?;
        emit!(KeysChanged { sanctum: s.key(), hot: s.hot, cold: s.cold, guardian_count: s.guardian_count });
        Ok(())
    }

    pub fn set_cold(ctx: Context<ColdOnly>, new_cold: Pubkey) -> Result<()> {
        let s = &mut ctx.accounts.sanctum;
        require!(new_cold != Pubkey::default() && new_cold != s.hot, SanctumError::BadKey);
        s.cold = new_cold;
        emit!(KeysChanged { sanctum: s.key(), hot: s.hot, cold: s.cold, guardian_count: s.guardian_count });
        Ok(())
    }

    pub fn set_hot(ctx: Context<ColdOnly>, new_hot: Pubkey) -> Result<()> {
        let s = &mut ctx.accounts.sanctum;
        require!(new_hot != Pubkey::default() && new_hot != s.cold, SanctumError::BadKey);
        s.hot = new_hot;
        s.rules_ready_at = 0; // a pending proposal by the old hot key dies with it
        emit!(KeysChanged { sanctum: s.key(), hot: s.hot, cold: s.cold, guardian_count: s.guardian_count });
        Ok(())
    }

    /// Cold key sets any rules, at once. Cancels a pending hot-key proposal.
    pub fn cold_set_rules(ctx: Context<ColdOnly>, rules: Rules) -> Result<()> {
        rules.check()?;
        let s = &mut ctx.accounts.sanctum;
        s.rules = rules;
        s.rules_ready_at = 0;
        emit!(RulesApplied { sanctum: s.key(), rules });
        Ok(())
    }

    /// Hot key proposes TIGHTER rules; they apply after max(current delay, 3 days).
    pub fn propose_rules(ctx: Context<HotOnly>, rules: Rules) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let s = &mut ctx.accounts.sanctum;
        require!(now >= s.frozen_until, SanctumError::Frozen);
        rules.check()?;
        s.rules.tighten_only(&rules)?;
        let d = std::cmp::max(s.rules.delay_secs, MIN_RULES_DELAY);
        s.pending_rules = rules;
        s.rules_ready_at = now + d;
        emit!(RulesProposed { sanctum: s.key(), rules, ready_at: s.rules_ready_at });
        Ok(())
    }

    pub fn apply_rules(ctx: Context<HotOnly>) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let s = &mut ctx.accounts.sanctum;
        require!(now >= s.frozen_until, SanctumError::Frozen);
        require!(s.rules_ready_at != 0 && now >= s.rules_ready_at, SanctumError::NotReady);
        let p = s.pending_rules;
        s.rules.tighten_only(&p)?; // re-checked: the cold key may have tightened in between
        s.rules = p;
        s.rules_ready_at = 0;
        emit!(RulesApplied { sanctum: s.key(), rules: p });
        Ok(())
    }

    /// Cold key: watcher coverage on/off and approval mode. Watchers require approval mode (otherwise every
    /// legitimate queued transfer would be frozen in its final hour).
    pub fn set_modes(ctx: Context<ColdOnly>, watchers_on: bool, approval_mode: bool) -> Result<()> {
        require!(!watchers_on || approval_mode, SanctumError::WatchersNeedApproval);
        let s = &mut ctx.accounts.sanctum;
        s.watchers_on = watchers_on;
        s.approval_mode = approval_mode;
        emit!(ModesSet { sanctum: s.key(), watchers_on, approval_mode });
        Ok(())
    }

    // ------------------------------------------------------------ watcher nodes

    /// Once, by the program's upgrade authority, right after the token exists. Stores that key as staking admin.
    pub fn init_staking(ctx: Context<InitStaking>, min_stake: u64, unstake_cooldown_secs: i64) -> Result<()> {
        require!(min_stake > 0, SanctumError::BadStakeConfig);
        require!(unstake_cooldown_secs >= 0 && unstake_cooldown_secs <= 365 * DAY, SanctumError::BadStakeConfig);
        let c = &mut ctx.accounts.config;
        c.admin = ctx.accounts.admin.key();
        c.mint = ctx.accounts.mint.key();
        c.token_program = ctx.accounts.token_program.key();
        c.stake_vault = ctx.accounts.stake_vault.key();
        c.min_stake = min_stake;
        c.unstake_cooldown = unstake_cooldown_secs;
        c.total_staked = 0;
        c.node_count = 0;
        c.bump = ctx.bumps.config;
        c.vault_bump = ctx.bumps.stake_vault;
        emit!(StakingInitialized { admin: c.admin, mint: c.mint, min_stake, unstake_cooldown: unstake_cooldown_secs });
        Ok(())
    }

    pub fn register_node(ctx: Context<RegisterNode>, amount: u64) -> Result<()> {
        let received = stake_in(&mut ctx.accounts.stake_accounts(), amount)?;
        let c = &mut ctx.accounts.config;
        require!(received >= c.min_stake, SanctumError::BelowMinStake);
        let n = &mut ctx.accounts.node;
        n.operator = ctx.accounts.operator.key();
        n.stake = received;
        n.unstake_at = 0;
        n.registered_at = Clock::get()?.unix_timestamp;
        n.slashed_total = 0;
        n.panics = 0;
        n.bump = ctx.bumps.node;
        c.total_staked = c.total_staked.checked_add(received).ok_or(SanctumError::Math)?;
        c.node_count = c.node_count.checked_add(1).ok_or(SanctumError::Math)?;
        emit!(NodeRegistered { node: n.key(), operator: n.operator, stake: received });
        Ok(())
    }

    pub fn add_stake(ctx: Context<AddStake>, amount: u64) -> Result<()> {
        require!(ctx.accounts.node.unstake_at == 0, SanctumError::Unstaking);
        let received = stake_in(&mut ctx.accounts.stake_accounts(), amount)?;
        let n = &mut ctx.accounts.node;
        n.stake = n.stake.checked_add(received).ok_or(SanctumError::Math)?;
        let c = &mut ctx.accounts.config;
        c.total_staked = c.total_staked.checked_add(received).ok_or(SanctumError::Math)?;
        emit!(Staked { node: n.key(), operator: n.operator, amount: received, stake: n.stake });
        Ok(())
    }

    /// Starts the cooldown for the whole stake. The node cannot panic from now on; it stays slashable.
    pub fn request_unstake(ctx: Context<NodeOp>) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let n = &mut ctx.accounts.node;
        require!(n.unstake_at == 0, SanctumError::Unstaking);
        n.unstake_at = now + ctx.accounts.config.unstake_cooldown;
        emit!(UnstakeRequested { node: n.key(), operator: n.operator, stake: n.stake, ready_at: n.unstake_at });
        Ok(())
    }

    /// After the cooldown: everything left goes back to the operator and the node account closes.
    pub fn withdraw_stake(ctx: Context<WithdrawStake>) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let n = &ctx.accounts.node;
        require!(n.unstake_at != 0 && now >= n.unstake_at, SanctumError::NotReady);
        let amount = n.stake;
        if amount > 0 {
            let seeds: &[&[u8]] = &[CONFIG_SEED, &[ctx.accounts.config.bump]];
            token_interface::transfer_checked(
                CpiContext::new_with_signer(
                    ctx.accounts.token_program.key(),
                    TransferChecked {
                        from: ctx.accounts.stake_vault.to_account_info(),
                        mint: ctx.accounts.mint.to_account_info(),
                        to: ctx.accounts.operator_ata.to_account_info(),
                        authority: ctx.accounts.config.to_account_info(),
                    },
                    &[seeds],
                ),
                amount,
                ctx.accounts.mint.decimals,
            )?;
        }
        let c = &mut ctx.accounts.config;
        c.total_staked = c.total_staked.checked_sub(amount).ok_or(SanctumError::Math)?;
        c.node_count = c.node_count.saturating_sub(1);
        emit!(StakeWithdrawn { node: ctx.accounts.node.key(), operator: ctx.accounts.operator.key(), amount });
        Ok(())
    }

    /// v1: slashing is decided by the team (admin) key. The slashed tokens are burned.
    pub fn slash(ctx: Context<Slash>, amount: u64, reason_code: u16) -> Result<()> {
        let n = &mut ctx.accounts.node;
        require!(amount > 0 && amount <= n.stake, SanctumError::Balance);
        let seeds: &[&[u8]] = &[CONFIG_SEED, &[ctx.accounts.config.bump]];
        token_interface::burn(
            CpiContext::new_with_signer(
                ctx.accounts.token_program.key(),
                Burn {
                    mint: ctx.accounts.mint.to_account_info(),
                    from: ctx.accounts.stake_vault.to_account_info(),
                    authority: ctx.accounts.config.to_account_info(),
                },
                &[seeds],
            ),
            amount,
        )?;
        n.stake -= amount;
        n.slashed_total = n.slashed_total.checked_add(amount).ok_or(SanctumError::Math)?;
        let c = &mut ctx.accounts.config;
        c.total_staked = c.total_staked.checked_sub(amount).ok_or(SanctumError::Math)?;
        emit!(Slashed { node: n.key(), operator: n.operator, amount, reason_code, stake_left: n.stake });
        Ok(())
    }

    /// A staked, active node freezes a Sanctum that opted in, citing a live, unapproved queue item in its final hour.
    /// Same limits as a guardian: muted 24h after a cold unfreeze, re-panic only in the last hour of a freeze.
    pub fn watcher_panic(ctx: Context<WatcherPanic>) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let c = &ctx.accounts.config;
        let n = &mut ctx.accounts.node;
        require!(n.unstake_at == 0 && n.stake >= c.min_stake, SanctumError::NodeNotActive);
        let s = &mut ctx.accounts.sanctum;
        let q = &ctx.accounts.queued;
        require!(s.watchers_on, SanctumError::WatchersOff);
        require!(q.panic_epoch == s.panic_epoch, SanctumError::VoidedByPanic);
        require!(!q.approved, SanctumError::QueueApproved);
        require!(now >= q.ready_at - WATCH_WINDOW, SanctumError::NotFinalHour);
        require!(now >= s.guardian_muted_until, SanctumError::GuardianMuted);
        require!(now + HOUR >= s.frozen_until, SanctumError::FrozenLastHourOnly);
        s.frozen_until = now + FREEZE_SECS;
        s.last_panic_at = now;
        s.panic_epoch = s.panic_epoch.checked_add(1).ok_or(SanctumError::Math)?;
        s.rules_ready_at = 0;
        n.panics = n.panics.saturating_add(1);
        emit!(WatcherPanicked { sanctum: s.key(), node: n.key(), operator: n.operator, seq: q.seq, until: s.frozen_until });
        Ok(())
    }
}

struct StakeIn<'a, 'info> {
    operator: &'a Signer<'info>,
    mint: &'a InterfaceAccount<'info, Mint>,
    from: &'a InterfaceAccount<'info, TokenAccount>,
    vault: &'a mut InterfaceAccount<'info, TokenAccount>,
    token_program: &'a Interface<'info, TokenInterface>,
}

/// Pull `amount` into the stake vault and return what actually arrived (robust to a transfer fee).
fn stake_in(a: &mut StakeIn, amount: u64) -> Result<u64> {
    require!(amount > 0, SanctumError::ZeroAmount);
    let before = a.vault.amount;
    token_interface::transfer_checked(
        CpiContext::new(
            a.token_program.key(),
            TransferChecked {
                from: a.from.to_account_info(),
                mint: a.mint.to_account_info(),
                to: a.vault.to_account_info(),
                authority: a.operator.to_account_info(),
            },
        ),
        amount,
        a.mint.decimals,
    )?;
    a.vault.reload()?;
    Ok(a.vault.amount.checked_sub(before).ok_or(SanctumError::Math)?)
}

// ---------------------------------------------------------------- state

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq, InitSpace)]
pub struct Rules {
    /// max outflow per asset per fixed hour, bps of the balance at the hour window's start
    pub cap_bps: u16,
    /// max outflow per asset per rolling 24h, bps of (balance + what left in the last 24h)
    pub day_cap_bps: u16,
    /// transfers above this share of the balance are queued
    pub delay_bps: u16,
    /// seconds a queued transfer waits
    pub delay_secs: i64,
}

impl Default for Rules {
    fn default() -> Self {
        Rules { cap_bps: 500, day_cap_bps: 1000, delay_bps: 1000, delay_secs: 6 * HOUR }
    }
}

impl Rules {
    fn check(&self) -> Result<()> {
        require!(
            self.cap_bps <= 10_000 && self.day_cap_bps <= 10_000 && self.delay_bps <= 10_000,
            SanctumError::BadRules
        );
        require!(self.delay_secs >= 0 && self.delay_secs <= 365 * DAY, SanctumError::BadRules);
        Ok(())
    }

    fn tighten_only(&self, r: &Rules) -> Result<()> {
        require!(r.cap_bps <= self.cap_bps, SanctumError::TightenOnly);
        require!(r.day_cap_bps <= self.day_cap_bps, SanctumError::TightenOnly);
        require!(r.delay_bps <= self.delay_bps, SanctumError::TightenOnly);
        require!(r.delay_secs >= self.delay_secs, SanctumError::TightenOnly);
        Ok(())
    }
}

#[account]
#[derive(InitSpace)]
pub struct Sanctum {
    pub creator: Pubkey, // seed; the first hot key
    pub nonce: u64,      // seed
    pub hot: Pubkey,
    pub cold: Pubkey,
    pub guardians: [Pubkey; MAX_GUARDIANS],
    pub guardian_count: u8,
    pub rules: Rules,
    pub pending_rules: Rules,
    pub rules_ready_at: i64,
    pub frozen_until: i64,
    pub last_panic_at: i64,
    pub guardian_muted_until: i64,
    /// bumped by every panic; a queue item is valid only while its epoch equals this
    pub panic_epoch: u64,
    pub queue_seq: u64,
    pub bump: u8,
    pub vault_bump: u8,
    /// cold opt-in: staked watcher nodes may panic on unapproved queue items in their final hour
    pub watchers_on: bool,
    /// every queued transfer needs cold approval before it can execute (forced on while watchers_on)
    pub approval_mode: bool,
}

impl Sanctum {
    fn is_guardian(&self, k: &Pubkey) -> bool {
        self.guardians[..self.guardian_count as usize].contains(k)
    }

    fn set_guardians(&mut self, g: &[Pubkey]) -> Result<()> {
        require!(g.len() <= MAX_GUARDIANS, SanctumError::TooManyGuardians);
        let mut out = [Pubkey::default(); MAX_GUARDIANS];
        for (i, a) in g.iter().enumerate() {
            require!(*a != Pubkey::default(), SanctumError::BadKey);
            require!(!g[..i].contains(a), SanctumError::DuplicateGuardian);
            out[i] = *a;
        }
        self.guardians = out;
        self.guardian_count = g.len() as u8;
        Ok(())
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Default, Debug, InitSpace)]
pub struct HourSlot {
    pub hour: i64,
    pub spent: u128,
}

/// Per (sanctum, mint) outflow accounting. mint = default pubkey for SOL. All sums are u128 (no truncation).
/// Daily-cap basis = current balance + capped outflow of the last 24h = (balance 24h ago + deposits since -
/// queued/other outflows since). A deposit can only raise the allowance by 10% of itself, and deposited funds
/// are locked under the same caps, so inflating the balance never lets more than 10% of (start + deposits) out.
#[account]
#[derive(InitSpace)]
pub struct CapState {
    pub sanctum: Pubkey,
    pub mint: Pubkey,
    pub window_start: i64,
    pub window_balance: u128,
    pub window_spent: u128,
    pub ring: [HourSlot; RING],
    pub initialized: bool,
}

impl CapState {
    fn day_spent(&self, now: i64) -> u128 {
        let h = now.div_euclid(HOUR);
        self.ring
            .iter()
            .filter(|sl| sl.spent > 0 && sl.hour + RING as i64 > h) // hours [h-24, h]
            .map(|sl| sl.spent)
            .sum()
    }

    /// How much can leave right now without hitting the hourly or the daily cap.
    pub fn room(&self, rules: &Rules, bal: u64, now: i64) -> u64 {
        let fresh = !self.initialized || now >= self.window_start + HOUR;
        let hour_bal = if fresh { bal as u128 } else { self.window_balance };
        let hour_spent = if fresh { 0 } else { self.window_spent };
        let hour_cap = hour_bal * rules.cap_bps as u128 / 10_000;
        let h_room = hour_cap.saturating_sub(hour_spent);
        let spent24 = self.day_spent(now);
        let day_cap = (bal as u128 + spent24) * rules.day_cap_bps as u128 / 10_000;
        let d_room = day_cap.saturating_sub(spent24);
        std::cmp::min(h_room, d_room).min(u64::MAX as u128) as u64
    }

    fn spend(&mut self, rules: &Rules, amount: u64, bal: u64, now: i64) -> Result<()> {
        if !self.initialized || now >= self.window_start + HOUR {
            self.initialized = true;
            self.window_start = now;
            self.window_balance = bal as u128;
            self.window_spent = 0;
        }
        let cap = self.window_balance * rules.cap_bps as u128 / 10_000;
        let ws = self.window_spent + amount as u128;
        require!(ws <= cap, SanctumError::HourlyCap);
        self.window_spent = ws;

        let spent24 = self.day_spent(now);
        let day_cap = (bal as u128 + spent24) * rules.day_cap_bps as u128 / 10_000;
        require!(spent24 + amount as u128 <= day_cap, SanctumError::DailyCap);
        let h = now.div_euclid(HOUR);
        let sl = &mut self.ring[h.rem_euclid(RING as i64) as usize];
        if sl.hour != h {
            sl.hour = h;
            sl.spent = 0;
        }
        sl.spent += amount as u128; // u128 slots: no truncation for any u64 amount
        Ok(())
    }
}

#[account]
#[derive(InitSpace)]
pub struct Queued {
    pub sanctum: Pubkey,
    pub seq: u64,
    pub mint: Pubkey, // default for SOL
    pub to: Pubkey,   // SOL: recipient account; token: recipient token account
    pub amount: u64,
    pub queued_at: i64,
    pub ready_at: i64,
    pub panic_epoch: u64,
    pub approved: bool,
    pub payer: Pubkey,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub admin: Pubkey,
    pub mint: Pubkey,
    pub token_program: Pubkey,
    pub stake_vault: Pubkey,
    pub min_stake: u64,
    pub unstake_cooldown: i64,
    pub total_staked: u64,
    pub node_count: u64,
    pub bump: u8,
    pub vault_bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Node {
    pub operator: Pubkey,
    pub stake: u64,
    /// 0 = active; otherwise the time the cooldown ends (node can no longer panic)
    pub unstake_at: i64,
    pub registered_at: i64,
    pub slashed_total: u64,
    pub panics: u64,
    pub bump: u8,
}

// ---------------------------------------------------------------- helpers

fn sol_balance(vault: &AccountInfo) -> Result<u64> {
    let rent_min = Rent::get()?.minimum_balance(0);
    Ok(vault.lamports().saturating_sub(rent_min))
}

fn needs_queue(s: &Sanctum, cap: &CapState, bal: u64, amount: u64, now: i64) -> Result<bool> {
    require!(amount > 0, SanctumError::ZeroAmount);
    require!(amount <= bal, SanctumError::Balance);
    let over_share = amount as u128 * 10_000 > bal as u128 * s.rules.delay_bps as u128;
    Ok(over_share || amount > cap.room(&s.rules, bal, now))
}

fn check_executable(s: &Sanctum, signer: &Pubkey, q: &Queued, now: i64) -> Result<()> {
    require!(*signer == s.hot || *signer == s.cold, SanctumError::Unauthorized);
    require!(now >= s.frozen_until, SanctumError::Frozen);
    require!(q.panic_epoch == s.panic_epoch, SanctumError::VoidedByPanic);
    // queued while guardian panics were muted: only the cold key can let it through
    require!(q.approved || q.queued_at >= s.guardian_muted_until, SanctumError::NeedsColdApproval);
    require!(q.approved || !s.approval_mode, SanctumError::NeedsColdApproval);
    // strict: the queue opens one second AFTER ready_at, so a cancel/panic landing at ready_at always wins the tie
    require!(now > q.ready_at, SanctumError::NotReady);
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn open_queued<'info>(
    s: &mut Account<'info, Sanctum>,
    sanctum_key: Pubkey,
    queued: &UncheckedAccount<'info>,
    payer: &AccountInfo<'info>,
    system: &AccountInfo<'info>,
    mint: Pubkey,
    to: Pubkey,
    amount: u64,
    now: i64,
) -> Result<()> {
    let seq = s.queue_seq;
    let seq_bytes = seq.to_le_bytes();
    let (expected, bump) =
        Pubkey::find_program_address(&[QUEUE_SEED, sanctum_key.as_ref(), &seq_bytes], &crate::ID);
    require_keys_eq!(queued.key(), expected, SanctumError::BadQueueAccount);
    let space = 8 + Queued::INIT_SPACE;
    let seeds: &[&[u8]] = &[QUEUE_SEED, sanctum_key.as_ref(), &seq_bytes, &[bump]];
    let signer: &[&[&[u8]]] = &[seeds];
    let info = queued.to_account_info();
    let need = Rent::get()?.minimum_balance(space);
    let have = info.lamports();
    // Pre-funding the address (griefing) must not block the queue: top up, allocate, assign.
    if have < need {
        system_program::transfer(
            CpiContext::new(system.key(), system_program::Transfer { from: payer.clone(), to: info.clone() }),
            need - have,
        )?;
    }
    require!(info.data_is_empty() && info.owner == &system_program::ID, SanctumError::BadQueueAccount);
    system_program::allocate(
        CpiContext::new_with_signer(system.key(), system_program::Allocate { account_to_allocate: info.clone() }, signer),
        space as u64,
    )?;
    system_program::assign(
        CpiContext::new_with_signer(system.key(), system_program::Assign { account_to_assign: info.clone() }, signer),
        &crate::ID,
    )?;
    let q = Queued {
        sanctum: sanctum_key,
        seq,
        mint,
        to,
        amount,
        queued_at: now,
        ready_at: now + s.rules.delay_secs,
        panic_epoch: s.panic_epoch,
        approved: false,
        payer: payer.key(),
        bump,
    };
    {
        let mut data = info.try_borrow_mut_data()?;
        let mut w: &mut [u8] = &mut data[..];
        q.try_serialize(&mut w)?;
    }
    s.queue_seq = seq.checked_add(1).ok_or(SanctumError::Math)?;
    emit!(QueuedTransfer { sanctum: sanctum_key, seq, mint, to, amount, ready_at: q.ready_at });
    Ok(())
}

fn send_sol<'info>(
    s: &Account<'info, Sanctum>,
    vault: &SystemAccount<'info>,
    to: &UncheckedAccount<'info>,
    system: &Program<'info, System>,
    amount: u64,
) -> Result<()> {
    let sk = s.key();
    let seeds: &[&[u8]] = &[VAULT_SEED, sk.as_ref(), &[s.vault_bump]];
    system_program::transfer(
        CpiContext::new_with_signer(
            system.key(),
            system_program::Transfer { from: vault.to_account_info(), to: to.to_account_info() },
            &[seeds],
        ),
        amount,
    )
}

fn send_token<'info>(
    s: &Account<'info, Sanctum>,
    vault: &SystemAccount<'info>,
    vault_ata: &InterfaceAccount<'info, TokenAccount>,
    to: &InterfaceAccount<'info, TokenAccount>,
    mint: &InterfaceAccount<'info, Mint>,
    token_program: &Interface<'info, TokenInterface>,
    amount: u64,
) -> Result<()> {
    let sk = s.key();
    let seeds: &[&[u8]] = &[VAULT_SEED, sk.as_ref(), &[s.vault_bump]];
    token_interface::transfer_checked(
        CpiContext::new_with_signer(
            token_program.key(),
            TransferChecked {
                from: vault_ata.to_account_info(),
                mint: mint.to_account_info(),
                to: to.to_account_info(),
                authority: vault.to_account_info(),
            },
            &[seeds],
        ),
        amount,
        mint.decimals,
    )
}

// ---------------------------------------------------------------- accounts

#[derive(Accounts)]
#[instruction(nonce: u64)]
pub struct Create<'info> {
    #[account(mut)]
    pub hot: Signer<'info>,
    #[account(init, payer = hot, space = 8 + Sanctum::INIT_SPACE,
        seeds = [SANCTUM_SEED, hot.key().as_ref(), &nonce.to_le_bytes()], bump)]
    pub sanctum: Account<'info, Sanctum>,
    #[account(mut, seeds = [VAULT_SEED, sanctum.key().as_ref()], bump)]
    pub vault: SystemAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct DepositSol<'info> {
    #[account(mut)]
    pub depositor: Signer<'info>,
    pub sanctum: Account<'info, Sanctum>,
    #[account(mut, seeds = [VAULT_SEED, sanctum.key().as_ref()], bump = sanctum.vault_bump)]
    pub vault: SystemAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct DepositToken<'info> {
    #[account(mut)]
    pub depositor: Signer<'info>,
    pub sanctum: Account<'info, Sanctum>,
    #[account(seeds = [VAULT_SEED, sanctum.key().as_ref()], bump = sanctum.vault_bump)]
    pub vault: SystemAccount<'info>,
    #[account(mint::token_program = token_program)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut, token::mint = mint, token::authority = depositor, token::token_program = token_program)]
    pub from: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(init_if_needed, payer = depositor,
        associated_token::mint = mint, associated_token::authority = vault, associated_token::token_program = token_program)]
    pub vault_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
    pub associated_token_program: Program<'info, AssociatedToken>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct WithdrawSol<'info> {
    #[account(mut)]
    pub hot: Signer<'info>,
    #[account(mut, has_one = hot @ SanctumError::Unauthorized)]
    pub sanctum: Account<'info, Sanctum>,
    #[account(mut, seeds = [VAULT_SEED, sanctum.key().as_ref()], bump = sanctum.vault_bump)]
    pub vault: SystemAccount<'info>,
    #[account(init_if_needed, payer = hot, space = 8 + CapState::INIT_SPACE,
        seeds = [CAP_SEED, sanctum.key().as_ref(), SOL_MINT.as_ref()], bump)]
    pub cap: Box<Account<'info, CapState>>,
    /// CHECK: queue item PDA ["q", sanctum, queue_seq]; created only if the transfer is queued (address checked).
    #[account(mut)]
    pub queued: UncheckedAccount<'info>,
    /// CHECK: any destination of the hot key's choice.
    #[account(mut)]
    pub to: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct WithdrawToken<'info> {
    #[account(mut)]
    pub hot: Signer<'info>,
    #[account(mut, has_one = hot @ SanctumError::Unauthorized)]
    pub sanctum: Account<'info, Sanctum>,
    #[account(seeds = [VAULT_SEED, sanctum.key().as_ref()], bump = sanctum.vault_bump)]
    pub vault: SystemAccount<'info>,
    #[account(mint::token_program = token_program)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut, associated_token::mint = mint, associated_token::authority = vault, associated_token::token_program = token_program)]
    pub vault_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(init_if_needed, payer = hot, space = 8 + CapState::INIT_SPACE,
        seeds = [CAP_SEED, sanctum.key().as_ref(), mint.key().as_ref()], bump)]
    pub cap: Box<Account<'info, CapState>>,
    /// CHECK: queue item PDA ["q", sanctum, queue_seq]; created only if the transfer is queued (address checked).
    #[account(mut)]
    pub queued: UncheckedAccount<'info>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub to: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ExecuteQueuedSol<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,
    pub sanctum: Account<'info, Sanctum>,
    #[account(mut, seeds = [VAULT_SEED, sanctum.key().as_ref()], bump = sanctum.vault_bump)]
    pub vault: SystemAccount<'info>,
    #[account(mut, has_one = sanctum, has_one = payer, close = payer)]
    pub queued: Box<Account<'info, Queued>>,
    /// CHECK: rent refund for the queue item; must equal queued.payer.
    #[account(mut)]
    pub payer: UncheckedAccount<'info>,
    /// CHECK: must equal queued.to (checked in the handler).
    #[account(mut)]
    pub to: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ExecuteQueuedToken<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,
    pub sanctum: Account<'info, Sanctum>,
    #[account(seeds = [VAULT_SEED, sanctum.key().as_ref()], bump = sanctum.vault_bump)]
    pub vault: SystemAccount<'info>,
    #[account(mut, has_one = sanctum, has_one = payer, close = payer)]
    pub queued: Box<Account<'info, Queued>>,
    /// CHECK: rent refund for the queue item; must equal queued.payer.
    #[account(mut)]
    pub payer: UncheckedAccount<'info>,
    #[account(mint::token_program = token_program)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut, associated_token::mint = mint, associated_token::authority = vault, associated_token::token_program = token_program)]
    pub vault_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub to: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
}

#[derive(Accounts)]
pub struct CancelQueued<'info> {
    pub signer: Signer<'info>,
    pub sanctum: Account<'info, Sanctum>,
    #[account(mut, has_one = sanctum, has_one = payer, close = payer)]
    pub queued: Box<Account<'info, Queued>>,
    /// CHECK: rent refund for the queue item; must equal queued.payer.
    #[account(mut)]
    pub payer: UncheckedAccount<'info>,
}

#[derive(Accounts)]
pub struct ApproveQueued<'info> {
    pub cold: Signer<'info>,
    #[account(has_one = cold @ SanctumError::Unauthorized)]
    pub sanctum: Account<'info, Sanctum>,
    #[account(mut, has_one = sanctum)]
    pub queued: Box<Account<'info, Queued>>,
}

#[derive(Accounts)]
pub struct ColdWithdrawSol<'info> {
    #[account(mut)]
    pub cold: Signer<'info>,
    #[account(has_one = cold @ SanctumError::Unauthorized)]
    pub sanctum: Account<'info, Sanctum>,
    #[account(mut, seeds = [VAULT_SEED, sanctum.key().as_ref()], bump = sanctum.vault_bump)]
    pub vault: SystemAccount<'info>,
    #[account(init_if_needed, payer = cold, space = 8 + CapState::INIT_SPACE,
        seeds = [CAP_SEED, sanctum.key().as_ref(), SOL_MINT.as_ref()], bump)]
    pub cap: Box<Account<'info, CapState>>,
    /// CHECK: any destination of the cold key's choice.
    #[account(mut)]
    pub to: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ColdWithdrawToken<'info> {
    #[account(mut)]
    pub cold: Signer<'info>,
    #[account(has_one = cold @ SanctumError::Unauthorized)]
    pub sanctum: Account<'info, Sanctum>,
    #[account(seeds = [VAULT_SEED, sanctum.key().as_ref()], bump = sanctum.vault_bump)]
    pub vault: SystemAccount<'info>,
    #[account(mint::token_program = token_program)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut, associated_token::mint = mint, associated_token::authority = vault, associated_token::token_program = token_program)]
    pub vault_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(init_if_needed, payer = cold, space = 8 + CapState::INIT_SPACE,
        seeds = [CAP_SEED, sanctum.key().as_ref(), mint.key().as_ref()], bump)]
    pub cap: Box<Account<'info, CapState>>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub to: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Panic<'info> {
    pub signer: Signer<'info>,
    #[account(mut)]
    pub sanctum: Account<'info, Sanctum>,
}

#[derive(Accounts)]
pub struct ColdOnly<'info> {
    pub cold: Signer<'info>,
    #[account(mut, has_one = cold @ SanctumError::Unauthorized)]
    pub sanctum: Account<'info, Sanctum>,
}

#[derive(Accounts)]
pub struct HotOnly<'info> {
    pub hot: Signer<'info>,
    #[account(mut, has_one = hot @ SanctumError::Unauthorized)]
    pub sanctum: Account<'info, Sanctum>,
}

#[derive(Accounts)]
pub struct InitStaking<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(init, payer = admin, space = 8 + Config::INIT_SPACE, seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,
    #[account(mint::token_program = token_program)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(init, payer = admin, seeds = [STAKE_VAULT_SEED], bump,
        token::mint = mint, token::authority = config, token::token_program = token_program)]
    pub stake_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    /// Only the program's upgrade authority may initialize (blocks a front-run init with a hostile admin).
    #[account(constraint = program_data.upgrade_authority_address == Some(admin.key()) @ SanctumError::Unauthorized)]
    pub program_data: Account<'info, ProgramData>,
    #[account(constraint = program.programdata_address()? == Some(program_data.key()) @ SanctumError::Unauthorized)]
    pub program: Program<'info, crate::program::Sanctum>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct RegisterNode<'info> {
    #[account(mut)]
    pub operator: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = mint, has_one = stake_vault, has_one = token_program)]
    pub config: Account<'info, Config>,
    #[account(init, payer = operator, space = 8 + Node::INIT_SPACE, seeds = [NODE_SEED, operator.key().as_ref()], bump)]
    pub node: Account<'info, Node>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut, token::mint = mint, token::authority = operator, token::token_program = token_program)]
    pub from: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut)]
    pub stake_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

impl<'info> RegisterNode<'info> {
    fn stake_accounts(&mut self) -> StakeIn<'_, 'info> {
        StakeIn { operator: &self.operator, mint: &self.mint, from: &self.from, vault: &mut self.stake_vault, token_program: &self.token_program }
    }
}

#[derive(Accounts)]
pub struct AddStake<'info> {
    pub operator: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = mint, has_one = stake_vault, has_one = token_program)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [NODE_SEED, operator.key().as_ref()], bump = node.bump, has_one = operator)]
    pub node: Account<'info, Node>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut, token::mint = mint, token::authority = operator, token::token_program = token_program)]
    pub from: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut)]
    pub stake_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
}

impl<'info> AddStake<'info> {
    fn stake_accounts(&mut self) -> StakeIn<'_, 'info> {
        StakeIn { operator: &self.operator, mint: &self.mint, from: &self.from, vault: &mut self.stake_vault, token_program: &self.token_program }
    }
}

#[derive(Accounts)]
pub struct NodeOp<'info> {
    pub operator: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [NODE_SEED, operator.key().as_ref()], bump = node.bump, has_one = operator)]
    pub node: Account<'info, Node>,
}

#[derive(Accounts)]
pub struct WithdrawStake<'info> {
    #[account(mut)]
    pub operator: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = mint, has_one = stake_vault, has_one = token_program)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [NODE_SEED, operator.key().as_ref()], bump = node.bump, has_one = operator, close = operator)]
    pub node: Account<'info, Node>,
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut, token::mint = mint, token::token_program = token_program)]
    pub operator_ata: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut)]
    pub stake_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
}

#[derive(Accounts)]
pub struct Slash<'info> {
    pub admin: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = admin @ SanctumError::Unauthorized,
        has_one = mint, has_one = stake_vault, has_one = token_program)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [NODE_SEED, node.operator.as_ref()], bump = node.bump)]
    pub node: Account<'info, Node>,
    #[account(mut)]
    pub mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut)]
    pub stake_vault: Box<InterfaceAccount<'info, TokenAccount>>,
    pub token_program: Interface<'info, TokenInterface>,
}

#[derive(Accounts)]
pub struct WatcherPanic<'info> {
    pub operator: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [NODE_SEED, operator.key().as_ref()], bump = node.bump, has_one = operator)]
    pub node: Account<'info, Node>,
    #[account(mut)]
    pub sanctum: Account<'info, Sanctum>,
    #[account(has_one = sanctum)]
    pub queued: Box<Account<'info, Queued>>,
}

// ---------------------------------------------------------------- events + errors

#[event]
pub struct Created { pub sanctum: Pubkey, pub hot: Pubkey, pub cold: Pubkey, pub vault: Pubkey }
#[event]
pub struct Deposited { pub sanctum: Pubkey, pub mint: Pubkey, pub amount: u64 }
#[event]
pub struct Sent { pub sanctum: Pubkey, pub mint: Pubkey, pub to: Pubkey, pub amount: u64 }
#[event]
pub struct QueuedTransfer { pub sanctum: Pubkey, pub seq: u64, pub mint: Pubkey, pub to: Pubkey, pub amount: u64, pub ready_at: i64 }
#[event]
pub struct QueueExecuted { pub sanctum: Pubkey, pub seq: u64, pub mint: Pubkey, pub to: Pubkey, pub amount: u64 }
#[event]
pub struct QueueCancelled { pub sanctum: Pubkey, pub seq: u64, pub by: Pubkey }
#[event]
pub struct QueueApproved { pub sanctum: Pubkey, pub seq: u64 }
#[event]
pub struct Panicked { pub sanctum: Pubkey, pub by: Pubkey, pub guardian: bool, pub until: i64 }
#[event]
pub struct Unfrozen { pub sanctum: Pubkey, pub muted_until: i64 }
#[event]
pub struct KeysChanged { pub sanctum: Pubkey, pub hot: Pubkey, pub cold: Pubkey, pub guardian_count: u8 }
#[event]
pub struct RulesProposed { pub sanctum: Pubkey, pub rules: Rules, pub ready_at: i64 }
#[event]
pub struct RulesApplied { pub sanctum: Pubkey, pub rules: Rules }

#[event]
pub struct ModesSet { pub sanctum: Pubkey, pub watchers_on: bool, pub approval_mode: bool }
#[event]
pub struct StakingInitialized { pub admin: Pubkey, pub mint: Pubkey, pub min_stake: u64, pub unstake_cooldown: i64 }
#[event]
pub struct NodeRegistered { pub node: Pubkey, pub operator: Pubkey, pub stake: u64 }
#[event]
pub struct Staked { pub node: Pubkey, pub operator: Pubkey, pub amount: u64, pub stake: u64 }
#[event]
pub struct UnstakeRequested { pub node: Pubkey, pub operator: Pubkey, pub stake: u64, pub ready_at: i64 }
#[event]
pub struct StakeWithdrawn { pub node: Pubkey, pub operator: Pubkey, pub amount: u64 }
#[event]
pub struct Slashed { pub node: Pubkey, pub operator: Pubkey, pub amount: u64, pub reason_code: u16, pub stake_left: u64 }
#[event]
pub struct WatcherPanicked { pub sanctum: Pubkey, pub node: Pubkey, pub operator: Pubkey, pub seq: u64, pub until: i64 }

#[error_code]
pub enum SanctumError {
    #[msg("signer has no standing for this action")]
    Unauthorized,
    #[msg("sanctum is frozen")]
    Frozen,
    #[msg("hourly cap")]
    HourlyCap,
    #[msg("daily cap")]
    DailyCap,
    #[msg("amount exceeds balance")]
    Balance,
    #[msg("amount must be > 0")]
    ZeroAmount,
    #[msg("queued transfer voided by a panic")]
    VoidedByPanic,
    #[msg("queued during guardian mute: needs cold approval")]
    NeedsColdApproval,
    #[msg("not ready yet")]
    NotReady,
    #[msg("guardians are muted after a cold unfreeze")]
    GuardianMuted,
    #[msg("guardians may only re-panic in the last hour of a freeze")]
    FrozenLastHourOnly,
    #[msg("hot key may only tighten rules")]
    TightenOnly,
    #[msg("invalid rules")]
    BadRules,
    #[msg("invalid key")]
    BadKey,
    #[msg("at most 3 guardians")]
    TooManyGuardians,
    #[msg("duplicate guardian")]
    DuplicateGuardian,
    #[msg("wrong queue item account")]
    BadQueueAccount,
    #[msg("destination does not match")]
    BadDestination,
    #[msg("asset does not match the queue item")]
    WrongAsset,
    #[msg("math overflow")]
    Math,
    #[msg("watchers need approval mode")]
    WatchersNeedApproval,
    #[msg("invalid staking config")]
    BadStakeConfig,
    #[msg("stake below the minimum")]
    BelowMinStake,
    #[msg("node is unstaking")]
    Unstaking,
    #[msg("node is not active")]
    NodeNotActive,
    #[msg("sanctum has watchers off")]
    WatchersOff,
    #[msg("queue item is approved by the cold key")]
    QueueApproved,
    #[msg("queue item is not in its final hour")]
    NotFinalHour,
}
