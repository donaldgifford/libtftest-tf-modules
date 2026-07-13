# Security group ingress topology (IMPL-0011 Phase 8).
#
# var.allowed_consumer_sg_ids drives for_each over
# aws_vpc_security_group_ingress_rule.consumer on local.resolved_port
# (engine default or var.db_port). Two entries -> two rules; empty -> zero
# (instance reachable from nowhere); mysql -> port 3306.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variables {
  region                    = "us-east-1"
  remote_state_bucket       = "stub-bucket"
  vpc_name                  = "libtftest-vpc"
  identifier_prefix         = "platform-rds"
  engine                    = "postgres"
  instance_class            = "db.t4g.medium"
  allocated_storage         = 20
  final_snapshot_identifier = "platform-rds-final-test"
  kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

run "two_consumers" {
  command = plan

  variables {
    allowed_consumer_sg_ids = ["sg-aaa1234567", "sg-bbb7654321"]
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

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.consumer) == 2
    error_message = "Two consumer SGs must produce exactly two ingress rules"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.consumer["sg-aaa1234567"].from_port == 5432
    error_message = "Postgres ingress rule must use from_port 5432"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.consumer["sg-aaa1234567"].ip_protocol == "tcp"
    error_message = "Ingress rules must be TCP"
  }
}

run "empty_list" {
  command = plan

  variables {
    allowed_consumer_sg_ids = []
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

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.consumer) == 0
    error_message = "Empty allowed_consumer_sg_ids must produce zero ingress rules"
  }
}

run "mysql_port" {
  command = plan

  variables {
    engine                  = "mysql"
    allowed_consumer_sg_ids = ["sg-aaa1234567"]
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

  assert {
    condition     = aws_vpc_security_group_ingress_rule.consumer["sg-aaa1234567"].from_port == 3306
    error_message = "MySQL ingress rule must use from_port 3306"
  }
}

run "db_port_override" {
  command = plan

  variables {
    db_port                 = 6432
    allowed_consumer_sg_ids = ["sg-aaa1234567"]
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

  assert {
    condition     = aws_vpc_security_group_ingress_rule.consumer["sg-aaa1234567"].from_port == 6432
    error_message = "var.db_port override must drive the ingress rule port"
  }
}
