# PARAMETERS.md

This document extracts protocol tunables from the contracts and gives explicit guidance: default values, how to change them, safe ranges, and the security/operational impact of changes. The Solidity in `src/` is authoritative; this file is a human-readable guide for parameter decisions and governance proposals.

Important: the core contract (`yPot`, `src/yPot.sol`) exposes immediate owner-only setters (`setTreasury`, `setLimits`, `setFee`, `setConfirms`, `setOracle`, `setConfirmBps`, `setSlippage`). If you want parameter changes to be timelocked, transfer ownership of `yPot` to the governance wrapper `yPotGov` (`src/yPotGov.sol`), which provides `prop*/exec*` flows with a 2-day delay.

---

## Quick summary (recommended defaults)

* `minBet` — **1 USDC** (1e6) — owner-settable via `setLimits` (immediate; timelocked if using `yPotGov`) — keeps dust markets out.
* `maxBet` — **1,000,000 USDC** (1_000_000e6) — owner-settable via `setLimits` (immediate; timelocked if using `yPotGov`) — caps exposure per bet.
* `fee` — **10 USDC** (10e6) — owner-settable via `setFee` (immediate; timelocked if using `yPotGov`) — paid by market creator on `create()`; allocated between truth-teller bounty escrow, reserve funding, and `treasury`.
* `minReportBond` — **100 USDC** (100e6) — immutable (hardcoded in this implementation) — floor for reporter bonds.
* `BOND_BPS` — **1000 (10%)** — constant in contract (non-changeable without redeploy)
* `CHALLENGE_WINDOW` — **48 hours** — challenge window (constant in `yPot`)
* `DISPUTE_PERIOD` — **24 hours** — post-resolution dispute period (constant in `yPot`)
* `UMA_APPEAL_WINDOW` — **48 hours** — window to start UMA appeal after committee quorum (constant in `yPot`; if UMA is enabled)
* `UMA_STALE_TIMEOUT` — **30 days** — UMA liveness timeout before `expireUmaAppeal` fallback (constant in `yPotUma`)
* `calcUmaAppealBond(id)` — **max(50 USDC, 5% of principal)** — appeal bond posted by appellant when starting UMA appeal (constant formula)
* `confirms` — **2** — owner-settable via `setConfirms` (immediate; timelocked if using `yPotGov`) — oracle quorum on disputes (must be `>= 2`)
* `confirmBps` — **2000 (20%)** — owner-settable via `setConfirmBps` (immediate; timelocked if using `yPotGov`) — confirmation threshold for accepting unchallenged reports (snapshotted at report time)
* `slippageBps` — **9900 (1% max slippage)** — owner-settable via `setSlippage` (immediate; timelocked if using `yPotGov`) — vault deposit slippage tolerance
* `umaModule` — **optional** — one-shot owner action (`setUmaModule`) — enables UMA appeal via an external module (e.g. `yPotUma`)
* `YIELD_FEE_BPS` — **500 (5%)** — constant — claim-time fee on yield-only, split between truth-teller, reserve, and `treasury`

---

## On-chain variables (what you can change and how)

