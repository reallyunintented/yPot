# Deployment Guide

This document describes the **recommended deployment, ownership, and operational setup** for yPot (the yield-bearing prediction market protocol).

It is written for real deployments, not toy testnets.

---

## 1. Deployment Topology (Recommended)

**Minimal trust deployment:**

```
EOA / Deployer
   │
   ▼
Multisig (Owner)
   │
   ▼
`src/yPot.sol`  ───► (ERC-4626 vault) ───► (optional underlying strategy)
```

* The **core protocol** is `src/yPot.sol` (contract `yPot`)
* `yPot` interacts with a configured **ERC-4626 vault** (`vault` immutable)
* `src/YearnWrapper.sol` is an *optional* ERC-4626 vault wrapper with depositor gating (one possible vault implementation)
* The **owner** of `yPot` should be a **multisig** (and/or a timelock wrapper like `yPotGov`, see below)

**Deployment Order:**
1. Deploy (or select) an ERC-4626 vault (optionally `src/YearnWrapper.sol`, configured to wrap a Yearn-like ERC-4626)
2. Deploy `yPot` with `(asset, vault, treasury, oracles[])`
3. If using `YearnWrapper`, authorize `yPot` as a depositor via `YearnWrapper.setDepositor(yPot, true)`
4. (Optional UMA) Deploy `UmaOptimisticOracleAdapter`
5. (Optional UMA) Deploy `yPotUma` with `(pot=yPot, umaOracle=UmaOptimisticOracleAdapter)`
6. (Optional UMA) Call `yPot.setUmaModule(address(yPotUma))` — registers the module in yPot (deployer must be yPot owner at this point)
7. (Optional UMA) Call `UmaOptimisticOracleAdapter.setRequester(address(yPotUma), true)` — allowlists yPotUma in the adapter
   - **Order matters:** `setUmaModule` before `setRequester` so the module address is set when first used
   - **Ownership constraint:** `setUmaModule` is `onlyOwner` on yPot. Perform step 6 while the deployer still owns yPot (before step 9 below).
8. Deploy `yPotGov(yPot)`
9. Transfer yPot ownership to yPotGov (Ownable2Step):
   - Call `yPot.transferOwnership(address(yPotGov))` — initiates pending transfer
   - Call `yPotGov.acceptPotOwnership()` — completes Ownable2Step; yPotGov now owns yPot
10. Transfer yPotGov ownership to the intended governor (multisig / GOV_OWNER) via Ownable2Step:
    - Call `yPotGov.transferOwnership(GOV_OWNER)` — initiates pending transfer (deployer is still yPotGov owner)
    - GOV_OWNER must separately call `yPotGov.acceptOwnership()` — completes Ownable2Step; deployer no longer has any ownership

> **Automation:** Use `script/DeployGovernance.s.sol` to automate steps 3–10 in a single broadcast. Steps 6–7 (UMA wiring) must happen before step 9 because `setUmaModule` is `onlyOwner` and cannot be called through `yPotGov` (it has no gov wrapper — it’s a one-shot operation).

---

## 2. Owner Configuration (Critical)

### Owner MUST be:

* A multisig (e.g. Gnosis Safe)
* With ≥2 signers (≥3 strongly recommended)
* Protected by an operational policy (no unilateral key)

### Owner controls:

* Oracle set and quorum
* Fees, bet limits, and treasury address
* Slippage tolerance and confirmation threshold
* Emergency pause / cancel
* Reserve withdrawal

> Operational detail: market creators are forbidden from being initial reporters; include this rule in your marketplace UI and operator runbook to avoid confusion.

> **Never deploy with an EOA owner for production.**

---

## 3. Oracle Setup

### Initial Oracle Set

* Minimum: **2 independent oracles** (required by the yPot constructor)
* Recommended: **3–5 oracles**
* Oracles should:

  * Be operated by independent entities
  * Have reputational or financial skin-in-the-game
  * Be reachable during disputes

### Quorum (`confirms`)

* Default: `2`
* Must satisfy: `2 ≤ confirms ≤ oracleN`
* `setConfirms` enforces `confirms > oracleN / 2` (strict majority) at the time you set it, to prevent split-brain races
* When adding/removing oracles, re-check quorum: adding oracles can make an existing `confirms` no longer a strict majority
* Increasing quorum increases safety but also increases liveness risk

> Oracles are **only used on dispute**. They are a backstop, not the primary resolution path.

### UMA Optimistic Oracle (optional dispute backstop)

yPot supports an optional UMA **appeal** path (after committee resolution) via the external UMA module `yPotUma`:

