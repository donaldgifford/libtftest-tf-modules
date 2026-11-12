# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches the node group, its IAM role, the launch template itself, and (via data.aws_default_tags) both tag_specifications.

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

# A second provider whose default_tags also set a key the module owns.
# Runs that select it prove the module's value wins the collision.
provider "aws" {
  alias                       = "collision"
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  default_tags {
    tags = { DefaultTagProbe = "design-0029", Name = "from-default-tags" }
  }
}

variables {
  remote_state_bucket = "stub-bucket"
  region              = "us-east-1"
  cluster_name        = "libtftest-cluster"
  vpc_name            = "libtftest-vpc"
  nodegroup_name      = "libtftest-ng"
}

run "default_tags_reach_resources" {
  command = plan

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
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-stub"
        private_subnet_ids = ["subnet-private-a", "subnet-private-b"]
        public_subnet_ids  = ["subnet-public-a", "subnet-public-b"]
      }
    }
  }

  assert {
    condition     = aws_eks_node_group.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the node group (tags_all)"
  }

  assert {
    condition     = aws_iam_role.node.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the node IAM role (tags_all)"
  }

  assert {
    condition     = aws_launch_template.node.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the launch template itself (tags_all)"
  }

  # The site default_tags cannot reach on its own: these are read back via
  # data.aws_default_tags and merged, so EC2 tags the launched instances
  # and root volumes with the standard set.
  assert {
    condition     = aws_launch_template.node.tag_specifications[0].tags["DefaultTagProbe"] == "design-0029" && aws_launch_template.node.tag_specifications[1].tags["DefaultTagProbe"] == "design-0029"
    error_message = "the instance and volume tag_specifications must carry the provider default_tags via data.aws_default_tags"
  }
}

run "tag_specification_name_wins_over_default_tags" {
  command   = plan
  providers = { aws = aws.collision }

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
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-stub"
        private_subnet_ids = ["subnet-private-a", "subnet-private-b"]
        public_subnet_ids  = ["subnet-public-a", "subnet-public-b"]
      }
    }
  }

  # tag_specifications get the defaults via data.aws_default_tags and
  # merge(defaults, { Name }): the module's Name must come last and win.
  assert {
    condition     = aws_launch_template.node.tag_specifications[0].tags["Name"] == "libtftest-ng"
    error_message = "the instance tag_specification's module-set Name must win over a provider default_tags Name"
  }

  assert {
    condition     = aws_launch_template.node.tag_specifications[1].tags["Name"] == "libtftest-ng-root"
    error_message = "the volume tag_specification's module-set Name must win over a provider default_tags Name"
  }
}
