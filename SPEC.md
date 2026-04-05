# Specification (Informal)

This document is an *informal* specification of the on-chain behavior of the main contracts in this repository.

- **Source of truth**: the Solidity in `src/` is authoritative.
- **Version**: written against `yPot` as shipped in `src/yPot.sol`.
- **Scope**: describes externally observable behavior and key invariants; it is not a full formal proof.

## Terminology

- **Asset**: the ERC-20 token used for deposits and payouts (6 decimals enforced in `yPot`).
- **Vault**: the ERC-4626 contract `yPot` deposits into (may be `YearnWrapper`).
- **Shares**: ERC-4626 shares minted by the vault.
- **Principal**: the sum of bet deposits into a market (in asset units).
- **Yield**: (assets redeemed) minus (cost basis principal) on a claim.
- **Weighted shares**: shares multiplied by a time-weight factor; used only to compute payout entitlement.
- **Truth-teller**: reporter or challenger whose proposed outcome matches the final winner (if any).

## Contracts and Roles

### `yPot` (`src/yPot.sol`)

Roles:
- **Anyone**: can create markets, bet, close, report, challenge, accept (if eligible), finalize, claim, sweep dust, etc.
- **Owner**: can pause/unpause; set parameters; set oracles/quorum; cancel markets pre-resolution; withdraw reserve; rescue ETH.
- **Oracle**: permissioned address that can vote in disputes via `resolveDispute`.
- **UMA module** (optional): a single configured contract address that can call UMA hook functions (`uma*`).

### `YearnWrapper` (`src/YearnWrapper.sol`) (optional vault)

- Deposit/mint is restricted to an allowlist of `depositors`.
- Withdraw/redeem is standard ERC-4626 behavior (not depositor-gated).
- Owner can manage depositors, pause deposits, adjust slippage bounds, and perform an emergency exit from the underlying Yearn vault.

### `yPotGov` (`src/yPotGov.sol`) (optional governance wrapper)

- Provides `prop*/exec*` functions with a 2-day timelock for parameter changes by calling into `yPot`.
- Also forwards a small set of immediate emergency actions (`pausePot`, `unpausePot`, `cancelMarket`, `rescuePotEth`).

### `yPotUma` + `UmaOptimisticOracleAdapter` (optional UMA backstop)

- `yPot` has a one-shot `setUmaModule` to enable an external UMA module.
- `yPotUma` implements UMA appeal lifecycle and interacts with `yPot` via UMA hook methods and views.
- The adapter provides a thin compatibility layer for different UMA OO deployments.

## Constants (Key)

From `src/yPot.sol`:
- `BPS = 10_000`
- `minReportBond = 100e6` (immutable)
- `CHALLENGE_WINDOW = 48 hours`
- `CONFIRM_TIMEOUT = 48 hours` (extra time after challenge window for confirmations)
- `DISPUTE_PERIOD = 24 hours` (delay before finality/claims)
- `UMA_APPEAL_WINDOW = 48 hours` (after committee quorum; if UMA is enabled)
- `SWEEP_DELAY = 30 days` (delay before sweeping unclaimed winnings)
- `YIELD_FEE_BPS = 500` (5% of yield only, applied at claim time)
- `DISPUTE_RAKE_BPS = 500` (5% rake on the losing bond, challenged settlement)
- `CONFIRM_MAX_MULTIPLIER_BPS = 50_000` (per-address confirmation bond cap = 5x their bet shares on reported outcome)

See `docs/PARAMETERS.md` for a broader parameter list and operational guidance.

## Market Lifecycle

Each market has a status (`uint8`) stored in `yPot`:

- `ST_OPEN (0)`: betting allowed
- `ST_CLOSED (1)`: betting closed; waiting for report
- `ST_REPORTED (5)`: report exists (may be challenged or unchallenged)
- `ST_APPEALABLE (7)`: committee reached quorum; UMA appeal window open
- `ST_UMA_PENDING (8)`: UMA escalation started (if UMA enabled)
- `ST_RESOLVED (2)`: winner set; dispute delay running
- `ST_CLAIMABLE (3)`: claims enabled
- `ST_CANCELLED (4)`: market cancelled; users can emergency withdraw
- `ST_SWEPT (6)`: unclaimed winnings swept to treasury; claims no longer possible

High-level transitions:

