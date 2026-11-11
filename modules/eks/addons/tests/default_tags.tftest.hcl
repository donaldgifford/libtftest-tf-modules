# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches the addons and their IAM role.

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
  remote_state_bucket        = "stub-bucket"
  region                     = "us-east-1"
  cluster_name               = "libtftest-cluster"
  pod_identity_agent_version = "v1.3.0-eksbuild.1"
}

run "default_tags_reach_resources" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name    = "libtftest-cluster"
        cluster_version = "1.31"
      }
    }
  }

  override_data {
    target = data.aws_eks_addon_version.pod_identity_agent
    values = {
      version = "v1.3.0-eksbuild.1"
    }
  }

  override_data {
    target = data.aws_eks_addon_version.vpc_cni
    values = {
      version = "v1.18.0-eksbuild.1"
    }
  }

  override_data {
    target = data.aws_eks_addon_version.kube_proxy
    values = {
      version = "v1.31.0-eksbuild.2"
    }
  }

  override_data {
    target = data.aws_eks_addon_version.coredns
    values = {
      version = "v1.11.3-eksbuild.1"
    }
  }

  override_data {
    target = data.aws_eks_addon_version.ebs_csi
    values = {
      version = "v1.35.0-eksbuild.1"
    }
  }

  assert {
    condition     = aws_eks_addon.pod_identity_agent.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the pod-identity-agent addon (tags_all)"
  }

  assert {
    condition     = aws_iam_role.ebs_csi.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the EBS CSI IAM role (tags_all)"
  }
}
