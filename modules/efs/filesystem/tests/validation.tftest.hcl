# Validation negatives — variable.validation blocks + the filesystem
# lifecycle precondition. Each run wires expect_failures at the
# appropriate target (variable for variable.validation, resource for
# precondition). Per IMPL-0008 Q11: single validation file.

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

run "identifier_uppercase_rejected" {
  command = plan

  variables {
    identifier_prefix = "InvalidUpperCase"
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

  expect_failures = [
    var.identifier_prefix,
  ]
}

run "performance_mode_rejected" {
  command = plan

  variables {
    performance_mode = "maxThroughput"
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

  expect_failures = [
    var.performance_mode,
  ]
}

run "throughput_mode_rejected" {
  command = plan

  variables {
    throughput_mode = "invalid"
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

  expect_failures = [
    var.throughput_mode,
  ]
}

run "provisioned_throughput_too_small" {
  command = plan

  variables {
    throughput_mode                 = "provisioned"
    provisioned_throughput_in_mibps = 0
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

  expect_failures = [
    var.provisioned_throughput_in_mibps,
  ]
}

run "provisioned_throughput_too_big" {
  command = plan

  variables {
    throughput_mode                 = "provisioned"
    provisioned_throughput_in_mibps = 5000
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

  expect_failures = [
    var.provisioned_throughput_in_mibps,
  ]
}

run "additional_consumer_sg_id_shape_rejected" {
  command = plan

  variables {
    additional_allowed_consumer_sg_ids = ["NotAnSgId"]
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

  expect_failures = [
    var.additional_allowed_consumer_sg_ids,
  ]
}

run "access_point_uid_out_of_range" {
  command = plan

  variables {
    access_points = {
      bad = {
        posix_user = {
          uid = 70000
          gid = 1000
        }
        root_directory = {
          path = "/bad"
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

  expect_failures = [
    var.access_points,
  ]
}

run "elastic_with_provisioned_throughput_precondition" {
  command = plan

  variables {
    throughput_mode                 = "elastic"
    provisioned_throughput_in_mibps = 100
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

  expect_failures = [
    aws_efs_file_system.this,
  ]
}

run "provisioned_without_throughput_precondition" {
  command = plan

  variables {
    throughput_mode                 = "provisioned"
    provisioned_throughput_in_mibps = null
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

  expect_failures = [
    aws_efs_file_system.this,
  ]
}
