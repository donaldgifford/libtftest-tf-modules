# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches the filesystem and its security group.

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
  region              = "us-east-1"
  remote_state_bucket = "stub-bucket"
  vpc_name            = "libtftest-vpc"
  cluster_name        = "libtftest-eks"
  identifier_prefix   = "platform-efs"
  kms_key_arn         = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "default_tags_reach_resources" {
  command = plan

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-0123456789abcdef0"
        private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        node_security_group_id = "sg-node1234567890"
      }
    }
  }

  assert {
    condition     = aws_efs_file_system.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the filesystem (tags_all)"
  }

  assert {
    condition     = aws_security_group.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the mount-target security group (tags_all)"
  }
}

run "access_point_name_wins_over_default_tags" {
  command   = plan
  providers = { aws = aws.collision }

  variables {
    access_points = {
      grafana = {
        posix_user     = { uid = 472, gid = 472 }
        root_directory = { path = "/grafana" }
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id             = "vpc-0123456789abcdef0"
        private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      }
    }
  }

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        node_security_group_id = "sg-node1234567890"
      }
    }
  }

  # Resource tags beat provider default_tags on a key collision.
  assert {
    condition     = aws_efs_access_point.this["grafana"].tags_all["Name"] == "grafana"
    error_message = "the access point's module-set Name (the map key) must win over a provider default_tags Name"
  }
}
