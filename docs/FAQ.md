# FAQ.md

This FAQ is written for users, integrators, and reviewers who want clear answers without reading the full contracts. It intentionally avoids marketing language and focuses on how the system actually behaves on-chain.

---

## General

### What is this protocol?

This is an on-chain, parimutuel prediction market where all funds are deposited into a yield-bearing ERC-4626 vault while markets are open. Users bet on outcomes, yield accrues in the background, and the final payout depends on both the outcome and the share-weighted participation.

There is no central operator resolving outcomes. Resolution is handled via a bond-backed reporter + challenge mechanism, with oracle fallback only when disputes occur.

---

### Is this gambling?

Economically, yes — users are taking risk on uncertain outcomes. Technically and legally, this is a non-custodial smart contract that escrows funds, accrues yield, and redistributes assets based on publicly visible rules.

Users are responsible for understanding local regulations.

---

### What chains does this run on?

Any EVM-compatible chain with:

* A reliable ERC-20 asset (e.g. USDC)
* A trusted ERC-4626 yield vault (e.g. Yearn V3)

Security assumptions depend heavily on the chosen vault and chain.

---

## Betting & Markets

### How do I place a bet?

1. A market is created with a description, deadline, resolution time, and number of outcomes.
2. Before the deadline, users call `bet()` specifying an outcome and amount.
3. Funds are deposited into the ERC-4626 vault and converted into internal shares.

You are betting on an outcome, not a price feed.

---

### Why do earlier bets get more weight?

The protocol uses time-weighted shares. Bets placed earlier receive a higher weight multiplier than bets placed near the deadline.

This incentivizes early liquidity and reduces last-minute information sniping.

---

### Can I change or cancel my bet?

No. Once placed, bets are locked until the market resolves or is canceled.

This is intentional to keep incentives simple and avoid secondary-market complexity.

---

### What happens if nobody bets on the winning outcome?

The market is canceled during finalization. Users can withdraw their deposited vault shares via `emergencyWithdraw()` (redeeming to underlying assets).

There is no outcome-based redistribution in this case.

---

## Yield & Payouts

### Where does the yield come from?

All user funds are deposited into an ERC-4626 vault (e.g. Yearn). Yield accrues passively during the market’s lifetime.

The protocol itself does not generate yield.

---

### How are winnings calculated?

Payouts are proportional to a user’s **weighted shares** on the winning outcome relative to total weighted shares on that outcome.

This means:

* Winners share the total pool proportionally with other winning bettors
* Early participation matters
* Yield is shared among winners

---

### Are there fees?

Yes.

* A small flat fee may be charged when creating a market (paid by the market creator)
* At claim time, **5% of yield only** is taken (never on principal)
* That yield-fee is split between:

  * Treasury
  * Protocol reserve (until it reaches its target; overflow routes to treasury)
  * Truth-teller (the reporter or challenger whose proposed outcome matches the final winner)

If there is no yield, there are no claim-time fees.

---

### Can I lose my principal?

You can lose principal by betting on the wrong outcome, if the underlying ERC-4626 vault loses value, or if you fail to claim before `sweepDust()` is called (unclaimed winnings are swept to `treasury` after the sweep delay).

---

## Resolution & Reporting

### How is the winning outcome determined?

After the market’s resolution time:

1. Any account **except the market creator** may submit a report with a bond (only one active report is permitted).
2. A single challenger may dispute the report by posting an equal-sized bond during the `CHALLENGE_WINDOW` (48 hours).
3. If unchallenged, the report can be accepted **only after** enough confirmation bonds are posted (`confirmReport` / `acceptReport`, gated by `confirmBps`). If challenged, a permissioned oracle quorum decides (or `expireChallenge` refunds/cancels if oracles fail to resolve).

Everything is on-chain and publicly visible.

---

### Why is a bond required to report?

The bond makes lying expensive.

If a reporter submits a false outcome and is challenged successfully, they lose their bond. Honest reporters recover their bond and receive a small reward.

If a report is challenged and resolved, the winning side receives both bonds minus a small dispute rake routed to `treasury`.

---

### Who can challenge a report?

Anyone, by posting an equal-sized bond and proposing a different outcome.

This creates a game-theoretic incentive to correct false reports.

