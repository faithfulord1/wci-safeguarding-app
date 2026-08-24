# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state (read this first)

The GitHub repository is described as "Children's Ministry Safeguarding & Attendance System - Winners
Chapel International Lewisham," but **no safeguarding/attendance application code exists in this repo
yet**. The default branch currently contains only an unrelated AWS GRC (governance/compliance) evidence
pipeline:

- `main.tf` — Terraform infrastructure
- `collector.py` — the Lambda function that infrastructure deploys

There is no `README.md`, no application source, no package manifest (`package.json`, `requirements.txt`,
etc.), no test suite, no linter config, and no CI workflows anywhere in the repo's history. Do not assume
a frontend/backend/database stack exists — check what's actually on disk before writing code that depends
on a framework, and confirm with the user before scaffolding a new application on top of this repo, since
that's a significant structural decision.

## What's here: GRC evidence collection pipeline

A small, self-contained Terraform stack that deploys a scheduled Lambda to capture AWS Config compliance
snapshots as tamper-evident evidence, for audit/compliance purposes (not part of the safeguarding app
itself).

**Architecture (`main.tf`):**
1. **Evidence vault** — an S3 bucket (`grc-evidence-vault-worm-<random>`) with versioning and
   [Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html) enabled in
   default-retention mode. Retention `mode` (`GOVERNANCE` or `COMPLIANCE`) and `retention_years` are
   Terraform variables — `GOVERNANCE` is the default for dev/test since it allows deletion by privileged
   users; `COMPLIANCE` is for production and is enforced even against the root account.
2. **Collector Lambda** (`collector.py`, Python 3.12, deployed via `archive_file` zip) — on each invocation
   it calls `config:GetComplianceSummaryByResourceType` for `AWS::S3::Bucket`, builds a JSON evidence
   payload with an `evidence_id` and UTC timestamp, computes a SHA-256 hash of the payload for tamper
   evidence, and writes it to the vault bucket with the hash and a `chain-of-custody` tag in the object
   metadata.
3. **IAM role/policy** — scoped narrowly to `config:GetComplianceSummaryByResourceType`/
   `GetComplianceDetailsByResource`, `s3:PutObject`/`PutObjectLegalHold` on the vault only, and CloudWatch
   Logs. Keep new permissions this tightly scoped if the collector's responsibilities grow.
4. **EventBridge schedule** — triggers the Lambda daily at midnight UTC (`cron(0 0 * * ? *)`).

**Conventions to preserve when editing this stack:**
- Evidence payloads are hashed with `json.dumps(..., sort_keys=True)` before hashing — keep key ordering
  deterministic if the payload schema changes, or the hash becomes non-reproducible.
- The vault's retention mode/years are variables, not hardcoded — don't hardcode `COMPLIANCE`/`GOVERNANCE`
  directly in resources.
- IAM permissions are least-privilege and resource-scoped to the vault ARN where possible; avoid widening
  to `Resource = "*"` unless the underlying AWS API requires it (as Config's read APIs currently do).

## Commands

No build/lint/test tooling is configured in this repo. For the Terraform stack, standard Terraform
workflow applies:

```bash
terraform init
terraform validate
terraform plan
terraform apply
```

There is no automated test suite for `collector.py`; validate changes by running `terraform plan`/`apply`
against a sandbox AWS account and checking the Lambda's CloudWatch logs and the resulting object in the
evidence vault.