| Human name            |        Variable |        Default | Change method | Recommended safe range | Impact of change |
| --------------------- | --------------: | -------------: | :-----------: | ---------------------- | ---------------- |
| Minimum bet           |        `minBet` | `1e6` (1 USDC) | Core: `setLimits` (immediate); `yPotGov`: `propLim/execLim` (2 days) | `1e6` — `1000e6` | Too low → spam / low-value attacks. Too high → excludes micro users. |
| Maximum bet           |        `maxBet` |  `1_000_000e6` | Core: `setLimits` (immediate); `yPotGov`: `propLim/execLim` (2 days) | `1_000_000e6` — `100_000_000e6` | Caps per-bet risk. Increasing increases single-user exposure. |
| Market creation fee   |           `fee` |         `10e6` | Core: `setFee` (immediate); `yPotGov`: `propFee/execFee` (2 days) | `0` — `1000e6` | Protects against spam markets and funds truth-teller bounty + reserve + treasury. Large fees hurt liquidity. |
| Minimum reporter bond | `minReportBond` |        `100e6` | Immutable in this implementation (`yPot` constructor) | `10e6` — `1000e6` | Prevents trivial grief reports. Set relative to expected smallest useful market. |
| Oracle set (add/remove) | `oracles` / `oracleN` | deploy-time | Core: `setOracle` (immediate); `yPotGov`: `propOracle/execOracle` (2 days) | `2` — `MAX_ORACLES` | Changes who can resolve disputes; misconfiguration can break liveness or safety. |
| Oracle quorum         |      `confirms` |            `2` | Core: `setConfirms` (immediate); `yPotGov`: `propConf/execConf` (2 days) | `2` — `oracleN` (recommend `> oracleN / 2`) | Higher increases safety but increases liveness risk. |
| Unchallenged confirm threshold | `confirmBps` | `2000` (20%) | Core: `setConfirmBps` (immediate); `yPotGov`: `propConfirmBps/execConfirmBps` (2 days) | `0` — `5000` (0–50%) | Higher makes thin-outcome capture harder but can slow unchallenged resolution. Applies to new reports only (snapshotted at report time). If an unchallenged report is still under threshold after `CHALLENGE_WINDOW + CONFIRM_TIMEOUT`, anyone can cancel it via `expireUnconfirmedReport()`. Once a challenge exists, confirmation bonds can be withdrawn and no longer gate resolution. |
| Treasury address      |      `treasury` |    deploy-time | Core: `setTreasury` (immediate); `yPotGov`: `propT/execT` (2 days) | — | Controls fee recipient. Timelock protects sudden theft; owner still has immediate pause/cancel powers via `yPotGov` forwarding. |
| Vault slippage tolerance | `slippageBps` | `9900` (1% max slippage) | Core: `setSlippage` (immediate); `yPotGov`: `propSlip/execSlip` (2 days) | `9500` — `9990` | Lower increases liveness risk (more `Slippage` reverts); higher increases integration risk with fast-moving vault rates. |
| UMA module address | `umaModule` | unset (`0x0`) | Core: `setUmaModule` (one-shot, immediate) | — | If set, UMA appeals are enabled via the configured module contract (e.g. `yPotUma`). |

**Constants (require redeploy to change)**

* `BPS = 10_000` → Basis points denominator (100%)
* `ONE_USDC = 1e6` → 1 USDC (6 decimals)
* `DISPUTE_PERIOD = 24 hours` → Post-resolution dispute period
* `CHALLENGE_WINDOW = 48 hours` → Window to challenge reports
* `UMA_APPEAL_WINDOW = 48 hours` → Window to start UMA appeal after committee quorum
* `UMA_STALE_TIMEOUT = 30 days` → UMA liveness timeout before `expireUmaAppeal` fallback (in `yPotUma`)
* `MAX_CREATE_FEE = 1000e6` → Maximum market creation fee (1000 USDC)
* `BOND_BPS = 1000` → Reporter bond = 10% of principal (bounded below by `minReportBond`)
* `DISPUTE_RAKE_BPS = 500` → Rake (to `treasury`) applied on challenged settlements, charged against the losing bond
* `YIELD_FEE_BPS = 500` → Yield fee = 5% of generated yield (charged at claim time)
* `YIELD_REPORTER_REWARD_BPS = 2000` → Truth-teller share of yield fee (20% of `tf`, if a truth-teller exists)
* `YIELD_RESERVE_BPS = 2000` → Reserve share of yield fee (20% of `tf`, capped by reserve target; overflow routes to `treasury`)
* `CREATE_REPORTER_BOUNTY_BPS = 2000` → Truth-teller bounty escrowed from create fee (20% of `fee`)
* `CREATE_RESERVE_BPS = 1000` → Reserve share of create fee (10% of `fee`, capped by reserve target; overflow routes to `treasury`)
* `RESERVE_TARGET_ASSETS = 25e6` → Target cap for the protocol reserve (25 USDC)
* `MAX_ROUNDING_TOPUP_ASSETS = 5` → Maximum principal shortfall topped up from reserve on full claims (tiny ERC4626 rounding dust)
* `MAX_DESC_BYTES = 1024` → Maximum market description length
* `SWEEP_DELAY = 30 days` → Delay before sweeping unclaimed funds
* `UMA_APPEAL_BOND_BPS = 500` → UMA appeal bond = 5% of principal, bounded below (in `yPotUma` / `yPotViews`)
* `MIN_UMA_APPEAL_BOND = 50e6` → UMA appeal bond floor, 50 USDC (in `yPotUma` / `yPotViews`)
* `MIN_SLIPPAGE_BPS = 9500` / `MAX_SLIPPAGE_BPS = 9990` → bounds for configurable slippage tolerances
* `CONFIRM_TIMEOUT = 48 hours` → additional time (after the 48h challenge window) before an under-confirmed unchallenged report becomes cancellable via `expireUnconfirmedReport`
* `CONFIRM_MAX_MULTIPLIER_BPS = 50_000` → per-address cap for `confirmReport` relative to their bet shares on the reported outcome (5x)
* `MAX_ORACLES = 9` → maximum oracle committee size
* `MAX_BATCH_CLAIMS = 64` → maximum markets per `batchClaim` call
* `MIN_MARKET_DURATION = 14 days` → minimum time between `create` and `deadline`
* `MAX_MARKET_DURATION = 730 days` → maximum betting window (2 years absolute cap)
* `MAX_RESOLUTION_DELAY = 180 days` → maximum allowed gap between `deadline` and `resTime`; prevents indefinite capital lock after market close

