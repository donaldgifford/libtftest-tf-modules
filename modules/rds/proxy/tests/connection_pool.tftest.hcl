# Connection-pool config plumb-through per IMPL-0010 Phase 9.
# Asserts the pool knobs reach connection_pool_config on the default
# target group. Remote state stubbed via override_data (Q2-a).

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
  target_type         = "serverless"
  target_identifier   = "platform-rds"
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

run "pool_defaults" {
  command = plan

  assert {
    condition     = aws_db_proxy_default_target_group.this.connection_pool_config[0].max_connections_percent == 100
    error_message = "max_connections_percent must default to 100"
  }

  assert {
    condition     = aws_db_proxy_default_target_group.this.connection_pool_config[0].max_idle_connections_percent == 50
    error_message = "max_idle_connections_percent must default to 50"
  }

  assert {
    condition     = aws_db_proxy_default_target_group.this.connection_pool_config[0].connection_borrow_timeout == 120
    error_message = "connection_borrow_timeout must default to 120"
  }

  assert {
    # The provider normalizes the empty default to null at plan time.
    condition     = try(length(aws_db_proxy_default_target_group.this.connection_pool_config[0].session_pinning_filters), 0) == 0
    error_message = "session_pinning_filters must default to empty"
  }
}

run "pool_custom" {
  command = plan

  variables {
    max_connections_percent      = 80
    max_idle_connections_percent = 20
    connection_borrow_timeout    = 300
    session_pinning_filters      = ["EXCLUDE_VARIABLE_SETS"]
    init_query                   = "SET search_path = app"
  }

  assert {
    condition     = aws_db_proxy_default_target_group.this.connection_pool_config[0].max_connections_percent == 80
    error_message = "custom max_connections_percent must plumb through"
  }

  assert {
    condition     = aws_db_proxy_default_target_group.this.connection_pool_config[0].max_idle_connections_percent == 20
    error_message = "custom max_idle_connections_percent must plumb through"
  }

  assert {
    condition     = aws_db_proxy_default_target_group.this.connection_pool_config[0].connection_borrow_timeout == 300
    error_message = "custom connection_borrow_timeout must plumb through"
  }

  assert {
    condition     = contains(aws_db_proxy_default_target_group.this.connection_pool_config[0].session_pinning_filters, "EXCLUDE_VARIABLE_SETS")
    error_message = "session_pinning_filters must plumb through"
  }

  assert {
    condition     = aws_db_proxy_default_target_group.this.connection_pool_config[0].init_query == "SET search_path = app"
    error_message = "init_query must plumb through"
  }
}
