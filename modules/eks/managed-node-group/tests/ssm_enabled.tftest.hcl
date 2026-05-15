# SSM opt-in (ADR-0012). enable_ssm = true adds the third managed-policy
# attachment AmazonSSMManagedInstanceCore.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  remote_state_bucket = "stub-bucket"
  region              = "us-east-1"
  cluster_name        = "libtftest-cluster"
  vpc_name            = "libtftest-vpc"
  nodegroup_name      = "libtftest-ng"
  enable_ssm          = true
}

run "ssm_enabled" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name              = "libtftest-cluster"
        cluster_version           = "1.31"
        cluster_endpoint          = "https://stub.eks.us-east-1.amazonaws.com"
        cluster_ca_data           = "Y2EtZGF0YQ=="
        cluster_oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/stub"
        cluster_security_group_id = "sg-cluster-stub"
        node_security_group_id    = "sg-node-stub"
        kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/stub-key"
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-stub"
        private_subnet_ids = ["subnet-a", "subnet-b"]
        public_subnet_ids  = ["subnet-pub-a", "subnet-pub-b"]
      }
    }
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.ssm) == 1
    error_message = "AmazonSSMManagedInstanceCore must be attached when var.enable_ssm = true"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.ssm[0].policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "SSM attachment must reference the AmazonSSMManagedInstanceCore AWS-managed policy"
  }
}
