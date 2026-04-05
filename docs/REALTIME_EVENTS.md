# yPot Event Integration Guide

This document lists the events emitted by:

- Core protocol: `src/yPot.sol` (contract `yPot`)
- UMA module (optional): `src/yPotUma.sol` (contract `yPotUma`)

Events are signals, not complete state. For authoritative values, hydrate from view calls (for example: `getMkt`, `getReport`, `getUsr`, `getPoolHealth`).

---

## Market Lifecycle

- `MarketCreated(uint256 indexed id, address indexed creator, uint64 deadline, uint8 outcomes)`
- `MarketMetadata(uint256 indexed id, string cid)`
- `BetPlaced(uint256 indexed id, address indexed user, uint8 outcome, uint256 amount, uint256 shares)`
- `Cancelled(uint256 indexed id)`

## Reporting, Challenges, and Resolution

- `Reported(uint256 indexed id, address indexed reporter, uint8 outcome, uint256 bond)`
- `Challenged(uint256 indexed id, address indexed challenger, uint8 outcome, uint256 bond)`
- `InternalResolved(uint256 indexed id, uint8 outcome, uint64 appealDeadline)`
- `Resolved(uint256 indexed id, uint8 outcome)`
- `ReportConfirmed(uint256 indexed id, address indexed confirmer, uint256 assets, uint256 shares)`
- `ConfirmBondWithdrawn(uint256 indexed id, address indexed confirmer, uint256 assets, uint256 shares)`

## Claims and Exits

- `Claimed(uint256 indexed id, address indexed user, uint256 amount)`
- `EmergencyWithdraw(uint256 indexed id, address indexed user, uint256 amount)`
- `Swept(uint256 indexed id, uint256 shares, uint256 assets)`
- `ExcessSharesSwept(uint256 shares, uint256 assets)`
- `ClaimToppedUp(uint256 indexed id, address indexed user, uint256 shortfall)`

## Admin / Configuration

- `OracleSet(address indexed oracle, bool active)`
- `ConfirmBpsSet(uint256 confirmBps)`
- `SlippageBpsSet(uint256 slippageBps)`
- `UmaModuleSet(address indexed module)`

## Fees / Reserve / Treasury

- `CreateFeeProcessed(uint256 indexed id, uint256 truthBounty, uint256 reserveFunding, uint256 treasuryFunding)`
- `TruthBountyPaid(uint256 indexed id, address indexed recipient, uint256 assets)`
- `TruthBountyRoutedToTreasury(uint256 indexed id, uint256 assets)`
- `DisputeRaked(uint256 indexed id, address indexed loser, uint256 rake)`
- `ReserveFunded(address indexed sender, uint256 reserveAdded, uint256 treasuryRouted)`
- `ReserveAutoFunded(uint256 assets)`
- `ReserveWithdrawn(address indexed to, uint256 assets)`

## UMA Module (Optional)

Emitted by `yPotUma`:

- `UmaAppealStarted(uint256 indexed id, address indexed appellant)`
- `UmaDisputeSettled(uint256 indexed id, int256 resolvedPrice)`
- `UmaDisputeExpired(uint256 indexed id)`
- `DisputeRaked(uint256 indexed id, address indexed loser, uint256 rake)`

## Indexing Notes

- Market identity key: `id` (from `MarketCreated`).
- User identity key: `address` (from `BetPlaced`, `Claimed`, `EmergencyWithdraw`, confirmations).
- Some transitions are time-gated; UIs/indexers may need to compute eligibility from timestamps and `getMkt(id)` rather than waiting for an event.

