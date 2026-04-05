# yPot

Yield-bearing parimutuel prediction markets with a bonded resolution game, optional UMA appeal, and an ERC-4626 vault back-end.

This public repository contains the Solidity / Foundry protocol project only.
Frontend, subgraph, and website deployment assets are intentionally not included here.

This repository is a Foundry project (`forge`).

## Contracts

- Core: `src/yPot.sol` (`yPot`)
- Vault wrapper (optional): `src/YearnWrapper.sol` (`YearnWrapper`)
- Governance timelock wrapper (recommended): `src/yPotGov.sol` (`yPotGov`)
- UMA appeal module (optional): `src/yPotUma.sol` (`yPotUma`)
- UMA adapter (optional): `src/UmaOptimisticOracleAdapter.sol` (`UmaOptimisticOracleAdapter`)
- Off-chain lens: `src/yPotViews.sol` (`yPotViews`)

## High-Level Design

- **Asset**: the protocol is designed for a 6-decimal ERC-20 (e.g. USDC). `yPot` enforces `decimals() == 6`.
- **Vault**: all funds are deposited into an immutable ERC-4626 vault (or wrapper). The protocol holds commingled vault shares and accounts users per market.
- **Markets**: users bet on outcomes. Winners redeem a pro-rata share of the entire pool (parimutuel), using a time-weighted share multiplier.
- **Resolution**:
  - Tier 1: bonded report
  - Tier 2: single bonded challenge + committee vote by permissioned oracles
  - Tier 3 (optional): UMA appeal via an external module

This system is **economically secure and optimistic**, not cryptographically trustless. See `docs/THREAT_MODEL.md`.

## Docs

- Deployment: `docs/DEPLOYMENT.md`
- Parameters: `docs/PARAMETERS.md`
- Threat model: `docs/THREAT_MODEL.md`
- Incentives/game theory: `docs/GAME_THEORY.md`
- Liveness risks: `docs/LIVENESS_RISKS.md`
- FAQ: `docs/FAQ.md`
- Error decoding (integrations): `docs/ERROR_DECODING.md`
- UMA ancillary format: `docs/UMA_ANCILLARY.md`
- Spec (this repo): `SPEC.md`

## Quickstart

Requirements:
- Foundry (`forge`)

Commands:
```bash
forge test
```

Notes:
- `foundry.toml` uses `via_ir = true`, so compiles can be slower than typical.

## Release Validation

Run the strict pre-release test gate:

```bash
./scripts/test-release.sh
```

This command:
- builds with the configured release settings
- forces a fresh compile and full test execution (not incremental cache-only runs)
- runs the full test suite
- runs invariants in a dedicated pass

By default it uses all available logical CPUs (`JOBS=0`). Override if needed:

```bash
JOBS=12 ./scripts/test-release.sh
```

For public release hardening (lint warnings treated as failures):

```bash
STRICT_LINT=1 JOBS=12 ./scripts/test-release.sh
```

## Testnet Deploy (Core)

1. Set required environment variables (see `.env.testnet.example` for names).
2. Run:

```bash
./scripts/deploy-testnet.sh
```

The script deploys `yPot` using `script/DeployyPot.s.sol` and supports optional explorer verification when `ETHERSCAN_API_KEY` is set.

For local-stack or preview deploys, the helper scripts write deployment JSON under `deployments/`.
For manual deployments, record the deployed addresses and `startBlock` in your own `deployments/<target>.json`.

Safety guard:
- `deploy-testnet.sh` blocks known mainnet chain IDs by default.
- Override only for intentional production promotion with:
  - `ALLOW_MAINNET_DEPLOY=1`

## Security Notes (Read Before Deploying)

- **Owner powers**: `yPot` has immediate owner-only setters (fees, limits, oracles, quorum, slippage) plus `pause` and pre-resolution `cancel`. For timelocked parameter changes, transfer ownership to `yPotGov` (`src/yPotGov.sol`).
- **Oracles**: disputes are decided by a permissioned oracle set. Liveness and correctness depend on oracle availability/honesty.
- **Liveness tradeoffs**: under-confirmed unchallenged reports can be cancelled, stale challenges can cancel and refund both bonds, and stale UMA appeals fall back to the committee winner. See `docs/LIVENESS_RISKS.md`.
- **Vault risk**: the ERC-4626 vault is an external dependency. Vault insolvency, withdrawal gating, or non-compliance can impact user funds.
- **UMA module**: enabling UMA is a one-shot `setUmaModule` action; review `src/yPot.sol` + `src/yPotUma.sol` + `src/UmaOptimisticOracleAdapter.sol` together before using it.

## Tests

- Unit/invariant tests live under `test/`.
- Adversarial search and harnesses live under `test/adversarial/`.

## License

MIT, see `LICENSE`.
