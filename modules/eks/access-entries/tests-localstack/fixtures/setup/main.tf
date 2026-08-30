# Setup fixture for terraform test `apply_localstack.tftest.hcl`.
#
# The bespoke addons-style fixture (IMPL-0020 OQ 3a) rather than
# composing the real eks/cluster module: fast, and it can cheaply seed
# a SECOND, deliberately stale state so the collision guard's degrade
# path is exercised live rather than only at plan.
#
# Builds:
#   1. VPC + 2 private subnets (aws_eks_cluster requires >= 2 AZs).
#   2. Cluster IAM role + AmazonEKSClusterPolicy attachment.
#   3. A real aws_eks_cluster (LocalStack Pro accepts this — verified
#      by the addons / managed-node-group / pod-identity-access
#      fixtures).
#   4. Two IAM roles to bind as access-entry principals, plus one
#      standing in for the cluster stack's SSO principal.
#   5. S3 bucket with TWO stub state objects:
#      - the current key, carrying sso_principal_arn (guard armed);
#      - a "stale" key with no sso_principal_arn, reproducing a
#        cluster stack that has not re-applied since DESIGN-0024.

terraform {
  required_version = ">= 1.1"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}

variable "remote_state_bucket" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "stale_cluster_name" {
  description = "Second state key whose stub omits sso_principal_arn, so the apply suite can exercise the guard's null-safe degrade path against a real read."
  type        = string
}

variable "region" {
  type = string
}

variable "account_name" {
  description = "Terragrunt account name — the <account_name> prefix of the account-scoped eks state key the module reads (IMPL-0015)."
  type        = string
}

#--------------------------------------------------------------
# VPC + subnets
#--------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "tftest-ae-fixture-vpc"
  }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = "${var.region}${["a", "b"][count.index]}"
  tags = {
    Name = "tftest-ae-fixture-private-${count.index}"
    Tier = "private"
  }
}

#--------------------------------------------------------------
# EKS cluster
#--------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  vpc_config {
    subnet_ids = aws_subnet.private[*].id
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

#--------------------------------------------------------------
# Principals to bind
#--------------------------------------------------------------
#
# Trust policies are irrelevant to access entries (EKS binds the ARN,
# it does not assume the role) — these exist so the entries name real
# principals.

data "aws_iam_policy_document" "assume_by_account" {
  statement {
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::000000000000:root"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "deployer" {
  name               = "${var.cluster_name}-platform-access"
  assume_role_policy = data.aws_iam_policy_document.assume_by_account.json
}

resource "aws_iam_role" "break_glass" {
  name               = "${var.cluster_name}-break-glass"
  assume_role_policy = data.aws_iam_policy_document.assume_by_account.json
}

# Stands in for the principal the cluster stack's SSO entry owns. The
# apply suite points an entry at this to prove the guard rejects it.
#
# Deliberately given a PATH, so the role has the two legitimate ARN
# spellings the guard must reconcile: the path-bearing one IAM returns
# (seeded into the stub state, as data.aws_iam_roles would) and the
# path-stripped one access-entry configs conventionally use. Without a
# path both spellings collapse to one string and the live tier would
# only prove the trivial case.
#
# A neutral path stands in for the real reserved-SSO one
# (/aws-reserved/sso.amazonaws.com/<region>/). Not because that path is
# unusable — eks/cluster's Go suite seeds a role under it directly
# (test/sso_test.go, seedSSORole) — but because whether real IAM permits
# CreateRole there is a question this fixture has no reason to depend
# on. The guard's normalization keeps only the account and the trailing
# name, so any path proves the same thing.
resource "aws_iam_role" "sso_owned" {
  name               = "AWSReservedSSO_${var.cluster_name}_abcdef1234567890"
  path               = "/sso-emulated/"
  assume_role_policy = data.aws_iam_policy_document.assume_by_account.json
}

#--------------------------------------------------------------
# S3 bucket + the two stub EKS states
#--------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket        = var.remote_state_bucket
  force_destroy = true
}

# Current shape: carries sso_principal_arn, so the guard is armed.
resource "aws_s3_object" "eks_state" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.account_name}/${var.region}/eks/${var.cluster_name}/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-ae-fixture-stub-eks"
    outputs = {
      cluster_name = {
        value = aws_eks_cluster.this.name
        type  = "string"
      }
      sso_principal_arn = {
        value = aws_iam_role.sso_owned.arn
        type  = "string"
      }
    }
    resources = []
  })
}

# Pre-DESIGN-0024 shape: no sso_principal_arn key at all. Points at the
# same real cluster so entries still apply — only the guard degrades.
resource "aws_s3_object" "eks_state_stale" {
  bucket       = aws_s3_bucket.state.id
  key          = "${var.account_name}/${var.region}/eks/${var.stale_cluster_name}/terraform.tfstate"
  content_type = "application/json"

  content = jsonencode({
    version           = 4
    terraform_version = "1.14.7"
    serial            = 1
    lineage           = "tftest-ae-fixture-stub-eks-stale"
    outputs = {
      cluster_name = {
        value = aws_eks_cluster.this.name
        type  = "string"
      }
    }
    resources = []
  })
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "deployer_role_arn" {
  value = aws_iam_role.deployer.arn
}

output "break_glass_role_arn" {
  value = aws_iam_role.break_glass.arn
}

# The path-bearing spelling — what IAM returns, and what the stub state
# above carries as sso_principal_arn.
output "sso_owned_role_arn" {
  value = aws_iam_role.sso_owned.arn
}

# The same role, path stripped: the spelling an operator would paste
# into an access_entries map. Two strings, one principal — the guard
# must still reject it.
output "sso_owned_role_arn_path_stripped" {
  value = replace(
    aws_iam_role.sso_owned.arn,
    ":role${aws_iam_role.sso_owned.path}",
    ":role/",
  )
}
