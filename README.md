# Automated GRC Evidence Vault on AWS

> **Repository identity note:** the GitHub repository name `wci-safeguarding-app` is a legacy name. The code currently maintained here is the **Automated GRC Evidence Vault on AWS**. A standard `main` branch has now been created so the project can be validated and maintained normally. The repository itself should be renamed in GitHub settings when convenient so the URL matches the implementation.

A portfolio-ready GRC Engineering project that continuously collects AWS Config compliance evidence and stores it in an S3 evidence vault protected by versioning, encryption and S3 Object Lock.

## What this demonstrates

- Infrastructure as Code with Terraform
- Automated evidence collection with AWS Lambda
- Scheduled continuous assurance with EventBridge
- Immutable/WORM evidence retention with S3 Object Lock
- SHA-256 tamper-evidence and chain-of-custody metadata
- Least-privilege IAM
- Public-access blocking and TLS-only bucket access
- CloudWatch logging, retention and error monitoring
- Separation of safe test retention from production COMPLIANCE retention

## Architecture

`AWS Config -> Lambda collector -> SHA-256 evidence envelope -> S3 Object Lock vault`

`EventBridge schedule -> Lambda` and `Lambda -> CloudWatch Logs / error alarm`

Each evidence object records the collection time, AWS account, region, resource type, environment, Lambda request ID, compliance response and a SHA-256 hash. Keys are partitioned by account, environment and date for easier audit retrieval.

## Important retention warning

The repository defaults to `GOVERNANCE` mode with a short 7-day retention period so the project can be tested safely. Do not switch to `COMPLIANCE` mode until the retention requirement has been formally approved. Objects protected by COMPLIANCE retention cannot be deleted or overwritten before their retention period expires.

A production example for a seven-year requirement is 2557 days. Confirm the exact legal/regulatory retention rule before applying it.

## Prerequisites

- Terraform >= 1.6
- AWS CLI configured for the intended non-production account first
- AWS Config enabled and recording the resource types you want to assess
- IAM permissions to provision S3, Lambda, IAM, EventBridge and CloudWatch resources

## Safe test deployment

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan \
  -var="environment=Dev" \
  -var="object_lock_mode=GOVERNANCE" \
  -var="retention_days=7"
terraform apply tfplan
```

Invoke the collector once before waiting for the daily schedule:

```bash
aws lambda invoke \
  --function-name "$(terraform output -raw collector_function_name)" \
  response.json
cat response.json
```

Then inspect the vault:

```bash
aws s3api list-object-versions \
  --bucket "$(terraform output -raw evidence_vault_name)"
```

## Production promotion

Production COMPLIANCE mode should be a separate reviewed deployment, preferably in a dedicated account with protected Terraform state and a manual approval gate.

Example only, after approval:

```bash
terraform plan -out=prod.tfplan \
  -var="environment=Production" \
  -var="object_lock_mode=COMPLIANCE" \
  -var="retention_days=2557"
```

Review the plan, account and region before any production apply.

## Evidence integrity model

The collector serializes the evidence envelope into canonical JSON and calculates SHA-256 before adding the hash field. To verify an exported evidence JSON file, run:

```bash
python verify_evidence.py evidence.json
```

The verifier removes the stored `sha256_hash`, recreates the canonical representation and compares the computed digest with the recorded digest.

## GRC mapping

| GRC objective | Implementation evidence |
| --- | --- |
| Continuous evidence collection | EventBridge scheduled Lambda |
| Evidence integrity | SHA-256 digest and versioned S3 objects |
| Evidence immutability | S3 Object Lock retention |
| Confidentiality | S3 server-side encryption and public-access block |
| Least privilege | Dedicated Lambda IAM policy |
| Auditability | Evidence IDs, timestamps, account/region, request ID, CloudWatch logs |
| Monitoring | Lambda error CloudWatch alarm |
| Reproducibility | Terraform Infrastructure as Code |

This is a technical control implementation, not by itself proof of compliance with a particular regulation. The organisation must map its approved retention schedule, AWS Config rules, control owners, evidence reviewers and exception process to the relevant framework.

## Repository files

- `main.tf`: AWS infrastructure
- `collector.py`: Lambda evidence collector
- `verify_evidence.py`: offline SHA-256 evidence verifier
- `tests/test_collector.py`: unit tests for deterministic serialization and evidence writes
- `.github/workflows/terraform.yml`: formatting, validation and Python tests
- `terraform.tfvars.example`: safe test configuration example
- `.gitignore`: excludes Terraform state, plans and generated ZIP files

## Recommended next production upgrades

For a real regulated environment, consider customer-managed KMS keys, cross-account backup/replication, Security Hub/CloudTrail/IAM evidence collectors, an SNS or incident-management alarm action, DynamoDB/OpenSearch evidence indexing, protected remote Terraform state, OIDC-based CI authentication and a formal evidence review/approval workflow.
