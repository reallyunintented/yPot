# Release Readiness (GO / NO-GO)

Last updated: 2026-03-04

This checklist is the decision gate for yPot launches.

It defines two release levels:
- `Public Beta`: real users, limited funds, explicit risk disclosure.
- `Open Production Funds`: uncapped public access with production risk posture.

If a required item is not complete, decision is `NO-GO`.

## 1) Decision Policy

Launch levels:
- `Level A: Public Beta`:
  - Allowed with strong controls and strict caps.
  - External audit may still be pending.
  - Must disclose risk clearly.
- `Level B: Open Production Funds`:
  - Requires completed third-party audit and operational maturity.
  - No placeholder infra or governance shortcuts.

Decision rule:
- Any failed required gate for target level => `NO-GO`.
- All required gates pass with evidence => `GO`.

## 2) Required Gates (Public Beta)

`B1` Contracts quality gate
- Required: yes
- Pass criteria:
  - `DEPLOYMENTS_FILE=ypot/deployments/<target>.json SUBGRAPH_NETWORK=<target-network> VITE_RPC_URL=<rpc-url> bash scripts/ci-gates.sh` passes.
  - No unresolved known critical bugs.
- Evidence:
  - command output timestamp + commit SHA.

`B2` Deployment correctness
- Required: yes
- Pass criteria:
  - non-zero `yPot`, `asset`, `vault`.
  - deployment JSON exists under `ypot/deployments/*.json`.
  - `startBlock` is real deployment block, not `0`.
- Evidence:
  - deployment JSON file + explorer links.

`B3` Frontend production preflight
- Required: yes
- Pass criteria:
  - `./scripts/release-frontend.sh` passes with target deployment file.
  - no localhost endpoints in production env.
- Evidence:
  - build logs + deployed URL.

`B4` Governance safety baseline
- Required: yes
- Pass criteria:
  - owner is multisig (no single hot EOA).
  - emergency pause path tested on target chain.
- Evidence:
  - owner address + tx hashes for ownership transfer and pause/unpause drill.

`B5` Oracle liveness baseline
- Required: yes
- Pass criteria:
  - at least 2 independent active oracle operators.
  - dispute test drill completed on target chain.
- Evidence:
  - operator roster + drill tx hashes.

`B6` Vault risk controls
- Required: yes
- Pass criteria:
  - vault due diligence documented.
  - beta TVL cap and per-market cap set.
- Evidence:
  - risk memo + configured cap values.

`B7` Monitoring and incident response
- Required: yes
- Pass criteria:
  - alerts configured for key events (`Reported`, `Challenged`, `Resolved`, pause).
  - on-call and response owner assigned.
- Evidence:
  - monitoring dashboard link + paging policy link.

`B8` User disclosure
- Required: yes
- Pass criteria:
  - app/docs explicitly state beta status and residual risks.
  - external audit status clearly stated.
- Evidence:
  - docs links and screenshots.

## 3) Additional Required Gates (Open Production Funds)

All `B*` gates must pass, plus:

`P1` External audit completion
- Required: yes
- Pass criteria:
  - independent third-party audit completed.
  - all critical/high findings fixed and verified.
- Evidence:
  - audit report URL + remediation map.

`P2` Governance hardening
- Required: yes
- Pass criteria:
  - timelock governance active for non-emergency parameter changes.
  - signer redundancy and key-management policy documented.
- Evidence:
  - timelock tx hashes + policy doc.

`P3` Oracle decentralization and SLA
- Required: yes
- Pass criteria:
  - 3+ independent oracle operators recommended.
  - formal SLA/escalation for dispute windows.
- Evidence:
  - signed operator agreement / SLA document.

`P4` Stress and chaos drills
- Required: yes
- Pass criteria:
  - completed drills for oracle outage, vault stress, and incident pause.
  - runbook updated with lessons learned.
- Evidence:
  - drill reports with timestamps and owners.

`P5` Security program
- Required: yes
- Pass criteria:
  - responsible disclosure process live.
  - bug bounty scope and severity policy published.
- Evidence:
  - policy URL + program URL.

## 4) Hard NO-GO Conditions

Automatic `NO-GO` if any are true:
- zero-address core contract in active target chain config.
- chain config still points to local (`127.0.0.1`, `localhost`) endpoints.
- owner remains single EOA for target launch.
- no tested emergency pause capability.
- no oracle operators on duty.
- unresolved critical/high audit findings for `Level B`.

## 5) Sign-off Execution

Use the repo sign-off tool:

```bash
node scripts/release-signoff.mjs init \
  --release-id <release-id> \
  --version <version> \
  --target-date <YYYY-MM-DD>

node scripts/release-signoff.mjs sign --department QA --status approved --name "<name>" --notes "<notes>"
node scripts/release-signoff.mjs sign --department Security --status approved --name "<name>" --notes "<notes>"
node scripts/release-signoff.mjs sign --department Product --status approved --name "<name>" --notes "<notes>"
node scripts/release-signoff.mjs sign --department Ops --status approved --name "<name>" --notes "<notes>"

node scripts/release-signoff.mjs verify
```

`verify` must exit `0` before GO.

## 6) Decision Record Template

Release ID:
- value:

Target level:
- value: `Public Beta` or `Open Production Funds`

Decision:
- value: `GO` or `NO-GO`

Reason:
- value:

Approvers:
- QA:
- Security:
- Product:
- Ops:

Evidence bundle:
- CI gates log:
- Deployment JSON:
- Explorer links:
- Frontend release build log:
- Incident drill report:
- Monitoring dashboard link:

---

Related docs:
- `docs/PUBLIC_BETA_DEPLOYMENT_RUNBOOK.md`
- `ypot/docs/DEPLOYMENT.md`
- `ypot/docs/THREAT_MODEL.md`
