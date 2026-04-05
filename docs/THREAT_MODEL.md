# Threat Model

This document enumerates the explicit threats, adversaries, and failure modes considered in the design of yPot.

yPot is an economically secure system, not a cryptographically trustless one. Some attacks are mitigated by incentives; others are accepted as out-of-scope.

---

## Assets at Risk

1. **User principal** deposited into ERC-4626 vaults
2. **Accumulated yield** generated during market lifetime
3. **Reporter and challenger bonds**
4. **Protocol fee flows** (treasury, reserve, truth-teller)

The protocol never mints value; all losses are redistributions between participants or external vault risk.

## Quick trust summary

yPot stores questions and user positions fully on-chain and resolves outcomes using a bonded reporter → challenger game with a permissioned committee vote (and optional UMA appeal).

Quick facts:
- Anyone **except the market creator** may post a report; only one active report exists at a time.
- A single challenger (equal bond) may contest a report during the challenge window.
- Dishonest reporting is economically costly, but the system does **not** cryptographically verify off-chain facts — the final result is decided by economic incentives and oracle votes if a dispute occurs.
- `minReportBond` is immutable (set at deployment); changing it requires a redeploy.

### Trusted roles & dependencies (explicit)

If you deploy this in the real world, users are trusting the following parties/components:

- **Owner (admin key / multisig)**: can pause creation/betting and can cancel markets pre-resolution. The owner can also change key parameters (immediate in `yPot`; timelocked if `yPot` is owned by `yPotGov`) and change the oracle set/quorum.
  - Operational note: unlike `YearnWrapper`, `yPot` and `yPotGov` do not disable `renounceOwnership()`. Renouncing permanently removes those admin capabilities.
- **Oracles (permissioned addresses)**: oracles are not decentralized by default. During disputes, the oracle quorum can decide the final outcome. If they collude, are coerced, or go offline, markets may resolve incorrectly or fail to resolve.
- **UMA appeal (optional)**: if you enable UMA via `UmaOptimisticOracleAdapter`, challenged markets that were resolved by the committee can be appealed to UMA. This can improve neutrality vs a local committee, but introduces its own governance/latency/cost assumptions.
- **ERC-4626 vault and underlying strategy (e.g., Yearn)**: the vault is an external trusted dependency. If it is buggy, malicious, insolvent, or violates ERC-4626 assumptions, user funds can be lost or withdrawals can break.
- **Off-chain monitoring (“someone shows up”)**: the incentive design assumes challengers/oracles are online when it matters. Low-attention markets are easier to attack.
  - Important nuance: the protocol’s security is still fundamentally optimistic. If nobody challenges a false report within the challenge window, a dishonest reporter can still win if they can also meet the confirmation threshold for unchallenged acceptance.

---

## Adversary Classes

### 1. Dishonest Reporter

**Goal:** Resolve a market to an incorrect outcome to extract value.

**Capabilities:**

* Can post a report with sufficient bond
* Can choose timing strategically

**Mitigations:**

* Bond sized to market principal
* Open challenge window
* Oracle backstop on dispute

**Residual Risk:**

* Thin or abandoned markets where no challenger appears. Confirmation bonds reduce (but do not eliminate) this risk by requiring additional locked capital and, in many configurations, making very thin reported outcomes unable to resolve unchallenged. Once a challenge exists, confirmation bonds no longer secure the outcome and are withdrawable.

---

### 2. Dishonest Challenger

**Goal:** Grief reporter or force oracle involvement.

**Capabilities:**

* Can post challenge bond
* Does not need to hold a market position

**Mitigations:**

* Symmetric bond requirement
* Loss of bond if incorrect

**Residual Risk:**

* Temporary delay of resolution
* If the committee never reaches quorum, `expireChallenge()` cancels the market and refunds both bonds. This makes stale challenges a low-net-cost griefing vector rather than a theft path.

---

### 3. Oracle Collusion or Failure

**Goal:** Force incorrect resolution during disputes.

**Capabilities:**

* Vote incorrectly once dispute exists

**Mitigations:**

* Oracles only invoked on challenge
* Configurable quorum
* Intended use with reputation-bound operators

**Residual Risk:**

* Incorrect resolution if oracle quorum colludes

---

### 4. Market Creator Abuse

**Goal:** Create misleading or ambiguous markets.

**Capabilities:**

* Controls market description text

**Mitigations:**

* Immutable description
* Public visibility before betting

**Residual Risk:**

* Social-engineering via vague wording

---

### 5. Thin Market Exploitation

**Goal:** Profit from low participation and low attention.

**Capabilities:**

* Monitor for markets with low principal

**Mitigations:**

* Minimum report bond
* Confirmation bonds required before accepting an unchallenged report (`confirmReport` / `acceptReport`, gated by `confirmBps`)
* Once a report is challenged, confirmer capital is no longer part of dispute security; reporter/challenger bonds and oracle escalation carry the dispute path
* Public monitoring

**Residual Risk:**

* Markets below economic attention threshold
* An under-confirmed but otherwise valid report can be cancelled by anyone via `expireUnconfirmedReport()` once the report is older than `CHALLENGE_WINDOW + CONFIRM_TIMEOUT`
* **Operator sizing note:** Confirmation bond holders can call `withdrawConfirmBond()` as soon
  as a `challenge()` is confirmed (before committee vote or UMA resolution completes). Bond
  capital does not stay locked for the full dispute lifecycle. Operators running high-stakes
  markets should size `confirmBps` so that the bond is economically meaningful even assuming
  early exit — e.g. bond value ≥ 2× gas overhead — rather than assuming it persists as
  a stake through resolution.

---

### 6. ERC-4626 Vault Risk

**Goal:** External vault loss or insolvency.

**Capabilities:**

* Vault strategy loss
* Exploit in vault contract

**Mitigations:**

* Vault address fixed at deployment
* Yield-only fee model

**Residual Risk:**

* Partial or total loss of assets

---

### 7. MEV & Transaction Ordering

**Goal:** Extract value via reordering or censorship.

**Capabilities:**

* Reorder report/challenge transactions

**Mitigations:**

* Time-based windows, not first-block wins

**Residual Risk:**

* Short-term reporting advantage

---

### 8. Admin Key Compromise

**Goal:** Malicious parameter changes or oracle manipulation.

**Capabilities:**

* Access to owner functions

**Mitigations:**

* Timelocked parameter changes
* Intended multisig ownership

**Residual Risk:**

* Governance failure

---

## Explicitly Out-of-Scope Threats

The protocol does not defend against:

* Nation-state censorship
* Universal oracle collusion
* Social consensus failures
* Extremely low-liquidity markets
* Real-world coercion of oracle operators

---

## Invariants

The following properties are always preserved by the contract:

* Fees apply only to yield (not principal)
* Unclaimed winnings can be swept after `DISPUTE_PERIOD + SWEEP_DELAY` from resolution (once claimable)
* Bonds are redistributed, never minted
* Oracles cannot act without a dispute

---

## Summary

yPot assumes adversarial behavior and minimizes trust where possible.

Where trust is unavoidable, it is made explicit, narrow, and economically constrained.
