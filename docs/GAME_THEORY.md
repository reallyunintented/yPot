# Game Theory & Incentive Design

This document formalizes the incentive assumptions and adversarial model of the yPot protocol.

yPot does not attempt to cryptographically verify real-world events. Instead, it relies on economic incentives and bounded rationality to make dishonest resolution unprofitable in expectation.

---

## Core Objective

The protocol must ensure that, for any market with non-trivial participation:

> **Reporting the true outcome is the dominant strategy.**

This is achieved via:
- bonded reporting,
- symmetric challenges,
- delayed finality,
- and an oracle backstop used only under dispute.

---

## Roles

### Bettors
- Provide liquidity by betting on outcomes.
- Are economically aligned with correct resolution.
- May also act as reporters or challengers.

### Reporter (clarified)
- First actor to report the winning outcome (any account except the market creator). Must post a bond. Only one active report is permitted per market; attempting to submit another report while one is active will revert.
- If the report is unchallenged through the `CHALLENGE_WINDOW` window, it can be accepted only after enough confirmation bonds are posted (`confirmReport`/`acceptReport`). The reporter then recovers their bond. If challenged and proven wrong, the reporter forfeits their bond.
- The market truth-teller (reporter or challenger whose proposed outcome matches the final winner) can receive an escrowed bounty funded from the market creation fee and a fixed share of the yield-only fee at claim time.

### Challenger
- Any single account may challenge an existing report by posting an equal bond and proposing an alternative outcome. The contract supports **one challenger only** (first challenger locks the dispute).
- The challenger does not need to hold a betting position. This preserves outsider monitoring, but means stale disputes must be treated as a liveness risk rather than only a cost-of-capital problem.

### Oracles
- Only involved if a dispute exists.
- Vote on the correct outcome.
- Have no economic upside from lying, only reputational downside.

---

## Market Lifecycle (Incentive-Relevant)

1. **Open**
   - Bets are placed; funds earn yield in an ERC-4626 vault.

2. **Closed**
   - Betting stops at deadline.
   - Principal is locked.

3. **Reported**
   - Any account may report an outcome after `resTime` by posting a bond.

4. **Challenge Window**
   - A fixed window (`CHALLENGE_WINDOW`) during which reports may be challenged.

5. **Resolved**
   - Either:
     - unchallenged report is accepted after sufficient confirmation bonds (`confirmReport`/`acceptReport`), or
     - oracles resolve a dispute (with an optional UMA appeal backstop, if enabled).

6. **Final**
   - Claims are enabled.

---

## Bond Economics

### Reporter Bond

The reporter bond is:

max(minReportBond, total_principal × 1000 / 10_000)  (= max(minReportBond, 10% of principal))


This ensures:
- small markets still have a meaningful bond,
- large markets scale reporter risk with value at stake.

### Challenger Bond

- Must exactly match the reporter bond.
- Makes normal disputed resolution expensive, but does not fully prevent low-net-cost griefing if the dispute later expires and both bonds are refunded.

### Bond Settlement

| Outcome | Result |
|------|------|
| Reporter correct, unchallenged | Bond returned |
| Reporter correct, challenged | Reporter receives both bonds minus a dispute rake (sent to `treasury`) |
| Challenger correct | Challenger receives both bonds minus a dispute rake (sent to `treasury`) |
| Both wrong | Bonds seized to treasury |

The “both wrong” case explicitly penalizes coordinated or negligent behavior.

### Confirmation bonds (unchallenged reports)

To accept an unchallenged report, the protocol requires additional “co-signing” value to be locked:

- Eligible confirmers: addresses that bet on the reported outcome.
- Mechanism: `confirmReport()` deposits assets into the configured ERC-4626 vault and tracks minted shares as a bond.
- Acceptance gate: `acceptReport()` requires `confirmTot >= totalPoolShares * confirmBps / 10_000`.

This makes “no challenger appeared” insufficient on its own, reducing thin-market capture risk.

These bonds are deliberately scoped to the optimistic path only. Once a challenge exists, confirmation bonds no longer affect resolution and can be withdrawn immediately; dispute incentives are then carried by the reporter/challenger bonds and the oracle/UMA path.

Another liveness nuance:
- there is no explicit confirmation cutoff at `CHALLENGE_WINDOW`. Confirmers may continue posting while the market remains unchallenged in `ST_REPORTED`.
- however, once `CHALLENGE_WINDOW + CONFIRM_TIMEOUT` has elapsed, anyone may call `expireUnconfirmedReport()` if the threshold is still unmet, cancelling the market.

---

## Dominant Strategy Analysis

### Honest Reporter

Assumptions:
- At least one rational challenger exists.
- Challenger observes a false report with non-zero probability.

Payoff:
- Honest report → bond returned + possible fee share.
- Dishonest report → high probability of losing bond.

Expected value favors honesty unless:
- challenger participation is irrationally low, or
- the market is extremely illiquid.

### Dishonest Reporter

To profit, a dishonest reporter must assume:
- no challenger appears, or
- oracles collude or fail.

This is explicitly treated as an *out-of-model failure case*.

---

## Challenger Incentives

Challengers are incentivized when:
- the reported outcome is observably false,
- and the bond size exceeds expected gas + opportunity cost.

This creates a public-goods dynamic:
- challengers are paid from dishonest reporters,
- not from protocol inflation or emissions.

---

## Oracle Backstop Model

Oracles:
- do not resolve markets by default,
- cannot preempt reporting,
- cannot extract value unless called.

They are invoked only if:
- a challenger posts bond,
- and a dispute exists.

This minimizes oracle trust surface and frequency.

---

## Yield Interaction

Yield generated by the ERC-4626 vault:
- does **not** affect outcome resolution,
- only affects payout size.

Fees are applied **only to yield**, not principal.

This ensures:
- principal is never taxed via claim fees,
- truth-teller rewards are bounded and independent of vault performance (fixed share of yield-fee + create-fee bounty).

---

## Failure Modes & Assumptions

yPot assumes the following **explicitly**:

1. **Sufficient attention**
   - At least one rational actor monitors markets of meaningful size.

2. **Bond adequacy**
   - Bonds are large relative to gas costs and coordination friction.

3. **Oracle honesty under dispute**
   - Oracles are honest or reputation-constrained.

4. **No protocol-level censorship**
   - Reporters and challengers can submit transactions.

5. **Resolution liveness**
   - Unchallenged reports need either enough confirmations or an attentive keeper to avoid stale cancellation.
   - Challenged reports need the oracle committee to reach quorum before `expireChallenge()` becomes callable.
   - If UMA is enabled, stale UMA appeals delay resolution but eventually fall back to the committee winner rather than cancelling the market.

If these assumptions fail, dishonest resolution may occur.

---

## Non-Goals

The protocol does **not** attempt to:
- guarantee truth in thin or abandoned markets,
- prevent all collusion,
- replace real-world legal enforcement.

yPot optimizes for *economic honesty*, not absolute truth.

---

## Summary

yPot resolves markets by making lying expensive, slow, and risky.

Truth emerges not from authority, but from:
- asymmetric risk,
- symmetric bonds,
- and time-delayed finality.

This is a game-theoretic system, not an oracle.
