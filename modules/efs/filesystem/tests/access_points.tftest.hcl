# Access-point map resolution.
#
# Empty map (covered in default.tftest.hcl) → 0 access points.
# Two-entry map → 2 access points; per-key Name tag + posix_user
# flowthrough.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  region              = "us-east-1"
  remote_state_bucket = "stub-bucket"
  vpc_name            = "libtftest-vpc"
  cluster_name        = "libtftest-eks"
  identifier_prefix   = "platform-efs"
  kms_key_arn         = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "two_access_points" {
  command = plan

  variables {
    access_points = {
      grafana = {
        posix_user = {
          uid = 472
          gid = 472
        }
        root_directory = {
          path = "/grafana"
          creation_info = {
            owner_uid   = 472
            owner_gid   = 472
            permissions = "0755"
          }
        }
      }
      prometheus = {
        posix_user = {
          uid            = 65534
          gid            = 65534
          secondary_gids = [10, 20]
        }
        root_directory = {
          path = "/prometheus"
        }
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

  assert {
    condition     = length(aws_efs_access_point.this) == 2
    error_message = "Two-entry access_points map must plan exactly two access points"
  }

  assert {
    condition     = aws_efs_access_point.this["grafana"].posix_user[0].uid == 472
    error_message = "grafana access point posix_user.uid must equal map-entry value 472"
  }

  assert {
    condition     = aws_efs_access_point.this["grafana"].posix_user[0].gid == 472
    error_message = "grafana access point posix_user.gid must equal map-entry value 472"
  }

  assert {
    condition     = aws_efs_access_point.this["grafana"].root_directory[0].path == "/grafana"
    error_message = "grafana access point root_directory.path must equal map-entry value /grafana"
  }

  assert {
    condition     = length(aws_efs_access_point.this["grafana"].root_directory[0].creation_info) == 1
    error_message = "grafana access point must emit creation_info block when caller supplies it"
  }

  assert {
    condition     = aws_efs_access_point.this["grafana"].root_directory[0].creation_info[0].permissions == "0755"
    error_message = "grafana access point creation_info.permissions must equal map-entry value 0755"
  }

  # Note: when the dynamic creation_info block is NOT emitted, the
  # rendered attribute is unknown at plan (EFS schema marks it
  # Computed). We assert the positive case via grafana's block above.

  assert {
    condition     = aws_efs_access_point.this["prometheus"].posix_user[0].secondary_gids == toset([10, 20])
    error_message = "prometheus access point secondary_gids must equal map-entry value [10, 20]"
  }

  assert {
    condition     = aws_efs_access_point.this["grafana"].tags["Name"] == "grafana"
    error_message = "Access point Name tag must equal the access_points map key"
  }
}