Note: the contract allows **one challenger only** (first challenger to post the bond locks the dispute).

---

### What are “confirmation bonds” for unchallenged reports?

Unchallenged reports are not accepted purely on “no challenger showed up”. Instead, accounts that actually bet on the reported outcome can post confirmation bonds via `confirmReport()`. Once the total confirmations reach a threshold (`confirmBps` × total pool), anyone can call `acceptReport()`.

This reduces the risk of “thin outcome capture” on low-attention markets.

Confirmation bonds are only part of the **unchallenged** path. If a report is challenged, confirmers no longer influence resolution and may withdraw their confirmation bonds immediately via `withdrawConfirmBond()`, including during later dispute states such as `APPEALABLE` and `UMA_PENDING`.

Important: if the reported outcome is very thin, the market may be unable to reach the confirmation threshold (and will cancel via `expireUnconfirmedReport()` unless someone challenges and triggers the committee/UMA path). Users betting on longshot outcomes should expect that correct resolution may require an active challenge/dispute flow.

---

### What if both the reporter and challenger are wrong?

If oracles resolve to a third outcome, **both bonds are confiscated to the treasury**.

This discourages griefing and random disputes.

---

### What if nobody reports?

If no report is submitted within a fixed window after the resolution time, the market can be expired and canceled. Users may withdraw their funds.

---

### What if oracles never resolve a dispute?

If a dispute remains unresolved for too long, the market is canceled and both reporter and challenger bonds are refunded.

This prevents permanent lockups.

---

## Oracles & Trust

### Are oracles always involved?

No.

Oracles are only used **if and only if** a report is challenged. Most markets should resolve without oracle involvement.

---

### How many oracles are required?

A configurable quorum (`confirms`) must agree on an outcome.

Higher quorum = higher safety, slower resolution.

---

### Can oracles steal funds?

No. Oracles can only influence **which outcome wins** in a disputed market.

They cannot:

* Withdraw user funds
* Change balances
* Access the vault

---

## Risk & Security

### What are the main risks?

* Betting on the wrong outcome
* Thin markets (low liquidity)
* Oracle collusion in disputed markets
* Yield vault loss or exploit
* Smart contract bugs

Note: `minReportBond` is an immutable floor for reporting costs (set at deployment); changing it requires redeploy.

These are documented in `docs/THREAT_MODEL.md`.

---

### What happens if the yield vault is exploited?

Losses are socialized across all open markets using that vault.

The protocol does not guarantee principal protection beyond what the vault provides.

---

### Can the owner rug the system?

The owner:

* Can pause new bets
* Can cancel markets
* Can change parameters (immediate in `yPot`; timelocked if `yPot` is owned by `yPotGov`)

The owner **cannot** directly withdraw user funds or vault assets.

See `THREAT_MODEL.md` for the full trust model.

---

## Emergency & Edge Cases

### What is emergency withdrawal?

If a market is canceled, users can withdraw their vault shares directly via `emergencyWithdraw()`.

This bypasses outcome resolution entirely.

---

### Can funds get stuck forever?

The protocol includes explicit expiration paths for:

* Unreported markets
* Unresolved disputes

These let markets be canceled so users can exit via `emergencyWithdraw()`. For resolved markets, claims are time-limited: unclaimed winnings can be swept after the sweep delay.

---

### What happens if nobody claims winnings?

Unclaimed funds remain in the vault until claimed. After 30 days from resolution + dispute period, anyone can call `sweepDust()` to redeem unclaimed shares and send the assets to the treasury. After a sweep, further claims are no longer possible for that market.

---

## Development & Contribution

### Is this audited?

No completed external third-party audit yet.

An internal security review with exploit PoCs and follow-up fixes is documented in `AUDIT_REPORT.md`.

Do not deploy with real funds without independent review.

---

### Where should I report bugs?

Follow the instructions in `SECURITY.md`.

Please do not disclose vulnerabilities publicly before coordinated disclosure.

---

### Is this production-ready?

Technically: close.

Economically and operationally: depends on deployment choices, oracle selection, and vault risk.

This is an experiment. Use accordingly.

---

## Final note

If something feels unclear or uncomfortable, assume it is risky. This system optimizes for transparency and incentives, not guarantees.