Note: constants are compiled in — to change them you must redeploy.

---

## YearnWrapper (vault) parameters and behaviors

The wrapper contract exposes runtime behavior and implicit parameters:

* `_decimalsOffset() = 3` (virtual shares) — defends against share inflation. This is compiled in.
* Slippage tolerance (`slippageBps`, default `9900`) — deposit/mint calls enforce a minimum preview-vs-execution ratio.
* `depositors` mapping — only authorized depositors (yPot contract) may call `deposit` and `mint`; `setDepositor` is owner-controlled.
* Emergency exit — owner can withdraw all Yearn shares into local assets (owner action).

**Operational notes**

* Verify `yearnVault.asset()` before deploying wrapper and yPot.
* Wrapper approves Yearn with `type(uint256).max` by default; ensure multisig treats this as expected risk.

---

## Parameter change governance & safety

### Timelocked changes

This section describes `yPotGov`’s 2-day timelock. If `yPot` is owned directly (not by `yPotGov`), an owner can call the core setters (`set*`) immediately.

The following changes must be proposed and then executed after a timelock (2 days) when using `yPotGov`:

* `propLim/execLim` — changes `minBet`/`maxBet`
* `propFee/execFee` — changes `fee`
* `propConf/execConf` — changes `confirms`
* `propT/execT` — changes treasury
* `propOracle/execOracle` — add/remove oracles (note: altering oracleN affects `confirms` validity)
* `propConfirmBps/execConfirmBps` — changes `confirmBps` (unchallenged confirmation threshold)
* `propSlip/execSlip` — changes `slippageBps`

### Transferring yPot ownership (timelocked via yPotGov)

Transferring yPot ownership to a new address is timelocked via `propPotOwner/execPotOwner/cancelPotOwner`:

* `propPotOwner(newOwner)` — proposes transferring yPot ownership; starts 2-day timelock. Reverts if `newOwner == address(0)` or a proposal is already pending.
* `execPotOwner()` — executes after timelock expires; calls `pot.transferOwnership(newOwner)` (Ownable2Step: initiates pending transfer only).
* `cancelPotOwner()` — cancels the pending proposal.

After `execPotOwner()`, the nominated owner must call `yPot.acceptOwnership()` directly (not via `yPotGov.acceptPotOwnership()`). This completes the Ownable2Step transfer.

Note: `yPotGov.acceptPotOwnership()` is for accepting ownership *of yPot by yPotGov itself* during initial governance setup, not for third-party owner acceptance.

**Governance checklist for timelocked proposals**

1. Publish governance proposal describing rationale and potential user impact.
2. Announce to operators and UI maintainers (min 48h before exec recommended).
3. After timelock passes, call `exec*` and verify resulting state changes on-chain.
4. For `propOracle/execOracle`, ensure new oracle endpoints/contacts are reachable.

### Immutable parameters (cannot be changed post-deployment)

* `minReportBond` is set at contract deployment and **cannot be changed** without redeploying the contract. In this repository’s `yPot` (`src/yPot.sol`), it is set to `100e6` in the constructor body (not passed as a constructor argument).

---

## Safe ranges & example decisions

### Small markets (community / testing)

* `minBet`: 1 USDC
* `minReportBond`: 100 USDC
* Rationale: keep cost of reporting higher than gain from trivial markets.

### Mid-sized markets (active trading)

* `minBet`: 10—100 USDC
* `minReportBond`: `max(10% * principal, 100 USDC)`
* `confirms`: 2

