variable "aws_region" {
  description = "Primary region for the lab"
  type        = string
  default     = "us-east-1"
}

variable "github_org" {
  description = "GitHub username"
  type        = string
  default     = "Rjnoord"
}

variable "github_repo" {
  description = "Repository name"
  type        = string
  default     = "finops-dashboard"
}

variable "state_bucket" {
  description = "Terraform state bucket (from bootstrap)"
  type        = string
  default     = "rjnoord-finops-tfstate"
}

variable "lock_table" {
  description = "Terraform lock table (from bootstrap)"
  type        = string
  default     = "finops-tf-lock"
}

variable "alert_email" {
  description = "Email for billing alerts"
  type        = string
  # no default on purpose - set in terraform.tfvars (gitignored)
}
