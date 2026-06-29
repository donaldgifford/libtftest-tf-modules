#--------------------------------------------------------------
# RDS Proxy core
#
# One aws_db_proxy fronting the target, its default target group with
# the connection-pool config, and one aws_db_proxy_target attaching
# the writer (db_instance_identifier for rds-instance, otherwise
# db_cluster_identifier). engine_family, the master secret, subnets,
# and the IAM-auth flag all derive from the target's remote state
# (locals.tf). Cross-variable / remote-state-dependent invariants that
# variable.validation can't express live as preconditions here
# (DESIGN-0010 V2/V4/V5 on the proxy; V6 on the target group).
#--------------------------------------------------------------

resource "aws_db_proxy" "this" {
  name           = var.name
  engine_family  = local.engine_family
  role_arn       = aws_iam_role.proxy.arn
  vpc_subnet_ids = local.db_subnet_ids

  vpc_security_group_ids = [aws_security_group.proxy.id]
  require_tls            = var.require_tls
  idle_client_timeout    = var.idle_client_timeout
  debug_logging          = var.debug_logging
  tags                   = var.tags

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = local.master_user_secret_arn
    iam_auth    = var.require_iam_auth ? "REQUIRED" : "DISABLED"
  }

  lifecycle {
    # V2 — proxy-supported engine only (engine read from remote state).
    precondition {
      condition     = local.engine_family != null
      error_message = "Unsupported target engine '${local.engine}'. RDS Proxy supports postgres/aurora-postgresql (POSTGRESQL) and mysql/aurora-mysql (MYSQL); MySQL ships in IMPL-0010 Phase 11."
    }

    # V4 — IAM client auth needs IAM auth enabled on the target engine.
    precondition {
      condition     = !var.require_iam_auth || local.iam_auth_enabled
      error_message = "require_iam_auth = true demands the target have iam_database_authentication_enabled = true (read from remote state). Enable IAM auth on the DB module first, or set require_iam_auth = false."
    }

    # V5 — a proxy must have some auth path.
    precondition {
      condition     = local.master_user_secret_arn != null || var.require_iam_auth
      error_message = "The proxy has no authentication path: the target's master_user_secret_arn is null (manage_master_user_password = false) and require_iam_auth = false. Provide a managed master secret or enable IAM auth."
    }
  }
}

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name

  connection_pool_config {
    max_connections_percent      = var.max_connections_percent
    max_idle_connections_percent = var.max_idle_connections_percent
    connection_borrow_timeout    = var.connection_borrow_timeout
    session_pinning_filters      = var.session_pinning_filters
    init_query                   = var.init_query
  }

  lifecycle {
    # V6 — idle connections are a subset of the pool (cross-variable;
    # the static [0,100] / [1,100] bounds live on the variables).
    precondition {
      condition     = var.max_idle_connections_percent <= var.max_connections_percent
      error_message = "max_idle_connections_percent (${var.max_idle_connections_percent}) must be <= max_connections_percent (${var.max_connections_percent}) — idle connections are a subset of the pool."
    }
  }
}

resource "aws_db_proxy_target" "this" {
  db_proxy_name     = aws_db_proxy.this.name
  target_group_name = aws_db_proxy_default_target_group.this.name

  db_instance_identifier = local.db_instance_identifier
  db_cluster_identifier  = local.db_cluster_identifier
}
