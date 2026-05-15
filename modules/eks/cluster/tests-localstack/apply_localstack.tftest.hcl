# Apply against LocalStack — the gap-discovery mode per RFC-0001.
#
# This file exercises `command = apply` against LocalStack Pro to surface,
# in concrete tftest.hcl failures, what LocalStack actually serves and
# where the framework's seams show. The plan-only files (default,
# kms_external, sso) handle structural assertions; this one handles the
# coverage question.
#
# Required env vars (the harness wiring terraform test needs to reach
# LocalStack — same shape libtftest's helpers_test.go wires in Go):
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1
#
# Documented gap-discovery findings so far (May 2026, against LocalStack
# Pro 2026.5.0):
#
#   FINDING #1: terraform test's `override_data` evaluates statically.
#   You cannot reference `run.*` outputs in override_data values, which
#   means cross-run dynamic stubbing of `data.terraform_remote_state`
#   isn't expressible. The workaround is to seed a real
#   terraform.tfstate object in LocalStack S3 from a setup fixture and
#   let the data source resolve naturally — the same seeding pattern
#   libtftest's helpers_test.go uses, just authored in HCL instead of
#   Go. Not a LocalStack gap; a terraform test ergonomics finding.
#
#   FINDING #2: `data.terraform_remote_state` with backend=s3 uses the
#   AWS SDK directly, independent of the AWS provider's `endpoints`
#   block. To redirect it at LocalStack, the developer must export
#   AWS_ENDPOINT_URL (universal) in the parent shell — `endpoints` in
#   `provider "aws"` only covers the aws provider's own calls.
#   This is the same gap libtftest hit and documented in
#   helpers_test.go. Filed as a documentation point in ADR-0014, not a
#   sneakystack ticket (LocalStack itself is fine; the issue is harness
#   plumbing).
#
#   No 501/NotImplemented errors hit so far against LocalStack Pro's
#   EKS / IAM / KMS / CloudWatch Logs / EC2 SG surface for this module.
#   When new modules surface them, they get filed as named sneakystack
#   tickets per RFC-0001 §`terraform test` as the gap-discovery tool.

# LocalStack provider — comprehensive endpoints block following LocalStack's
# documented pattern. Note s3 uses the s3.localhost.localstack.cloud DNS
# (resolves to 127.0.0.1, supports virtual-hosted style) so we don't need
# s3_use_path_style on the provider. The s3 backend of
# data.terraform_remote_state.vpc is independent of this provider block
# (uses its own AWS SDK) — that one still needs AWS_ENDPOINT_URL env var
# in the parent shell.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    cloudwatchlogs = "http://localhost:4566"
    ec2            = "http://localhost:4566"
    eks            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    kms            = "http://localhost:4566"
    s3             = "http://s3.localhost.localstack.cloud:4566"
    sts            = "http://localhost:4566"
  }
}

variables {
  name                = "tftest-apply"
  region              = "us-east-1"
  remote_state_bucket = "stub-bucket"
  vpc_name            = "stub-vpc"
  sso_cluster_policy  = "AmazonEKSViewPolicy"
  tags = {
    Account     = "libtftest"
    ClusterName = "tftest-apply"
    ClusterType = "eks"
    Environment = "test"
    Region      = "us-east-1"
  }
}

# Setup: create the LocalStack-side fixtures the cluster apply needs.
#
# RFC-0001 gap finding: terraform test's override_data block evaluates
# statically — values cannot reference run.* outputs. So we can't apply
# a VPC fixture first and override_data the stub remote state to point
# at its outputs. Instead the fixture module creates VPC + subnets AND
# writes a real terraform.tfstate object to a real LocalStack S3 bucket
# in one apply, so the cluster module's data.terraform_remote_state.vpc
# resolves naturally without any override_data.
#
# This is the same seeding pattern libtftest's helpers_test.go uses,
# re-implemented in HCL. Data point recorded inline.
run "setup" {
  command = apply

  variables {
    remote_state_bucket = var.remote_state_bucket
    vpc_name            = var.vpc_name
    region              = var.region
  }

  module {
    source = "./tests-localstack/fixtures/setup"
  }
}

# Default-config apply against LocalStack. Exercises IAM, KMS, CloudWatch
# Logs, EKS, EC2 SGs and rules. Any LocalStack coverage gap surfaces here
# as an apply error — file as a sneakystack ticket per RFC-0001.
run "default_apply" {
  command = apply

  # The cluster actually exists in LocalStack after this run.
  # Each assertion reads a real LocalStack-returned value.
  assert {
    condition     = aws_eks_cluster.this.name == "tftest-apply"
    error_message = "LocalStack EKS apply must return our cluster name"
  }
  assert {
    condition     = length(aws_eks_cluster.this.endpoint) > 0
    error_message = "LocalStack EKS apply must populate the cluster endpoint"
  }
  assert {
    condition     = length(aws_eks_cluster.this.certificate_authority[0].data) > 0
    error_message = "LocalStack EKS apply must populate certificate_authority.data"
  }
  assert {
    condition     = length(aws_eks_cluster.this.identity[0].oidc[0].issuer) > 0
    error_message = "LocalStack EKS apply must populate oidc.issuer URL"
  }
  assert {
    condition     = length(aws_eks_cluster.this.vpc_config[0].cluster_security_group_id) > 0
    error_message = "LocalStack EKS apply must populate cluster_security_group_id"
  }
  assert {
    condition     = length(aws_kms_key.cluster[0].arn) > 0
    error_message = "LocalStack KMS apply must populate the key ARN"
  }
  assert {
    condition     = length(aws_security_group.nodes.id) > 0
    error_message = "LocalStack EC2 SG apply must populate the SG ID"
  }
  assert {
    condition     = aws_cloudwatch_log_group.cluster.retention_in_days == 30
    error_message = "CloudWatch log group should retain the configured 30d retention"
  }
}
