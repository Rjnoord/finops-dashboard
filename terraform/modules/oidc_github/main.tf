# GitHub Actions OIDC federation.
# Creates the identity provider and TWO roles:
#   - plan role:   assumable from pull requests, read-only + state access
#   - deploy role: assumable ONLY from the main branch, can apply changes
# This is the zero-stored-credentials pattern: GitHub mints a short-lived
# OIDC token per workflow run; AWS STS exchanges it for temporary creds.

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS validates GitHub's cert against trusted root CAs; thumbprint is
  # still a required field but no longer security-critical for this issuer.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = { Project = "finops-dashboard" }
}

locals {
  repo_sub_main = "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"
  repo_sub_pr   = "repo:${var.github_org}/${var.github_repo}:pull_request"
}

# ---------- Plan role (pull requests) ----------

data "aws_iam_policy_document" "assume_plan" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.repo_sub_pr, local.repo_sub_main]
    }
  }
}

resource "aws_iam_role" "plan" {
  name                 = "finops-github-plan"
  assume_role_policy   = data.aws_iam_policy_document.assume_plan.json
  max_session_duration = 3600
  tags                 = { Project = "finops-dashboard" }
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess does not cover the Cost and Usage Report API, which
# terraform plan needs to refresh the CUR definition in state.
data "aws_iam_policy_document" "plan_cur_read" {
  statement {
    sid       = "CurRead"
    actions   = ["cur:DescribeReportDefinitions"]
    resources = ["arn:aws:cur:us-east-1:${data.aws_caller_identity.current.account_id}:definition/*"]
  }
}

resource "aws_iam_policy" "plan_cur_read" {
  name   = "finops-plan-cur-read"
  policy = data.aws_iam_policy_document.plan_cur_read.json
}

resource "aws_iam_role_policy_attachment" "plan_cur_read" {
  role       = aws_iam_role.plan.name
  policy_arn = aws_iam_policy.plan_cur_read.arn
}

# Plan needs to read/write state objects and take the state lock.
data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/*"]
  }
  statement {
    sid       = "StateBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }
  statement {
    sid     = "StateLock"
    actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [
      "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.lock_table}"
    ]
  }
}

resource "aws_iam_policy" "state_access" {
  name   = "finops-tf-state-access"
  policy = data.aws_iam_policy_document.state_access.json
}

resource "aws_iam_role_policy_attachment" "plan_state" {
  role       = aws_iam_role.plan.name
  policy_arn = aws_iam_policy.state_access.arn
}

# ---------- Deploy role (main branch only) ----------

data "aws_iam_policy_document" "assume_deploy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals" # exact match — deploy trust is main only
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.repo_sub_main]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = "finops-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.assume_deploy.json
  max_session_duration = 3600
  tags                 = { Project = "finops-dashboard" }
}

# PowerUser covers all service resources but denies IAM. Terraform will
# manage IAM roles for the Lambdas, so grant IAM narrowly: only on roles
# and policies whose names start with the project prefix.
resource "aws_iam_role_policy_attachment" "deploy_poweruser" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "deploy_iam_scoped" {
  statement {
    sid = "ProjectScopedIam"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:PassRole",
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:TagPolicy",
      "iam:GetPolicyVersion", "iam:ListPolicyVersions", "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/finops-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/finops-*"
    ]
  }

  # Terraform state includes the OIDC provider itself, so plan/refresh from
  # the deploy role must be able to read (and tag) it.
  statement {
    sid = "OidcProviderManage"
    actions = [
      "iam:GetOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider",
      "iam:UntagOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:AddClientIDToOpenIDConnectProvider",
      "iam:RemoveClientIDFromOpenIDConnectProvider"
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
    ]
  }
}

resource "aws_iam_policy" "deploy_iam_scoped" {
  name   = "finops-deploy-iam-scoped"
  policy = data.aws_iam_policy_document.deploy_iam_scoped.json
}

resource "aws_iam_role_policy_attachment" "deploy_iam" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.deploy_iam_scoped.arn
}

resource "aws_iam_role_policy_attachment" "deploy_state" {
  role       = aws_iam_role.deploy.name
  policy_arn = aws_iam_policy.state_access.arn
}
