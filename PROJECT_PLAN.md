# FinOps Cost Optimization Dashboard — Build Spec
**Repo: finops-dashboard | Target: intermediate/mid-level | Owner: RJ Noord**

Drop this file in the repo root as `PROJECT_PLAN.md` and reference it in Claude Code sessions. Each phase = one focused session ending in a commit.

---

## The Business Problem (put this in your README)

A mid-size company's AWS bill grows 8–12% monthly with no clear owner. Finance can't allocate costs because tagging is inconsistent; engineering leaves idle resources running; nobody notices anomalies until the invoice. This platform gives a FinOps function three capabilities: **visibility** (where money goes, by team/service), **accountability** (tag compliance enforcement), and **action** (ranked savings opportunities with AI-generated remediation plans).

### KPIs the dashboard reports
- Monthly spend trend + forecast vs. budget
- Tag compliance % (resources with required `Owner`, `Environment`, `CostCenter` tags)
- Identified monthly savings ($ from idle/oversized/orphaned resources)
- Anomalies detected and time-to-detection

---

## Architecture

```
Cost & Usage Report (CUR) ──> S3 ──> Athena (SQL analysis)
Cost Explorer API ─────────────────────┐
CloudWatch metrics (EC2 CPU, etc.) ────┤
                                       ▼
                          Lambda collectors (Python, EventBridge daily)
                                       │
                          DynamoDB (findings + daily aggregates)
                                       │
                ┌──────────────────────┼──────────────────────┐
                ▼                      ▼                      ▼
        Streamlit dashboard    Bedrock summarizer      SNS alerts
        (local / App Runner)   (weekly exec report     (anomalies,
                                via SES or SNS)         budget breach)
```

Supporting services: AWS Budgets, Cost Anomaly Detection, IAM (least-privilege per Lambda), KMS for DynamoDB/S3 encryption. **Everything provisioned by Terraform.**

### Cost guardrails for the lab itself
- Billing alarm at $10 on day one; CUR + Athena costs pennies at this scale
- Seed "wasteful" resources briefly (t3.micro idle, small unattached EBS, old snapshot), let collectors detect them, screenshot, destroy
- `terraform destroy` after each documented run; DynamoDB on-demand billing

---

## Repo Structure

```
finops-dashboard/
├── .github/workflows/
│   ├── ci.yml            # lint, test, scan on every PR
│   ├── plan.yml          # terraform plan + Infracost comment on PR
│   └── deploy.yml        # terraform apply on merge to main
├── terraform/
│   ├── modules/
│   │   ├── cur_athena/
│   │   ├── collectors/   # Lambdas + EventBridge + DynamoDB
│   │   ├── alerting/     # Budgets, anomaly detection, SNS
│   │   └── oidc_github/  # the IAM role GitHub assumes
│   ├── envs/dev/         # backend.tf (S3 state + DynamoDB lock), main.tf
│   └── envs/prod/        # even if unused, shows multi-env thinking
├── src/
│   ├── collectors/
│   │   ├── idle_ec2.py
│   │   ├── orphaned_storage.py
│   │   ├── tag_compliance.py
│   │   └── cost_aggregator.py
│   ├── bedrock_reporter/summarizer.py
│   └── shared/           # boto3 clients, models, config
├── dashboard/app.py      # Streamlit
├── tests/                # pytest + moto (mocked AWS)
├── docs/architecture.md  # diagram (Mermaid) + decision log
└── PROJECT_PLAN.md       # this file
```

---

## Build Phases (one Claude Code session each)

### Phase 1 — Foundation & OIDC
- Terraform remote state: S3 bucket + DynamoDB lock table (bootstrap manually or with a tiny init config)
- `oidc_github` module: IAM OIDC provider for `token.actions.githubusercontent.com`, role with trust policy locked to `repo:Rjnoord/finops-dashboard:ref:refs/heads/main` (and a plan-only role for PRs)
- Billing alarm at $10
- **Interview story:** why OIDC beats stored keys — short-lived creds, no rotation, trust scoped to repo+branch

