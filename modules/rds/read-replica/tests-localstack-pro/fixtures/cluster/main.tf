# Q4-b cluster fixture for the read-replica Pro apply suite (IMPL-0013
# Phase 6). Instantiates the ACTUAL modules/rds/cluster module (highest
# fidelity — the reader-consumed output shape is exactly what the cluster
# emits, no hand-maintained stub to drift) and writes its outputs to S3
# as the stub cluster state the readers then read via
# data.terraform_remote_state.rds_cluster (override_data cannot reference
# a prior apply's outputs, so the S3 round-trip is the bridge — the proxy
# fixtures/db pattern).
#
# Three-level state dependency: the cluster module itself reads a VPC
# remote state, so this fixture first builds a VPC + stub VPC state, then
# instantiates the cluster module with depends_on = [the VPC state
# object] so the cluster's data.terraform_remote_state.vpc read is
# deferred to apply (after the VPC state exists), then writes the cluster
# stub state for the readers.

terraform {
  required_version = ">= 1.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}

variable "region" {
  description = "AWS region (for AZ composition + the remote-state keys)."
  type        = string
}

variable "remote_state_bucket" {
  description = "S3 bucket holding both the stub VPC state (for the cluster module) and the stub cluster state (for the readers)."
  type        = string
}

variable "vpc_name" {
  description = "VPC name used to compose the cluster module's VPC remote-state key."
  type        = string
}

variable "cluster_identifier" {
  description = "Identifier for the cluster module (its identifier_prefix); also the read-replica's cluster_identifier and the cluster state-key segment."
  type        = string
}

#--------------------------------------------------------------
# VPC + private subnets + S3 bucket + stub VPC state
# (the cluster module reads vpc_id + private_subnet_ids from
# <region>/vpc/<vpc_name>/terraform.tfstate).
#--------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
  tags       = { Name = var.vpc_name }
}

resource "aws_subnet" "private" {
  count             = 3
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = "${var.region}${["a", "b", "c"][count.index]}"
  tags = {
    Name = "${var.vpc_name}-private-${count.index}"
    Tier = "private"
  }
}

resource "aws_s3_bucket" "state" {
  bucket        = var.remote_state_bucket
  force_destroy = true
}

resource "aws_s3_object" "vpc_state" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-rr-stub-vpc"
    outputs = {
      vpc_id = {
        value = aws_vpc.this.id
        type  = "string"
      }
      private_subnet_ids = {
        value = aws_subnet.private[*].id
        type  = ["list", "string"]
      }
    }
    resources = []
  })
}

#--------------------------------------------------------------
# The real cluster module. depends_on the VPC state object so its
# data.terraform_remote_state.vpc read is deferred to apply, after the
# VPC state exists.
#--------------------------------------------------------------

module "cluster" {
  source = "../../../../cluster"

  region              = var.region
  remote_state_bucket = var.remote_state_bucket
  vpc_name            = var.vpc_name
  identifier_prefix   = var.cluster_identifier

  engine         = "aurora-postgresql"
  engine_version = "16"
  instance_class = "db.t3.medium"

  skip_final_snapshot = true

  depends_on = [aws_s3_object.vpc_state]
}

#--------------------------------------------------------------
# Stub cluster state at the read-replica's key
# (<region>/rds/cluster/<cluster_identifier>/terraform.tfstate). The
# outputs map is exactly the read-replica consumer set the cluster
# module emits (Q4-b — no drift).
#--------------------------------------------------------------

resource "aws_s3_object" "cluster_state" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.region}/rds/cluster/${var.cluster_identifier}/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-rr-stub-cluster"
    outputs = {
      cluster_identifier = {
        value = module.cluster.cluster_identifier
        type  = "string"
      }
      engine = {
        value = module.cluster.engine
        type  = "string"
      }
      engine_version_actual = {
        value = module.cluster.engine_version_actual
        type  = "string"
      }
      db_subnet_group_name = {
        value = module.cluster.db_subnet_group_name
        type  = "string"
      }
      db_parameter_group_name = {
        value = module.cluster.db_parameter_group_name
        type  = "string"
      }
    }
    resources = []
  })
}

output "cluster_identifier" {
  value = module.cluster.cluster_identifier
}

output "remote_state_key" {
  value = aws_s3_object.cluster_state.key
}
