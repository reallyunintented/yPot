# Liveness Risks

This note documents live resolution-delay and cancellation paths that are present by design in the current `src/` contracts.

These are not direct theft bugs. They matter because they determine when a valid market can be delayed, cancelled, or forced onto a slower resolution path if monitoring or oracle liveness is weak.

## 1. Under-Confirmed Unchallenged Reports

Path:
- `report()`
- no `challenge()`
- confirmations remain below `confirmBpsSnapshot`
- anyone calls `expireUnconfirmedReport()` after `reportedAt + CHALLENGE_WINDOW + CONFIRM_TIMEOUT`

Outcome:
- market moves to `ST_CANCELLED`
- reporter bond is refunded
- bettors exit via `emergencyWithdraw()`
- confirmers can later withdraw their confirmation bonds

Important nuance:
- `confirmReport()` is not capped by the challenge window.
- Confirmations may continue after `CHALLENGE_WINDOW` while the market remains unchallenged in `ST_REPORTED`.
- The market becomes cancellable after the timeout; it does not auto-cancel.

Why it matters:
- an otherwise valid report can still be cancelled if no one completes the confirm threshold before a third party calls expiry
- this is a protocol liveness/design tradeoff, not a theft path

## 2. Stale Challenges

Path:
- anyone calls `challenge()` with the reporter bond amount
- oracle committee never reaches quorum
- anyone calls `expireChallenge()` after `reportedAt + CHALLENGE_WINDOW + 7 days`

Outcome:
- market moves to `ST_CANCELLED`
- reporter and challenger bonds are both refunded
- bettors exit via `emergencyWithdraw()`

Why it matters:
- `challenge()` does not require the challenger to hold a market position
- if dispute liveness is poor, stale challenges become a low-net-cost griefing vector
- the main attacker costs are time, gas, and temporary capital lock rather than permanent slashing

## 3. Stale UMA Appeals

Path:
- anyone calls `startUmaAppeal()` during `ST_APPEALABLE`
- UMA does not settle cleanly before `UMA_STALE_TIMEOUT`
- anyone calls `expireUmaAppeal()`

Outcome:
- market falls back to the committee winner via `umaResolve()`
- appeal bond is refunded
- the market is delayed, not cancelled

Why it matters:
- this path extends resolution latency
- it does not create a second cancellation route

## Operational Guidance

- Monitor `report()` events and alert when a market remains under the confirmation threshold near `CHALLENGE_WINDOW + CONFIRM_TIMEOUT`.
- Monitor challenged markets and alert before `expireChallenge()` becomes callable.
- If UMA is enabled, alert on `ST_UMA_PENDING` markets well before the stale timeout.
- Treat these paths as explicit operational assumptions in audits and deployment docs.

## Possible Mitigations

- Add a non-refundable rake or penalty on stale `challenge()` expiry.
- Add better confirmer incentives or keeper automation around under-confirmed reports.
- Keep oracle quorum sized for both safety and practical liveness.
- Document clearly that UMA stale expiry falls back to the committee winner rather than cancelling the market.
