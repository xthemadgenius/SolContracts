use anchor_lang::prelude::*;
use anchor_lang::system_program;
#[allow(unused_imports)]
use pyth_sdk_solana::load_price_feed_from_account_info;
use anchor_spl::token::{self, Token, TokenAccount, Transfer};
use solana_program::{
    account_info::AccountInfo,
    pubkey::Pubkey,
};

declare_id!("Contract Addy");

#[program]
pub mod presale_vesting {
    use super::*;

    pub fn initialize_presale(ctx: Context<InitializePresale>, token_mint: Pubkey, admin: Pubkey, bump: u8) -> Result<()> {
        let presale = &mut ctx.accounts.presale_account;
        presale.token_mint = token_mint;
        presale.admin = admin;
        presale.total_tokens_allocated = 0;
        presale.is_closed = false;
        presale.bump = bump; // Save the bump seed
        Ok(())
    }

    pub fn contribute(ctx: Context<Contribute>, amount: u64) -> Result<()> {
        let presale = &mut ctx.accounts.presale_account;

        // Ensure the presale has not ended
        require!(!presale.is_closed, CustomError::PresaleClosed);

        // Transfer tokens from contributor to admin wallet
        let cpi_accounts = Transfer {
            from: ctx.accounts.allocation_account.to_account_info(), // Token source (contributor wallet)
            to: ctx.accounts.admin_wallet.to_account_info(),         // Token destination (admin wallet)
            authority: ctx.accounts.contributor.to_account_info(),   // Contributor's authority
        };
        let cpi_context = CpiContext::new(ctx.accounts.token_program.to_account_info(), cpi_accounts);
        token::transfer(cpi_context, amount)?;

        // Update allocation account with the contributed amount
        let allocation = &mut ctx.accounts.allocation_account;
        allocation.amount += amount;
        allocation.cliff_timestamp = presale.cliff_timestamp;
        allocation.vesting_end_timestamp = presale.vesting_end_timestamp;

        presale.total_tokens_allocated += amount;

        Ok(())
    }


    pub fn claim_tokens(ctx: Context<ClaimTokens>, claimable_now: u64) -> Result<()> {
        let allocation = &mut ctx.accounts.allocation_account;

        // Create a longer-lived variable for the presale_account key
        let presale_account_key = ctx.accounts.presale_account.key();

        // Prepare seeds for signing
        let seeds = &[
            b"presale",
            presale_account_key.as_ref(),
            &[ctx.accounts.presale_account.bump],
        ];
        let signer = &[&seeds[..]];

        // Transfer tokens to the contributor
        let cpi_accounts = Transfer {
            from: ctx.accounts.presale_wallet.to_account_info(), // Token source
            to: ctx.accounts.contributor_wallet.to_account_info(), // Token destination
            authority: ctx.accounts.presale_account.to_account_info(), // Authority
        };
        let cpi_context = CpiContext::new_with_signer(
            ctx.accounts.token_program.to_account_info(),
            cpi_accounts,
            signer,
        );
        token::transfer(cpi_context, claimable_now)?;

        // Update allocation
        allocation.claimed_amount += claimable_now;

        Ok(())
    }

    pub fn close_presale(ctx: Context<ClosePresale>) -> Result<()> {
        let presale = &mut ctx.accounts.presale_account;

        // Only the admin can close the presale
        require!(ctx.accounts.admin.key() == presale.admin, CustomError::Unauthorized);
        presale.is_closed = true;

        Ok(())
    }
}

#[derive(Accounts)]
pub struct InitializePresale<'info> {
    #[account(init, payer = admin, space = 8 + 32 + 32 + 8 + 8 + 1)]
    pub presale_account: Account<'info, PresaleAccount>,
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(address = system_program::ID)]
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Contribute<'info> {
    #[account(mut)]
    pub presale_account: Account<'info, PresaleAccount>, // Presale state
    #[account(
        init_if_needed,
        payer = contributor,
        space = 8 + 8 + 8 + 8 + 8
    )]
    pub allocation_account: Account<'info, AllocationAccount>, // Allocation state for the contributor
    #[account(mut)]
    pub contributor: Signer<'info>, // Contributor wallet
    /// CHECK: Admin wallet account (could add stricter validation here)
    pub admin_wallet: AccountInfo<'info>, // Admin wallet to receive funds
    #[account(address = token::ID)]
    pub token_program: Program<'info, Token>, // Token program
    pub system_program: Program<'info, System>, // System program
}

#[derive(Accounts)]
pub struct ClaimTokens<'info> {
    #[account(mut)]
    pub presale_account: Account<'info, PresaleAccount>, // Presale state
    #[account(mut)]
    pub allocation_account: Account<'info, AllocationAccount>, // Allocation state for the contributor
    #[account(mut)]
    pub presale_wallet: Account<'info, TokenAccount>, // Presale token wallet
    #[account(mut)]
    pub contributor_wallet: Account<'info, TokenAccount>, // Contributor token wallet
    #[account(address = token::ID)]
    pub token_program: Program<'info, Token>, // Token program
}

#[derive(Accounts)]
pub struct ClosePresale<'info> {
    #[account(mut)]
    pub presale_account: Account<'info, PresaleAccount>,
    #[account(signer)]
    pub admin: AccountInfo<'info>,
}

#[account]
pub struct PresaleAccount {
    pub token_mint: Pubkey,              // Token mint address
    pub admin: Pubkey,                  // Admin address
    pub total_tokens_allocated: u64,    // Total tokens allocated
    pub cliff_timestamp: u64,           // Cliff timestamp for vesting
    pub vesting_end_timestamp: u64,     // Vesting end timestamp
    pub is_closed: bool,                // Whether the presale is closed
    pub bump: u8,                       // PDA bump seed
}

#[account]
pub struct AllocationAccount {
    pub amount: u64,
    pub claimed_amount: u64,
    pub cliff_timestamp: u64,
    pub vesting_end_timestamp: u64,
}

#[error_code]
pub enum CustomError {
    #[msg("The presale has already been closed.")]
    PresaleClosed,
    #[msg("The cliff period has not been reached yet.")]
    CliffNotReached,
    #[msg("You have no tokens to claim at this time.")]
    NothingToClaim,
    #[msg("Unauthorized action.")]
    Unauthorized,
}