# Security Policy

This repository contains an AWS GRC Evidence Vault reference implementation. It is designed for controlled, non-production learning and portfolio use unless an organisation has completed its own security, legal, retention, and cloud-governance review.

## Security and governance principles

- Never commit AWS credentials, Terraform state, plan files containing sensitive values, account secrets, or production evidence.
- Use a dedicated non-production AWS account for initial testing.
- Keep the default test configuration in S3 Object Lock `GOVERNANCE` mode with short retention.
- Do not enable `COMPLIANCE` retention until the retention period, account, region, and legal basis have been formally approved.
- Protect Terraform state with encryption, restricted access, locking, and an approved remote backend before production use.
- Prefer short-lived OIDC-based CI credentials over long-lived AWS access keys.
- Limit Lambda and deployment permissions using least privilege.
- Treat evidence hashes as integrity signals, not a substitute for access control, chain-of-custody procedures, or independent assurance.

## Reporting a vulnerability

Please report security concerns privately to the repository owner rather than publishing credentials, account identifiers, exploit details, or sensitive evidence in a public issue.
