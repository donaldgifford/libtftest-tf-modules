# Validation negatives V1–V7 per IMPL-0010 Phase 9 / DESIGN-0010.
# Each run drives one invariant to failure and asserts via
# expect_failures on the variable (static validations) or the resource
# (preconditions). Remote state stubbed via override_data (Q2-a).

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
  name                = "platform-proxy"
  remote_state_bucket = "stub-bucket"
  target_type         = "aurora-cluster"
  target_identifier   = "platform-aurora"
}

# Default healthy target outputs (aurora-postgresql, IAM auth on so V4
# is satisfied unless a run overrides it). Per-run override_data adjusts
# the specific output a negative needs.
override_data {
  target = data.terraform_remote_state.target
  values = {
    outputs = {
      master_user_secret_arn              = "arn:aws:secretsmanager:us-east-1:000000000000:secret:rds-abc"
      master_user_secret_kms_key_arn      = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
      security_group_id                   = "sg-0123456789abcdef0"
      db_subnet_ids                       = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      vpc_id                              = "vpc-0123456789abcdef0"
      engine                              = "aurora-postgresql"
      iam_database_authentication_enabled = true
    }
  }
}

# V1 — bad target_type (static variable validation).
run "v1_bad_target_type" {
  command = plan

  variables {
    target_type = "nonsense"
  }

  expect_failures = [var.target_type]
}

# V2 — unsupported engine (precondition on the proxy). db_port is set so
# the SG rules have a concrete port and only the V2 precondition fails.
run "v2_unsupported_engine" {
  command = plan

  variables {
    db_port = 1433
  }

  override_data {
    target = data.terraform_remote_state.target
    values = {
      outputs = {
        master_user_secret_arn              = "arn:aws:secretsmanager:us-east-1:000000000000:secret:rds-abc"
        master_user_secret_kms_key_arn      = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
        security_group_id                   = "sg-0123456789abcdef0"
        db_subnet_ids                       = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
        vpc_id                              = "vpc-0123456789abcdef0"
        engine                              = "sqlserver-ex"
        iam_database_authentication_enabled = true
      }
    }
  }

  expect_failures = [aws_db_proxy.this]
}

# V3 — read-only endpoint on an rds-instance target (precondition).
run "v3_read_only_on_instance" {
  command = plan

  variables {
    target_type               = "rds-instance"
    target_identifier         = "platform-db"
    create_read_only_endpoint = true
  }

  expect_failures = [aws_db_proxy.this]
}

# V4 — require_iam_auth against a target without IAM auth (precondition).
run "v4_iam_auth_without_target" {
  command = plan

  variables {
    require_iam_auth = true
  }

  override_data {
    target = data.terraform_remote_state.target
    values = {
      outputs = {
        master_user_secret_arn              = "arn:aws:secretsmanager:us-east-1:000000000000:secret:rds-abc"
        master_user_secret_kms_key_arn      = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
        security_group_id                   = "sg-0123456789abcdef0"
        db_subnet_ids                       = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
        vpc_id                              = "vpc-0123456789abcdef0"
        engine                              = "aurora-postgresql"
        iam_database_authentication_enabled = false
      }
    }
  }

  expect_failures = [aws_db_proxy.this]
}

# V5 — no auth path: null master secret + IAM auth off (precondition).
run "v5_no_auth_path" {
  command = plan

  override_data {
    target = data.terraform_remote_state.target
    values = {
      outputs = {
        master_user_secret_arn              = null
        master_user_secret_kms_key_arn      = null
        security_group_id                   = "sg-0123456789abcdef0"
        db_subnet_ids                       = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
        vpc_id                              = "vpc-0123456789abcdef0"
        engine                              = "aurora-postgresql"
        iam_database_authentication_enabled = false
      }
    }
  }

  expect_failures = [aws_db_proxy.this]
}

# V6 — idle connections exceed the pool (cross-variable precondition on
# the target group).
run "v6_idle_exceeds_max" {
  command = plan

  variables {
    max_connections_percent      = 50
    max_idle_connections_percent = 90
  }

  expect_failures = [aws_db_proxy_default_target_group.this]
}

# V6 static — max_connections_percent out of [1,100] (variable validation).
run "v6_max_connections_out_of_range" {
  command = plan

  variables {
    max_connections_percent = 0
  }

  expect_failures = [var.max_connections_percent]
}

# V7 — negative connection_borrow_timeout (variable validation).
run "v7_negative_borrow_timeout" {
  command = plan

  variables {
    connection_borrow_timeout = -1
  }

  expect_failures = [var.connection_borrow_timeout]
}