- `startUmaAppeal(id)`
- `settleUmaAppeal(id)`
- `expireUmaAppeal(id)`

Notes:
* This is not “free decentralization”: it adds operational complexity and can increase dispute cost/latency.
* Deployers must choose a UMA identifier/currency pair supported on their chain.
* UMA escalation is only possible after a dispute was challenged and the committee reached quorum (market enters the appeal window).
* The appeal window is fixed at **48 hours** after committee quorum.
* `startUmaAppeal()` requires an appeal bond based on market principal: `max(50 USDC, 5% of principal)` (see `calcUmaAppealBond(id)`). If the appeal overturns the committee decision (or UMA stalls and the protocol falls back), this bond is refunded; otherwise it is sent to `treasury`.
* In this repo’s implementation, `startUmaAppeal()` funds UMA using the existing **reporter + challenger bonds** already held by yPot (it transfers them into the adapter just-in-time). The adapter does not need to be pre-funded for the dispute bond.
* yPot uses the adapter’s per-request flow with **reward = 0**.
* UMA ancillary data includes the market `desc` and basic metadata. For the exact string format, see `docs/UMA_ANCILLARY.md`.

### Practical note: multisigs vs oracle addresses

`yPot` treats oracles as a set of **addresses** with a **quorum** (`confirms`).

* You must deploy with **2+** oracle addresses, and quorum is always at least `2`.

If you want multisig-controlled dispute resolution, use one or more Safe addresses as oracles — but note that a single-address oracle set is not supported by this contract (it requires **2+** distinct oracle addresses, and `confirms >= 2`).

---

## 4. Vault & Asset Assumptions

* Asset **must have 6 decimals** (e.g. USDC)
* Vault **must implement ERC‑4626 correctly**
* Vault loss risk is explicitly accepted

Before deployment:

* Verify `vault.asset()` matches `asset`
* Verify `vault.totalAssets()` behavior
* Simulate loss scenarios (vault drawdown)

---

## 5. Parameter Initialization Checklist

Before opening markets:

* `minBet` / `maxBet` sane for asset
* `minReportBond` is immutable at `100e6` (100 USDC); verify this is adequate for your deployment
* `fee` low enough to not kill market creation
* `treasury` set to a monitored address

If `yPot` is owned by `yPotGov`, parameter changes are **timelocked** — schedule, announce, then execute. Emergency actions (pause/cancel) and YearnWrapper admin actions (e.g. `setDepositor`) are immediate.

---

## 6. Operational Monitoring (Strongly Recommended)

Run keepers / alerts for:

* `Reported(id, reporter, outcome)`
* `Challenged(id, challenger, outcome)`
* `Resolved(id, outcome)`
* `Cancelled(id)`
* `expireMarket` / `expireChallenge` eligibility
* Unchallenged report acceptance readiness (`acceptReport` gated by `confirmBps`) and liveness fallback (`expireUnconfirmedReport`)

Failure to act during windows can result in:

* Incorrect outcomes becoming final
* Funds being locked longer than expected

---

## 7. Emergency Procedures

### Pause

* Use when:

  * Vault misbehaves
  * Unexpected accounting behavior
  * Ongoing exploit investigation

Pause stops new market creation (`create`), betting (`bet`), confirmation bonds (`confirmReport`), and reserve funding (`fundReserve`). `close()`, reporting/disputes, `finalize()`, and withdrawals/claims remain available.

### Cancel Market

* Use sparingly
* Cancels unresolved markets
* Users can emergency-withdraw their vault shares (amount may be below principal if the vault loses value)

### Emergency Exit Vault

* Pulls all funds from Yearn into wrapper
* Does NOT distribute funds
* Claims continue from local balance

---

## 8. Post‑Deployment Verification

After deployment:

* Create a test market
* Place bets on all outcomes
* Walk full lifecycle:

  * Close → Report → Challenge → Resolve → Finalize → Claim

Verify:

* Bonds move correctly
* Shares and payouts are proportional
* Fees route as expected

---

## 9. Human Assumptions (Explicit)

This protocol assumes:

* Someone monitors markets
* Someone challenges dishonest reports
* Oracles respond during disputes

If **nobody shows up**, the protocol will still function — but may not function *correctly*.

This is not a bug; it is an explicit design trade‑off.

---

## 10. Summary

yPot can be deployed safely with:

* Conservative parameters
* Active monitoring
* Independent oracles
* A disciplined multisig owner

Neglecting any of the above materially increases risk.

See `docs/THREAT_MODEL.md` and `docs/GAME_THEORY.md` for deeper reasoning.
