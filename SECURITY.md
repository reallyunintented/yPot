# Security Policy

## Reporting Vulnerabilities

If you discover a security vulnerability in this project, please report it responsibly.

**Do not open a public issue.**

Instead, email security concerns to the project maintainers. Include:

- A clear description of the vulnerability
- Steps to reproduce (if applicable)
- Potential impact assessment

We will acknowledge receipt within 48 hours and aim to provide a fix or mitigation plan promptly.

## Scope

This policy covers the Solidity contracts in `src/`, deployment scripts in `script/`, and supporting infrastructure in `scripts/`.

Third-party dependencies (OpenZeppelin, forge-std) have their own security policies.

## Disclaimer

This software is provided as-is.

- External audit status: no completed third-party audit.
- Internal assurance: see `AUDIT_REPORT.md` and `test/audit/` for security-review findings and PoC regression tests.

Do not deploy with real funds without an independent external review.
