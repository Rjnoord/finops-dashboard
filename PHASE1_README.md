# Phase 1 — Foundation & OIDC

What this phase creates:
- Remote state backend (S3 + DynamoDB lock) via a one-time bootstrap
- GitHub OIDC identity provider + two IAM roles (plan for PRs, deploy for main)
- $10 billing alarm with email alerts

## Setup order

**1. Bootstrap the state backend (one time, local state):**
```bash
cd terraform/bootstrap
terraform init
terraform apply
```
If the bucket name is taken, rerun with `-var state_bucket_name=<unique-name>` and update `envs/dev/backend.tf` + `envs/dev/variables.tf` to match.

**2. Enable billing alerts (one-time console step):**
Billing console → Billing Preferences → check "Receive CloudWatch Billing Alerts." The alarm can't see the metric until this is on.

**3. Deploy the dev environment:**
```bash
cd terraform/envs/dev
cp terraform.tfvars.example terraform.tfvars   # put your real email in it
terraform init
terraform plan
terraform apply
```
Confirm the SNS subscription email AWS sends you, or alerts go nowhere.

**4. Wire GitHub to AWS:**
Copy the two output ARNs into the repo: Settings → Secrets and variables → Actions → **Variables** (not secrets — role ARNs aren't sensitive):
- `AWS_PLAN_ROLE_ARN` = plan_role_arn output
- `AWS_DEPLOY_ROLE_ARN` = deploy_role_arn output

Phase 2 workflows will reference these.

## What to say in the README / interview

- **Why OIDC:** GitHub mints a short-lived signed token per workflow run; AWS STS verifies it against the trust policy and issues temporary credentials. Nothing long-lived is stored anywhere, nothing to rotate, nothing to leak.
- **Why two roles:** PRs can come from any branch, so the plan role is read-only + state lock. Only merges to protected `main` can assume the deploy role — the trust policy enforces `ref:refs/heads/main` with an exact StringEquals match.
- **Why scoped IAM on deploy:** PowerUserAccess denies IAM entirely; the deploy role gets IAM actions only on `finops-*` named roles/policies, so a compromised pipeline can't escalate by creating an admin role.

## Commit message
```
Phase 1: remote state backend, GitHub OIDC roles, billing alarm

- S3 + DynamoDB Terraform backend (bootstrap config)
- OIDC provider with branch-scoped plan/deploy roles, no stored AWS keys
- $10 billing guardrail with SNS email alerts
```
