# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches an access entry.

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
  remote_state_bucket = "stub-bucket"
  region              = "us-east-1"
  cluster_name        = "libtftest-cluster"
}

run "default_tags_reach_access_entries" {
  command = plan

  variables {
    access_entries = {
      deploy_role = {
        principal_arn = "arn:aws:iam::000000000000:role/deploy-role"
        policy_associations = {
          admin = {
            policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          }
        }
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name              = "libtftest-cluster"
        cluster_version           = "1.31"
        cluster_endpoint          = "https://stub.eks.us-east-1.amazonaws.com"
        cluster_ca_data           = "Y2EtZGF0YQ==" # base64("ca-data")
        cluster_oidc_issuer_url   = "https://oidc.eks.us-east-1.amazonaws.com/id/stub"
        cluster_security_group_id = "sg-cluster-stub"
        node_security_group_id    = "sg-node-stub"
        kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/stub-key"
        sso_principal_arn         = "arn:aws:iam::000000000000:role/AWSReservedSSO_Admin_abcdef1234567890"
      }
    }
  }

  assert {
    condition     = aws_eks_access_entry.this["deploy_role"].tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the access entry (tags_all)"
  }
}
