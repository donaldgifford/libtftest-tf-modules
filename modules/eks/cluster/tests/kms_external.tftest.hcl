# External KMS key path: when var.kms_key_arn is non-null, the module
# must skip aws_kms_key.cluster + aws_kms_alias.cluster and use the
# provided ARN in encryption_config.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name                = "libtftest-ext"
  region              = "us-east-1"
  remote_state_bucket = "stub-bucket"
  vpc_name            = "stub-vpc"
  sso_cluster_policy  = "AmazonEKSViewPolicy"
  kms_key_arn         = "arn:aws:kms:us-east-1:000000000000:key/external-test-key"
  tags = {
    Account     = "libtftest"
    ClusterName = "libtftest-ext"
    ClusterType = "eks"
    Environment = "test"
    Region      = "us-east-1"
  }
}

run "external_kms_plan" {
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

  # Bring-your-own KMS: module must not create its own key/alias.
  assert {
    condition     = length(aws_kms_key.cluster) == 0
    error_message = "aws_kms_key.cluster must not be created when var.kms_key_arn is set"
  }
  assert {
    condition     = length(aws_kms_alias.cluster) == 0
    error_message = "aws_kms_alias.cluster must not be created when var.kms_key_arn is set"
  }

  # And the cluster's envelope-encryption key_arn points at the external ARN.
  assert {
    condition     = aws_eks_cluster.this.encryption_config[0].provider[0].key_arn == var.kms_key_arn
    error_message = "encryption_config provider key_arn must reference the external kms_key_arn input"
  }
}
