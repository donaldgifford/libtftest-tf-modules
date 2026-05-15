# SSO Access Entry gating: count 0 when disabled, count 1 when enabled.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  name                = "libtftest-sso"
  region              = "us-east-1"
  remote_state_bucket = "stub-bucket"
  vpc_name            = "stub-vpc"
  sso_cluster_policy  = "AmazonEKSViewPolicy"
  tags = {
    Account     = "libtftest"
    ClusterName = "libtftest-sso"
    ClusterType = "eks"
    Environment = "test"
    Region      = "us-east-1"
  }
}

run "sso_disabled" {
  command = plan

  variables {
    sso_access_enabled = false
  }

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

  assert {
    condition     = length(aws_eks_access_entry.sso) == 0
    error_message = "SSO access entry count must be 0 when sso_access_enabled is false"
  }
  assert {
    condition     = length(aws_eks_access_policy_association.sso) == 0
    error_message = "SSO access policy association count must be 0 when sso_access_enabled is false"
  }
}

run "sso_enabled" {
  command = plan

  variables {
    sso_access_enabled = true
    sso_role_name      = "Developer"
  }

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

  # The SSO data lookup. Stubbed to a known role ARN matching the
  # AWSReservedSSO_<permset>_<suffix> pattern the module's name_regex expects.
  override_data {
    target = data.aws_iam_roles.sso[0]
    values = {
      arns = ["arn:aws:iam::000000000000:role/AWSReservedSSO_Developer_abcdef1234567890"]
    }
  }

  assert {
    condition     = length(aws_eks_access_entry.sso) == 1
    error_message = "SSO access entry count must be 1 when sso_access_enabled is true"
  }
  assert {
    condition     = length(aws_eks_access_policy_association.sso) == 1
    error_message = "SSO access policy association count must be 1 when sso_access_enabled is true"
  }
  assert {
    condition     = aws_eks_access_entry.sso[0].principal_arn == "arn:aws:iam::000000000000:role/AWSReservedSSO_Developer_abcdef1234567890"
    error_message = "SSO access entry principal_arn must resolve from data.aws_iam_roles.sso[0].arns"
  }
  assert {
    condition     = aws_eks_access_policy_association.sso[0].policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
    error_message = "SSO access policy association policy_arn must reference var.sso_cluster_policy"
  }
}
