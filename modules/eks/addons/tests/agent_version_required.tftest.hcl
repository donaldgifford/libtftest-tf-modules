# Variable validation negative — empty string for the agent's version
# variable is the "tried to pin and forgot the value" mistake. Null is
# permitted (data source resolves); "" is rejected.

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
  tags = {
    Account     = "000000000000"
    ClusterName = "libtftest-cluster"
    ClusterType = "secure"
    Environment = "test"
    Region      = "us-east-1"
  }
}

run "empty_string_rejected" {
  command = plan

  variables {
    pod_identity_agent_version = ""
  }

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

  expect_failures = [var.pod_identity_agent_version]
}