1. `create()` -> `ST_OPEN`
2. `bet()` while open
3. `close()` after deadline -> `ST_CLOSED`
4. `report()` after `resTime` -> `ST_REPORTED`
5. Optional branch:
   - Unchallenged path:
     - `confirmReport()` deposits confirmation bonds (only bettors on the reported outcome)
     - `acceptReport()` after `CHALLENGE_WINDOW` and when confirmation threshold met -> `ST_RESOLVED`
     - or `expireUnconfirmedReport()` after `CHALLENGE_WINDOW + CONFIRM_TIMEOUT` -> `ST_CANCELLED`
   - Challenged path:
     - `challenge()` during `CHALLENGE_WINDOW` -> `ST_REPORTED` (challenger set)
     - `resolveDispute()` votes by oracles; once quorum reached -> `ST_APPEALABLE`
     - If UMA is not used: after `UMA_APPEAL_WINDOW`, `finalize()` resolves -> `ST_RESOLVED`
      - If UMA is used: UMA module calls `umaBeginAppeal()` -> `ST_UMA_PENDING`, then `umaResolve()` -> `ST_RESOLVED`, or `umaCancel()` -> `ST_CANCELLED`
      - If committee never resolves: `expireChallenge()` after `CHALLENGE_WINDOW + 7 days` -> `ST_CANCELLED` (both bonds refunded)
      - If UMA stalls past its stale timeout: `expireUmaAppeal()` falls back to the committee winner -> `ST_RESOLVED`
6. `finalize()` after `DISPUTE_PERIOD` from resolution -> `ST_CLAIMABLE` (or `ST_CANCELLED` if nobody bet on the winning outcome)
7. `claim()` / `batchClaim()` while claimable
8. `sweepDust()` after `DISPUTE_PERIOD + SWEEP_DELAY` from resolution -> `ST_SWEPT`

## Market Creation (`create`)

Preconditions (reverts otherwise):
- protocol not paused
- `2 <= outcomes <= 5`
- `desc` length in bytes is `1..1024` and contains no `|` byte
- `cid` length in bytes is `<= 128`
- `deadline > now` and `resTime > deadline`
- `deadline - now >= 14 days`

Effects:
- creates new market id (monotonic counter; starts at 1)
- initializes share arrays of length `outcomes + 1` with index 0 unused
- charges `fee` (if nonzero) and allocates:
  - 20% -> per-market `reporterBountyEscrow`
  - 10% -> reserve (capped by reserve target; overflow -> treasury)
  - remainder -> treasury

## Betting (`bet`)

Preconditions:
- protocol not paused
- market exists and `status == ST_OPEN`
- `now <= deadline`
- outcome in `[1..outcomes]`
- amount in `[minBet..maxBet]`
- `txDeadline >= now`

Effects:
- transfers `amount` from bettor into `yPot`
- deposits into vault, minting `shares`
- enforces slippage: `shares >= previewDeposit(amount) * slippageBps / BPS` and `shares >= minShares`
- records:
  - unweighted shares `sh[outcome] += shares`
  - weighted shares `wsh[outcome] += shares * wt(created, deadline, now) / BPS`
  - principal `prin[outcome] += amount`
  - per-market `tot += shares` and `prin += amount`

## Reporting (`report`) and Bonds

Report preconditions:
- `status == ST_CLOSED` and `now >= resTime`
- outcome in `[1..outcomes]`
- no existing report
- reporter is not the market creator

Report bond:
```
reportBond = max(minReportBond, principal * 10%)
```
(`principal` is current market principal at report time.)

Effects:
- transfers `reportBond` from reporter into `yPot`
- snapshots `confirmBps` into the report
- sets `status = ST_REPORTED`

## Challenge (`challenge`)

Preconditions:
- `status == ST_REPORTED`
- challenger is not the reporter
- no existing challenger (only one is supported)
- `now <= reportedAt + CHALLENGE_WINDOW`
- challenged outcome in `[1..outcomes]` and must differ from reported outcome
- challenger is not required to hold a betting position in the market

Effects:
- transfers `reportBond` from challenger into `yPot`
- records challenger + `challengeOutcome` + `challengeBond`

## Confirmation Bonds (`confirmReport`, `withdrawConfirmBond`, `acceptReport`)

Confirmation bonding (unchallenged reports) is designed to make “nobody challenged” insufficient for finality.

`confirmReport` preconditions:
- protocol not paused
- `status == ST_REPORTED` and market is unchallenged
- caller has a nonzero bet share position on the reported outcome
- `assetsIn > 0`
- per-address cap: total confirmation shares for the caller cannot exceed `5x` their bet shares on the reported outcome
- `txDeadline >= now`

Effects:
- transfers `assetsIn` into `yPot` and deposits into vault, minting `confirmShares`
- enforces slippage: `confirmShares >= previewDeposit(assetsIn) * slippageBps / BPS` and `confirmShares >= minShares`
- increases per-market `confirmTot` and per-user `confirmSh[user]`

`acceptReport` preconditions:
- `status == ST_REPORTED` and unchallenged
- `now > reportedAt + CHALLENGE_WINDOW`
- `confirmTot >= required`, where:
```
required = totalPoolShares * confirmBpsSnapshot / BPS
```

Effects:
- sets `winner = reportedOutcome`, `resolved = now`, `status = ST_RESOLVED`
- refunds the reporter bond to the reporter

Important liveness nuance:
- `confirmReport()` has no cutoff tied to the challenge window. Confirmations may still be added after `CHALLENGE_WINDOW` so long as the market remains unchallenged in `ST_REPORTED`.
- `expireUnconfirmedReport()` is permissionless after `reportedAt + CHALLENGE_WINDOW + CONFIRM_TIMEOUT` if the market is still below the threshold. This makes under-confirmed reports cancellable, but not automatically cancelled.

