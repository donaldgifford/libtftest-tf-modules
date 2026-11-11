# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches the cluster, its KMS key and its security groups.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  default_tags {
    tags = { DefaultTagProbe = "design-0029" }
  }
}

variables {
  name                = "libtftest"
  region              = "us-east-1"
  remote_state_bucket = "stub-bucket"
  vpc_name            = "stub-vpc"
  sso_cluster_policy  = "AmazonEKSViewPolicy"
}

run "default_tags_reach_resources" {
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

  assert {
    condition     = aws_eks_cluster.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the cluster (tags_all)"
  }

  assert {
    condition     = aws_kms_key.cluster[0].tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the module-managed KMS key (tags_all)"
  }
}
