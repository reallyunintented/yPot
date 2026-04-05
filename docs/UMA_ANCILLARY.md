# UMA Ancillary Data Format (yPotUma)

This document specifies the UMA ancillary payload produced by the UMA appeal module:

- `src/yPotUma.sol` (contract `yPotUma`)

When a market is escalated via `yPotUma.startUmaAppeal(id)`, UMA voters see the ancillary text as the “question context” attached to the oracle request.

## Current format (as implemented)

The module constructs a single UTF-8 string via `abi.encodePacked(...)`:

`yPot market #<id> on chain <chainId> | Resolution timestamp: <resTime>: <desc> | Committee winner: <committeeWinner> | Reported outcome: <reportedOutcome> | Challenged outcome: <challengedOutcome> | Valid outcomes: 1-<outcomes> | Return the winning outcome number.`

Notes:

- `<desc>` is the on-chain market description from `yPot.getMkt(id)`.
- `yPot.create()` rejects the pipe character `|` in `desc`, so the `" | "` separators in the ancillary are not ambiguous.
- This ancillary is intended for *human interpretation* by UMA voters; for canonical state, use on-chain views (`getMkt`, `getReport`, `getAppealInfo`, etc.).