### High-value markets

* `minReportBond`: set manually to a high number or rely on 10% rule to generate a large bond
* `confirms`: consider 3 or more
* `fee`: keep low to not deter liquidity

---

## Payout & fee splits (what parameters control money flow)

* `fee` (market creation fee) is paid from the creator to the contract at market creation. It is allocated as follows (with reserve portions capped by `RESERVE_TARGET_ASSETS`; overflow routes to `treasury`):

  * `reporterBountyEscrow` = `fee * CREATE_REPORTER_BOUNTY_BPS / BPS` (escrowed per-market; paid to the market truth-teller if the market becomes claimable, otherwise routed to `treasury`)
  * `reserveFunding` = `fee * CREATE_RESERVE_BPS / BPS` (added to the protocol reserve until the reserve target)
  * remainder → `treasury`

* At claim-time `tf` (total fee on yield) = `YIELD_FEE_BPS` (5%) of yield on that claim, where yield is `assetsOut - costBasis` for the redeemed shares. This yield fee is split:

  * `truthFee` = `tf * YIELD_REPORTER_REWARD_BPS / BPS` if a truth-teller exists (the reporter or challenger whose proposed outcome matches the final winner); otherwise `0`
  * `reserveFee` = `tf * YIELD_RESERVE_BPS / BPS` (added to the protocol reserve until the reserve target)
  * remainder → `treasury`

**Note:** The yield fee rate and split logic are compiled in; changing effective proportions requires redeploy.

---

## UMA appeal economics (if enabled)

When a dispute is resolved by the oracle committee, the market enters a fixed **48-hour** appeal window. Anyone can call `yPotUma.startUmaAppeal(id)` during that window if the protocol has UMA enabled (i.e. `yPot.umaModule` is set to a deployed UMA module such as `yPotUma`).

This implementation additionally requires an appeal bond based on principal:

`calcUmaAppealBond(id) = max(50 USDC, principal * 5%)`

* If UMA overturns the committee winner: the appeal bond is refunded to the appellant.
* If UMA upholds the committee winner: the appeal bond is sent to `treasury`.
* If UMA stalls past the stale timeout: `expireUmaAppeal()` falls back to the committee winner and refunds the appeal bond.

---

### UMA ancillary data (what UMA voters see)

This implementation encodes a human-readable ancillary string that includes the market description (`desc`) and relevant metadata. Note: `yPot.create()` rejects `|` in `desc`, so UMA “separator” pipes are unambiguous in the current implementation.

See `docs/UMA_ANCILLARY.md` for the exact format and recommended parsing strategy.

---

## Monitoring thresholds & alerts (recommended)

* **Large market alert** — when `m.prin > $X` (e.g., $50k) fire a high-priority alert for reporting monitoring.
* **Low pool health** — if `getPoolHealth(id)` returns `healthy == false`, show a prominent UI warning and alert operators.
* **Report posted** — notify off-chain keepers to watch challenge window.
* **Report still under confirm threshold near timeout** — escalate to confirmer-facing alerts or automation before `expireUnconfirmedReport()` becomes callable.
* **Challenge posted** — escalate to oracles and ops.
* **Challenge unresolved near expiry** — alert operators before `expireChallenge()` can cancel and refund both bonds.

---

## Tests & pre-change checks

Before executing a parameter change, run automated checks:

1. Unit tests for `create`/`bet`/`report`/`challenge`/`accept`/`resolve` flows at the new parameter values.
2. Fuzz tests for edge values near `minBet`/`maxBet`/`minReportBond`.
3. Integration test that simulates `minReportBond` floor overriding percentage-bond for small markets.
4. Governance test to ensure `prop*`/`exec*` cover the right state transitions.

---

## FAQ (parameter related)

**Q: Can I change `minReportBond` after deployment?**
A: No. `minReportBond` is immutable. In this repo’s implementation it is hardcoded to `100e6` (100 USDC); changing it requires a code change + redeploy.

**Q: Can I change `BOND_BPS` or `CHALLENGE_WINDOW` without redeploy?**
A: No — these are compile-time constants. To change them you must redeploy.

**Q: What is a safe `confirms` value?**
A: `2` works for decentralized small deployments; increase to `3` or `5` for high-value markets with more independent oracles.

---

## Final notes

This file should be updated when defaults change or after an audit. Use this file for governance proposals to state exact numeric changes and expected impact.