### Phase 2 — CI Pipeline (before any app code — real teams build the pipeline first)
- `ci.yml`: terraform fmt -check, validate, tflint, checkov (or tfsec), ruff + black --check, pytest
- `plan.yml`: assume plan role via OIDC, `terraform plan`, post plan output as PR comment; add Infracost cost-diff comment
- `deploy.yml`: on merge to main, assume deploy role, `terraform apply -auto-approve` with plan artifact
- Branch protection on main: PR required, CI must pass
- **Interview story:** plan-on-PR / apply-on-merge is the standard IaC promotion flow

### Phase 3 — CUR + Athena
- Terraform: CUR definition (daily, parquet) → S3, Glue database/crawler or CUR-provided CloudFormation-equivalent tables, Athena workgroup with query result location + per-query byte limit
- Write 4–5 saved Athena queries: spend by service, spend by tag:CostCenter, untagged spend, daily trend
- **Note:** CUR takes up to 24h to first deliver — build Phase 4 while waiting

### Phase 4 — Collectors
- `idle_ec2.py`: instances with <5% avg CPU over 7 days (CloudWatch GetMetricData) → finding with estimated monthly waste
- `orphaned_storage.py`: unattached EBS volumes, snapshots >90 days with no AMI, unassociated Elastic IPs
- `tag_compliance.py`: Resource Groups Tagging API, check required tag set, compute compliance %
- `cost_aggregator.py`: Cost Explorer API daily grain → DynamoDB aggregates
- Each Lambda: own least-privilege IAM role (no `*` resources), EventBridge daily schedule, structured JSON logging, DLQ
- Tests with moto for each collector — CI must run them

### Phase 5 — Alerting & AI Reporting
- AWS Budgets (monthly, 80%/100% thresholds → SNS) + Cost Anomaly Detection monitor → SNS
- `summarizer.py`: pull week's findings from DynamoDB → Bedrock prompt → executive summary (top 3 savings actions, ranked by $) → SNS/SES weekly
- Prompt lives in repo, versioned — treat prompts as code

### Phase 6 — Dashboard
- Streamlit: spend trend chart, service breakdown, tag compliance gauge, findings table sorted by savings, anomaly timeline
- Reads DynamoDB + runs canned Athena queries; read-only IAM
- Run locally for screenshots; App Runner deploy optional (costs ~$5/mo if left up — deploy, screenshot, tear down)

### Phase 7 — The Simulation & Writeup
- Seed wasteful resources via a `terraform/scenarios/wasteful` config
- Let collectors run, capture findings + Bedrock report + dashboard screenshots
- Destroy scenario, document: "identified $X/month in savings across N resources; tag compliance 62%→94% after enforcement"
- `docs/architecture.md`: Mermaid diagram + 5 decision-log entries (why CUR over CE-only, why OIDC, why DynamoDB over RDS, why Streamlit, why plan/apply split)
- README rewrite around the business problem + KPIs + screenshots

---

## Resume Bullets This Produces (X-Y-Z format)

- Built a FinOps analytics platform on AWS (CUR, Athena, Lambda, DynamoDB, Bedrock) that identified $X/month in savings opportunities across idle compute, orphaned storage, and untagged spend
- Implemented a GitOps deployment pipeline using GitHub Actions with OIDC federation (zero stored credentials), automated Terraform plan-on-PR with Infracost cost-impact comments, and policy scanning via Checkov
- Automated cost anomaly detection and AI-generated executive savings reports using AWS Cost Anomaly Detection, Budgets, and Amazon Bedrock, cutting reporting effort from hours to minutes

## Interview Questions This Prepares You For
1. How would you reduce our AWS bill? (walk the collector logic)
2. How do you secure CI/CD access to cloud accounts? (OIDC deep-dive)
3. How do you enforce tagging at scale? (compliance collector → next step: SCPs/tag policies — mention as roadmap)
4. Terraform state management? (S3 + locking, plan/apply separation)
5. Where would you take this next? (multi-account via Organizations, tag policies, rightsizing recommendations from Compute Optimizer)
