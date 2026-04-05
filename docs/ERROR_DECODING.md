# yPot Revert / Error Decoding Guide

The source of truth is the Solidity in `src/`. This document is an integration guide for wallets, UIs, and indexers that want to present clear error messages for calls into:

- `src/yPot.sol` (contract `yPot`)
- (optionally) `src/YearnWrapper.sol` when it is used as the yPot vault

---

## Protocol custom errors (authoritative)

### `yPot` (core)

`yPot` uses short error selectors:

- `E1()` — invalid params (out-of-range outcome, amount outside min/max, invalid timestamps, empty/too-long description, etc.)
- `E2()` — invalid state/time window for the requested action
- `E3()` — unauthorized (e.g., market creator trying to report; non-oracle calling `resolveDispute`)
- `E4()` — expired tx deadline (used by `bet`/`confirmReport`)
- `E6()` — slippage (preview vs execution moved beyond tolerance; or `minShares` / `minOut` too strict)
- `E7()` — market duration too short (`create()` requires `deadline-now >= 14 days`)
- `E8()` — challenger already exists (only one challenger is supported)
- `E9()` — report already exists (only one active report is supported)

### `yPotGov` (timelock wrapper)

`yPotGov` defines:

- `E1()` — invalid params (proposal already pending, zero address, etc.)
- `E5()` — timelock not ready (attempted `exec*` before the timelock elapsed)

### `yPotUma` (UMA module)

`yPotUma` uses:

- `E2()` — invalid state for UMA appeal actions

### Suggested user-facing mapping

| Error | Suggested title | Typical user action |
|------|------------------|---------------------|
| `E1()` | Invalid input | Fix amount/outcome/deadlines; refresh market data |
| `E2()` | Not available | Wait for the relevant time window / market status |
| `E3()` | Not permitted | Switch account; explain role requirement (owner/oracle/not-creator) |
| `E4()` | Transaction expired | Retry with a fresh tx deadline |
| `E5()` | Timelock pending | Show ETA for when execution becomes valid |
| `E6()` | Slippage exceeded | Refresh quote; retry with updated mins |
| `E7()` | Market too short | Increase `deadline` (markets must be at least 14 days long) |
| `E8()` | Already challenged | Refresh; dispute is already in progress |
| `E9()` | Already reported | Refresh; there is already an active report |

---

## Common “bubbled up” errors (not defined by `yPot`)

Calls into yPot can revert with errors coming from dependencies (the asset token or the configured ERC-4626 vault). Your UI should treat these as expected integration errors, not “unknown failures”.

### ERC-20 transfer/allowance failures (asset token)

Typical user-facing causes:
- insufficient balance
- insufficient allowance / missing approval

### ERC-4626 / OpenZeppelin errors (vault or wrapper)

Depending on the configured vault, you may see:
- `ERC4626ExceededMaxDeposit`
- `ERC4626ExceededMaxMint`
- `ERC4626ExceededMaxWithdraw`
- `ERC4626ExceededMaxRedeem`

### YearnWrapper errors (if the yPot vault is `YearnWrapper.sol`)

Potential bubbled errors include:
- `Unauthorized()` — wrapper depositor gating (caller not in depositors allowlist)
- `ZeroAddress()` — zero address passed to `setDepositor` or constructor
- `ZeroAmount()` — zero amount deposit/mint or zero shares from vault
- `SlippageExceeded()` — Yearn deposit returned fewer shares than slippage tolerance
- `InsufficientLiquidity()` — wrapper cannot fulfill withdrawal from local + Yearn balance
- `InvalidSlippage()` — `setSlippage` called with out-of-bounds value
- `RenounceDisabled()` — `renounceOwnership` is permanently disabled
- `EnforcedPause()` — OpenZeppelin Pausable error (if the wrapper is paused)

### UmaOptimisticOracleAdapter errors (if UMA is enabled)

- `Unauthorized()` — caller is not the request owner or adapter owner
- `ZeroAddress()` — zero address in constructor or withdrawal target
- `OracleCallFailed(bytes)` — underlying UMA oracle call reverted
- `InvalidOracleResponse()` — settle returned less than 32 bytes
- `RequestAlreadyExists()` — duplicate request for the same timestamp/ancillary
- `RequestSlotUsed()` — request ID was previously initialized (prevents reuse)
- `RequestNotActive()` — attempted to settle/dispute a non-active request
- `RequestStillActive()` — attempted to withdraw from an unsettled request
- `RequestUnknown()` — request ID was never initialized
- `InsufficientBalance()` — adapter does not hold enough currency for the operation
- `InsufficientClaimable()` — withdrawal amount exceeds claimable for this request
- `InsufficientExcess()` — owner withdrawal exceeds excess (unreserved) balance

---

## Context hints (recovery messaging)

These aren’t separate error types, but they matter for actionable UX:

- `bet(...)` failures:
  - `E2()` often means market is closed (past deadline) or doesn’t exist.
  - `E4()` means the UI’s `txDeadline` is stale.
  - `E6()` means the vault preview/execution moved beyond tolerance or `minShares` was set too high.
- `report(...)` failures:
  - `E3()` means the caller is the market creator.
  - `E2()` often means not yet closed, before `resTime`, or already reported.
- `challenge(...)` failures:
  - `E2()` can mean challenge window ended.
  - `E8()` means already challenged.
  - `E1()` can mean invalid outcome index or “same outcome as report”.
- `claim(...)` failures:
  - `E2()` can mean not finalized / not claimable.
  - `E6()` means `minOut` too strict.
  - Claims can permanently stop after `sweepDust()` is called for that market.

---

## Notes

- UIs should map these `E*()` errors to human-friendly labels (e.g., “Invalid params” / “Invalid state”) and offer the “Context hints” actions above.
