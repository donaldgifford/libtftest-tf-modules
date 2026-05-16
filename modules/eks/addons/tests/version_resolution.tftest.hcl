# Version resolution via coalesce(var.<name>_version, data.<>.version) per
# IMPL-0003 Q3. A literal pin short-circuits the data source; a null var
# routes to the AWS-idiomatic most_recent = true pick.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  remote_state_bucket        = "stub-bucket"
  region                     = "us-east-1"
  cluster_name               = "libtftest-cluster"
  pod_identity_agent_version = "v1.3.0-eksbuild.1"
  tags = {
    Account     = "000000000000"
    ClusterName = "libtftest-cluster"
    ClusterType = "secure"
    Environment = "test"
    Region      = "us-east-1"
  }
}

run "vpc_cni_version_pinned" {
  command = plan

  variables {
    vpc_cni_version = "v1.18.0-eksbuild.1"
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

  # vpc_cni data source returns a DIFFERENT version to prove the literal
  # pin wins over the data source.
  override_data {
    target = data.aws_eks_addon_version.vpc_cni
    values = {
      version = "v9.9.9-DATA-SOURCE-WINS"
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
    condition     = aws_eks_addon.vpc_cni.addon_version == "v1.18.0-eksbuild.1"
    error_message = "Pinned var.vpc_cni_version must short-circuit the data source"
  }
}

run "vpc_cni_version_resolved_from_data_source" {
  command = plan

  # vpc_cni_version intentionally omitted — defaults to null → data source.

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
    condition     = aws_eks_addon.vpc_cni.addon_version == "v1.18.0-eksbuild.1"
    error_message = "Null var.vpc_cni_version must resolve via data.aws_eks_addon_version.vpc_cni.version"
  }
}
