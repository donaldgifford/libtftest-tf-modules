# Access-logs sink fixture for the bucket Community apply suite
# (IMPL-0018 3.4). Stands up the fleet state bucket, instantiates the
# **real** access-logs-bucket module (not a stub — the composing-fixture
# precedent from rds/proxy's fixtures/db), and writes its contract
# output to the reserved ADR-0020 key so the bucket module's
# data.terraform_remote_state.access_logs reads it for real.
# override_data cannot reference prior-run outputs, so this object IS
# the bridge — and it exercises the account-scoped key + assume_role
# read mechanics end to end (IMPL-0015).
#
# No VPC here: unlike the RDS fixtures this suite needs only S3, so it
# creates the state bucket directly rather than sourcing the shared
# reference-vpc fixture (which would pull in EC2 + a ~1-2 min NAT).

terraform {
  required_version = ">= 1.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}

variable "account_name" {
  description = "Terragrunt account name — the <account_name> prefix of the reserved sink state key."
  type        = string
}

variable "account_id" {
  description = "AWS account ID — composed into the sink's bucket name."
  type        = string
}

variable "region" {
  description = "AWS region — composed into the sink's bucket name and the state key."
  type        = string
}

variable "remote_state_bucket" {
  description = "Name of the fleet state bucket this fixture creates and seeds."
  type        = string
}

resource "aws_s3_bucket" "state" {
  bucket        = var.remote_state_bucket
  force_destroy = true
}

# The real sink module — the consumer reads what this actually produces.
module "access_logs" {
  source = "../../../../access-logs-bucket"

  account_id = var.account_id
  region     = var.region

  # Fixture teardown: the sink may hold delivered log objects.
  force_destroy = true
}

resource "aws_s3_object" "sink_state" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.account_name}/${var.region}/s3/access-logs/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-s3-access-logs-sink"
    outputs = {
      bucket_name = {
        value = module.access_logs.bucket_name
        type  = "string"
      }
      bucket_arn = {
        value = module.access_logs.bucket_arn
        type  = "string"
      }
    }
    resources = []
  })
}

output "sink_bucket_name" {
  description = "The real sink's composed bucket name — what the consumer must resolve through the remote-state read."
  value       = module.access_logs.bucket_name
}

output "remote_state_key" {
  description = "The reserved ADR-0020 key this fixture seeded."
  value       = aws_s3_object.sink_state.key
}
