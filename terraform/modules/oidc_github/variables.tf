variable "github_org" {
  description = "GitHub username or organization"
  type        = string
}

variable "github_repo" {
  description = "Repository name"
  type        = string
}

variable "state_bucket" {
  description = "Terraform state bucket name"
  type        = string
}

variable "lock_table" {
  description = "Terraform state lock table name"
  type        = string
}

variable "aws_region" {
  description = "AWS region for regional ARNs"
  type        = string
}
