# Wasteful-resource simulation — Phase 7.
#
# Deliberately creates the cheap waste patterns the collectors hunt, WITHOUT
# the required tags, so the platform has something real to find:
#   - an unattached EBS volume  (~$0.80/mo prorated — pennies for an hour)
#   - an unassociated Elastic IP (~$3.60/mo prorated)
#
# Local state, separate from the main pipeline, so teardown is one command:
#   terraform apply    # seed the waste
#   (invoke collectors, screenshot the dashboard, run the reporter)
#   terraform destroy  # clean up — do not leave this running
#
# An idle EC2 instance is opt-in (var.create_idle_instance) because the idle
# signal needs 7 days of CPU data — leave it running a week if you want the
# IDLE_EC2 finding on the dashboard, then destroy.

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
  region = "us-east-1"
  # No default_tags on purpose: these resources simulate the untagged sprawl
  # the tag-compliance collector exists to catch.
}

variable "create_idle_instance" {
  description = "Also launch a t3.micro to develop the 7-day idle-CPU signal"
  type        = bool
  default     = false
}

resource "aws_ebs_volume" "orphan" {
  #checkov:skip=CKV_AWS_189:Simulation resource, deliberately unencrypted-by-CMK and untagged
  #checkov:skip=CKV_AWS_3:Deliberately misconfigured — this volume exists to be flagged by the collectors and holds no data
  availability_zone = "us-east-1a"
  size              = 10
  type              = "gp3"
  # Untagged on purpose — should show up in the tag-compliance offenders too.
}

resource "aws_eip" "orphan" {
  #checkov:skip=CKV2_AWS_19:The unattached EIP IS the simulation — the orphaned_storage collector exists to catch exactly this
  domain = "vpc"
  # Allocated but never associated — pure waste the collector should price.
}

data "aws_ami" "al2023" {
  count       = var.create_idle_instance ? 1 : 0
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023*-arm64"]
  }
}

resource "aws_instance" "idle" {
  #checkov:skip=CKV_AWS_126:Simulation resource; detailed monitoring adds cost for a box meant to sit idle
  #checkov:skip=CKV_AWS_135:Simulation resource kept deliberately minimal
  #checkov:skip=CKV_AWS_8:Simulation resource kept deliberately minimal
  #checkov:skip=CKV_AWS_79:Simulation resource kept deliberately minimal
  #checkov:skip=CKV_AWS_49:Simulation resource kept deliberately minimal
  #checkov:skip=CKV2_AWS_41:Idle simulation box needs no instance profile — it does nothing by design
  count         = var.create_idle_instance ? 1 : 0
  ami           = data.aws_ami.al2023[0].id
  instance_type = "t3.micro"
}

output "seeded" {
  value = {
    volume     = aws_ebs_volume.orphan.id
    elastic_ip = aws_eip.orphan.allocation_id
    instance   = var.create_idle_instance ? aws_instance.idle[0].id : "not created"
  }
}
