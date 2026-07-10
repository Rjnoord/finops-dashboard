# Security policy

Report suspected vulnerabilities privately through GitHub security advisories. Do not include credentials, account identifiers, billing exports, or Terraform state in a public issue.

GitHub Actions uses OIDC instead of stored AWS access keys. Local `.tfvars`, state, generated plans, cloud exports, and environment files must remain untracked.
