# yPot Go/No-Go Checklist (2026-03-05)

Purpose: operational sign-off snapshot after a clean serial validation run.

## 1) Code/Protocol Coherence

- [x] Core lifecycle smoke test passes.
- [x] Admin access control tests pass.
- [x] Dispute and state-machine tests pass.
- [x] Tier-1 confirmation and fuzz tests pass.
- [x] UMA appeal/adapter variant suites pass.
- [x] Audit regression PoC suite passes.
- [x] Invariant suite passes (reduced config: `FOUNDRY_INVARIANT_RUNS=16`, `FOUNDRY_INVARIANT_DEPTH=64`).

Evidence (2026-03-05 run, serial):
- `forge test --match-path test/yPotSmoke.t.sol --summary` -> PASS (1/1)
- `forge test --match-path test/yPotAdminAccess.t.sol --summary` -> PASS (2/2)
- `forge test --match-path test/yPotDispute.t.sol --summary` -> PASS (7/7)
- `forge test --match-path test/yPotStateMatrix.t.sol --summary` -> PASS (7/7)
- `forge test --match-path test/yPotTier1Confirm.t.sol --summary` -> PASS (26/26)
- `forge test --match-path test/audit/ExploitPoC.t.sol --summary` -> PASS (11/11)
- `FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=64 forge test --match-path test/yPotInvariant.t.sol --summary` -> PASS (5/5)
- `forge test --match-path test/YPotGov.t.sol --summary` -> PASS (7/7)
- `forge test --match-path test/YPotViews.t.sol --summary` -> PASS (8/8)
- `forge test --match-path test/YearnWrapperEdge.t.sol --summary` -> PASS (9/9)
- `forge test --match-path test/yPotUmaBestEffort.t.sol --summary` -> PASS (4/4)
- `forge test --match-path test/yPotUmaAdapterVariants.t.sol --summary` -> PASS (4/4)
- `forge test --match-path test/yPotUmaAppeal.t.sol --summary` -> PASS (28/28)

Status: **GO for local/dev/testnet technical coherence**.

## 2) Release Gate Operability

- [ ] `forge build --force -j 1` completed in this environment.
- [ ] `./scripts/test-release.sh` completed end-to-end in this environment.
- [x] `scripts/test-release.sh` updated to shard non-invariant tests per file after a clean build.

Notes:
- Prior monolithic `forge test --force --no-match-path ...` runs consistently stalled on large test compile sets.
- Script now performs `forge build --force --skip test` then per-file test shards to avoid single massive compile units.
- A timed run confirmed the new script enters and executes shard loop successfully.

Status: **PARTIAL** (test confidence high, forced rebuild gate operability needs follow-up).

## 3) Production-Funds Readiness

- [ ] Non-local deployment JSON present (target chain, non-zero `startBlock`).
- [ ] Frontend release preflight passing against non-local chain config.
- [ ] Governance ownership transferred to multisig/timelock with verified drill.
- [ ] Oracle operator/SLA + dispute drill evidence.
- [ ] Vault risk memo + launch caps documented.
- [ ] Monitoring/on-call evidence documented.
- [ ] External independent audit completed and remediated.

Current repo evidence:
- `deployments/anvil.json` uses `chainId: 31337`, `startBlock: 0` (local only).
- `docs/RELEASE_READINESS_STATUS_2026-03-04.md` marks Public Beta and Production Funds as NO-GO.
- `SECURITY.md` states no completed third-party audit.

Status: **NO-GO for production funds**.

## Decision

- Local/dev/testnet validation: **GO**.
- Public beta on real users/funds: **NO-GO** until Section 3 items are closed.
- Open production funds: **NO-GO** until Section 3 items are closed and force-rebuild release gate is reliable.
