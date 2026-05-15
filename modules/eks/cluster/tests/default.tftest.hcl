# Default-config plan-time invariants per RFC-0001 / ADR-0013.
# Side-by-side reference for the libtftest suite under ../test/.
#
# Stubs (override_data):
#   - data.aws_caller_identity.current → fake account for the KMS
#     resource policy principal.
#   - data.terraform_remote_state.vpc  → stub VPC outputs so the
#     module's vpc_config and node SG resolve without LocalStack S3.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name                = "libtftest"
  region              = "us-east-1"
  remote_state_bucket = "stub-bucket"
  vpc_name            = "stub-vpc"
  sso_cluster_policy  = "AmazonEKSViewPolicy"
  tags = {
    Account     = "libtftest"
    ClusterName = "libtftest"
    ClusterType = "eks"
    Environment = "test"
    Region      = "us-east-1"
  }
}

run "default_plan" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "000000000000"
      arn        = "arn:aws:iam::000000000000:user/test"
      user_id    = "test"
    }
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-libtftest"
        private_subnet_ids = ["subnet-private-libtftest-a", "subnet-private-libtftest-b"]
        public_subnet_ids  = ["subnet-public-libtftest-a", "subnet-public-libtftest-b"]
      }
    }
  }

  # ADR-0003: cluster module installs no managed addons. Asserting absence
  # by name — terraform test cannot directly count resources by type from
  # within an assert, so we rely on the module not declaring any.

  # Exactly one IAM role in this module (cluster service role).
  # Workload IAM moved to DESIGN-0004 (pod-identity-access).
  assert {
    condition     = aws_iam_role.cluster.name == "${var.name}-cluster"
    error_message = "cluster service role name should be \"${var.name}-cluster\""
  }

  # KMS envelope encryption — secrets resource included.
  # encryption_config[].resources is a set, not a list — use contains()
  # rather than indexing. (Real ergonomics data point for RFC-0001: libtftest's
  # plan-JSON walk treats it as a list since terraform serializes sets that
  # way for the JSON plan; HCL assert sees the typed set and requires set ops.)
  assert {
    condition     = contains(aws_eks_cluster.this.encryption_config[0].resources, "secrets")
    error_message = "envelope encryption resources must include \"secrets\""
  }

  # Endpoint defaults — public=true and private=true per Resolved Q11.
  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_public_access == true
    error_message = "endpoint_public_access default must be true"
  }
  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access == true
    error_message = "endpoint_private_access default must be true"
  }

  # Authentication mode.
  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API_AND_CONFIG_MAP"
    error_message = "authentication_mode must be API_AND_CONFIG_MAP"
  }

  # CloudWatch log retention.
  assert {
    condition     = aws_cloudwatch_log_group.cluster.retention_in_days == 30
    error_message = "log retention default must be 30 days"
  }

  # KMS rotation + 30-day deletion window when module manages the key.
  assert {
    condition     = aws_kms_key.cluster[0].enable_key_rotation == true
    error_message = "module-managed KMS key must have rotation enabled"
  }
  assert {
    condition     = aws_kms_key.cluster[0].deletion_window_in_days == 30
    error_message = "module-managed KMS deletion window default must be 30 days"
  }

  # Module-managed KMS path: exactly one key + one alias when kms_key_arn is null.
  assert {
    condition     = length(aws_kms_key.cluster) == 1
    error_message = "default config must create exactly one module-managed KMS key"
  }
  assert {
    condition     = length(aws_kms_alias.cluster) == 1
    error_message = "default config must create exactly one module-managed KMS alias"
  }

  # Node SG vpc_id resolves from the (stubbed) VPC remote state.
  assert {
    condition     = aws_security_group.nodes.vpc_id == "vpc-libtftest"
    error_message = "aws_security_group.nodes.vpc_id must come from data.terraform_remote_state.vpc.outputs.vpc_id"
  }

  # SSO Access Entry not created by default.
  assert {
    condition     = length(aws_eks_access_entry.sso) == 0
    error_message = "SSO access entry must not be created when sso_access_enabled is false"
  }
  assert {
    condition     = length(aws_eks_access_policy_association.sso) == 0
    error_message = "SSO access policy association must not be created when sso_access_enabled is false"
  }

  # Subnets passed to the cluster come from the stubbed remote state.
  assert {
    condition     = length(aws_eks_cluster.this.vpc_config[0].subnet_ids) == 2
    error_message = "cluster vpc_config.subnet_ids must come from stubbed private_subnet_ids (length 2)"
  }
}
