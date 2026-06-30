# Minimal Aurora target fixture for the proxy Pro apply suite
# (IMPL-0010 Phase 10). Stands up just enough of a data tier for an
# RDS Proxy to attach to — a VPC + two subnets + SG + subnet group + an
# Aurora Serverless v2 cluster with an AWS-managed master secret — then
# writes a stub remote-state file to S3 at the proxy's expected key so
# the proxy's data.terraform_remote_state.target reads it for real
# (the same pattern the serverless apply suite uses; override_data
# cannot reference prior-run outputs, so this is the bridge).

terraform {
  required_version = ">= 1.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}

variable "identifier" {
  description = "Cluster identifier for the fixture (also the proxy's target_identifier)."
  type        = string
}

variable "region" {
  description = "AWS region (for AZ composition + the remote-state key)."
  type        = string
}

variable "remote_state_bucket" {
  description = "S3 bucket the proxy reads the target's stub state from."
  type        = string
}

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
  tags       = { Name = var.identifier }
}

resource "aws_subnet" "this" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(aws_vpc.this.cidr_block, 8, count.index)
  availability_zone = "${var.region}${count.index == 0 ? "a" : "b"}"
  tags              = { Name = "${var.identifier}-${count.index}" }
}

resource "aws_security_group" "this" {
  name   = "${var.identifier}-db"
  vpc_id = aws_vpc.this.id
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.identifier}-db"
  subnet_ids = aws_subnet.this[*].id
}

resource "aws_rds_cluster" "this" {
  cluster_identifier          = var.identifier
  engine                      = "aurora-postgresql"
  engine_mode                 = "provisioned"
  manage_master_user_password = true
  master_username             = "admin"
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.this.id]
  skip_final_snapshot         = true

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 1
  }
}

resource "aws_rds_cluster_instance" "this" {
  identifier         = "${var.identifier}-1"
  cluster_identifier = aws_rds_cluster.this.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.this.engine
}

#--------------------------------------------------------------
# S3 bucket + stub target state at the proxy's key
# (<region>/rds/serverless/<identifier>/terraform.tfstate). The
# outputs map mirrors the serverless module's proxy-composition
# outputs (IMPL-0010 Phase 2).
#--------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket        = var.remote_state_bucket
  force_destroy = true
}

resource "aws_s3_object" "target_state" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.region}/rds/serverless/${var.identifier}/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-proxy-stub-db"
    outputs = {
      master_user_secret_arn = {
        value = try(aws_rds_cluster.this.master_user_secret[0].secret_arn, null)
        type  = "string"
      }
      master_user_secret_kms_key_arn = {
        value = try(aws_rds_cluster.this.master_user_secret[0].kms_key_id, null)
        type  = "string"
      }
      security_group_id = {
        value = aws_security_group.this.id
        type  = "string"
      }
      db_subnet_ids = {
        value = aws_subnet.this[*].id
        type  = ["list", "string"]
      }
      vpc_id = {
        value = aws_vpc.this.id
        type  = "string"
      }
      engine = {
        value = aws_rds_cluster.this.engine
        type  = "string"
      }
      iam_database_authentication_enabled = {
        value = aws_rds_cluster.this.iam_database_authentication_enabled
        type  = "bool"
      }
    }
    resources = []
  })
}

output "cluster_identifier" {
  value = aws_rds_cluster.this.id
}

output "remote_state_key" {
  value = aws_s3_object.target_state.key
}