`withdrawConfirmBond`:
- redeems the caller’s confirmation shares back to assets, subject to `minOut`
- not allowed while the market is in unchallenged `ST_REPORTED` (to prevent breaking acceptance); otherwise allowed in most later states

## Committee Resolution (`resolveDispute`) and Appeals

`resolveDispute` preconditions:
- caller is a whitelisted oracle
- `status == ST_REPORTED` and challenged
- not already in UMA dispute mode
- oracle has not voted before for this market
- outcome in `[1..outcomes]`

Effects:
- records oracle vote; once `votes[outcome] >= confirms`:
  - sets `winner = outcome`
  - sets `appealDeadline = now + UMA_APPEAL_WINDOW`
  - sets `status = ST_APPEALABLE`

UMA escalation:
- if UMA is enabled and within `appealDeadline`, the UMA module can call `umaBeginAppeal` which:
  - moves the market to `ST_UMA_PENDING`
  - snapshots the existing reporter/challenger bonds for UMA use (bonds are removed from the core report struct)
- if UMA later stalls past its stale timeout, `expireUmaAppeal()` resolves back to the committee winner rather than cancelling the market

## Finalization and Expiry

`finalize`:
- If `status == ST_APPEALABLE` and the UMA appeal window has ended (and UMA mode is not active), `finalize` transitions the market to `ST_RESOLVED` and distributes the reporter/challenger bonds.
- Then, for any `ST_RESOLVED`, once `now >= resolved + DISPUTE_PERIOD`:
  - If the winning outcome has zero weighted shares (no winning bettors), market is cancelled.
  - Else `status = ST_CLAIMABLE` and the truth-teller bounty is paid (if any).

`expireMarket`:
- if `status == ST_CLOSED` and `now > resTime + 7 days`, cancels the market.

`expireChallenge`:
- if challenged and committee never reaches quorum within `CHALLENGE_WINDOW + 7 days`, cancels the market and refunds both bonds.
- because `challenge()` does not require market stake, this is a meaningful liveness/griefing surface if oracle resolution is absent.

## Bond Settlement and Dispute Rake

Unchallenged:
- reporter bond is refunded on `acceptReport` (unchallenged) or `expireUnconfirmedReport` (unconfirmed) as applicable.

Challenged (committee path):
- after the appeal window, `finalize` distributes bonds based on the winner:
  - if winner matches reporter’s proposed outcome: reporter wins
  - if winner matches challenger’s proposed outcome: challenger wins
  - otherwise: both lose (bonds go to treasury)

When there is a winner (reporter or challenger):
- a rake is charged against the losing bond:
```
rake = loserBond * DISPUTE_RAKE_BPS / BPS
```
- `rake` is sent to treasury, remainder of both bonds to the winner.

UMA paths use analogous rules via `yPotUma` when distributing recovered bonds.

## Claims (`claim`, `batchClaim`)

Preconditions:
- market `status == ST_CLAIMABLE`
- caller has nonzero weighted shares on the winning outcome
- caller has remaining unclaimed entitlement

Entitlement in vault shares:
```
entitledShares = userWeighted / totalWinningWeighted * totalPoolShares
```

On a claim:
- redeem `sharesToRedeem` from the vault for assets
- compute cost basis principal `cp`:
```
cp = marketPrincipal * sharesToRedeem / totalPoolShares
```
- apply yield-only fee:
```
yield = max(0, assetsOut - cp)
tf    = yield * YIELD_FEE_BPS / BPS
payout = assetsOut - tf
```
- pay `payout` to claimant
- split `tf` between truth-teller (if present), reserve (capped), and treasury

Rounding reserve top-up:
- on full claims only, if vault redemption rounds down slightly below `cp`, the contract may top up a tiny shortfall from the reserve (bounded by `MAX_ROUNDING_TOPUP_ASSETS`).

`batchClaim`:
- accepts up to 64 ids and calls internal claim logic for each (claims “all available” for each id).

## Cancellation and Emergency Withdraw (`emergencyWithdraw`)

If a market is cancelled (`ST_CANCELLED`):
- users can redeem their original unweighted bet shares across all outcomes back to assets via `emergencyWithdraw`.
- the yield fee is not applied on emergency withdraws.

## Sweeping

`sweepDust`:
- after `resolved + DISPUTE_PERIOD + SWEEP_DELAY`, anyone can:
  - mark the market as swept (`ST_SWEPT`)
  - redeem remaining unclaimed vault shares and send assets to treasury

`sweepExcessVaultShares`:
- permissionless cleanup that redeems any vault shares held by the protocol in excess of internal `accountedShares` and routes assets to treasury.

## Pausing

In `yPot`, `pause` prevents:
- `create`
- `bet`
- `confirmReport`
- `fundReserve`

Resolution, finalization, withdrawals, and claims remain available while paused.
