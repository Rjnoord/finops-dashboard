# Bootstrap: creates the S3 bucket + DynamoDB table that hold Terraform state.
# Run ONCE with local state, before anything else:
#   cd terraform/bootstrap && terraform init && terraform apply
# The bucket name must be globally unique — override via -var if taken.

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket_name" {
  type    = string
  default = "rjnoord-finops-tfstate"
}

resource "aws_s3_bucket" "tfstate" {
  #checkov:skip=CKV_AWS_18:Single-account personal lab bucket; access logging cost/noise isn't justified here
  #checkov:skip=CKV_AWS_144:Personal lab, single region; cross-region replication is disproportionate cost for tfstate
  #checkov:skip=CKV2_AWS_62:Personal lab bucket with no downstream consumers for event notifications
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Project   = "finops-dashboard"
    ManagedBy = "terraform-bootstrap"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  #checkov:skip=CKV_AWS_119:AWS-owned encryption key is sufficient for a lock table with no sensitive data; CMK adds cost with no benefit here
  name         = "finops-tf-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  point_in_time_recovery {
    enabled = true
  }

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Project   = "finops-dashboard"
    ManagedBy = "terraform-bootstrap"
  }
}

output "state_bucket" {
  value = aws_s3_bucket.tfstate.id
}

output "lock_table" {
  value = aws_dynamodb_table.tflock.name
}
