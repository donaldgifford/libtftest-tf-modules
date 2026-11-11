# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches the Mode A role, and that association_tags merge on top of it at the association.

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
  namespace           = "kube-system"
  service_account     = "cluster-autoscaler"
  managed_policy_arns = ["arn:aws:iam::aws:policy/AutoScalingFullAccess"]
  association_tags = {
    Component = "cluster-autoscaler"
  }
}

run "default_tags_reach_resources" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "libtftest-cluster"
      }
    }
  }

  assert {
    condition     = aws_iam_role.this[0].tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the Mode A role (tags_all)"
  }

  assert {
    condition     = aws_eks_pod_identity_association.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the association (tags_all)"
  }

  assert {
    condition     = aws_eks_pod_identity_association.this.tags_all["Component"] == "cluster-autoscaler"
    error_message = "association_tags must still merge on top of the provider default_tags (DESIGN-0029 OQ 4a)"
  }
}
