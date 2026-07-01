#--------------------------------------------------------------
# Computed locals
#
# Composition is via the target DB module's remote state
# (DESIGN-0010 Q3 / ADR-0001): the consumed outputs are aliased at
# the use site below so iam.tf / security_group.tf / proxy.tf read
# local.* rather than repeating the
# data.terraform_remote_state.target.outputs.* path.
#--------------------------------------------------------------

locals {
  # target_type → remote-state directory segment. Live-repo key
  # convention: <region>/rds/<dir>/<target_identifier>/terraform.tfstate
  # (DESIGN-0010 "Composition via remote state").
  target_dir_map = {
    "rds-instance"   = "instance"
    "aurora-cluster" = "cluster"
    "serverless"     = "serverless"
  }

  target_dir = local.target_dir_map[var.target_type]

  # Outputs consumed from the target DB module's remote state, aliased
  # here so downstream files read local.* (per the "read at the use
  # site" convention). The serverless module emits all of these as of
  # IMPL-0010 Phase 2; the instance/cluster modules must match.
  master_user_secret_arn = data.terraform_remote_state.target.outputs.master_user_secret_arn
  secret_kms_key_arn     = data.terraform_remote_state.target.outputs.master_user_secret_kms_key_arn
  db_security_group_id   = data.terraform_remote_state.target.outputs.security_group_id
  db_subnet_ids          = data.terraform_remote_state.target.outputs.db_subnet_ids
  vpc_id                 = data.terraform_remote_state.target.outputs.vpc_id
  engine                 = data.terraform_remote_state.target.outputs.engine
  iam_auth_enabled       = data.terraform_remote_state.target.outputs.iam_database_authentication_enabled

  # Static engine → RDS Proxy engine_family + default port. Postgres
  # rows ship first (DESIGN-0010 Q9-a); MySQL rows land in Phase 11.
  # Keyed on the engine read from remote state, so proxy/target engine
  # drift is impossible by construction. A lookup miss yields null and
  # is surfaced by the V2 precondition on aws_db_proxy (Phase 6) with a
  # clear message rather than a cryptic map-index error.
  engine_family_map = {
    "postgres"          = "POSTGRESQL"
    "aurora-postgresql" = "POSTGRESQL"
    "mysql"             = "MYSQL"
    "aurora-mysql"      = "MYSQL"
  }

  engine_default_port_map = {
    "postgres"          = 5432
    "aurora-postgresql" = 5432
    "mysql"             = 3306
    "aurora-mysql"      = 3306
  }

  engine_family = lookup(local.engine_family_map, local.engine, null)

  port = var.db_port != null ? var.db_port : lookup(local.engine_default_port_map, local.engine, null)

  # Target-identifier routing: rds-instance targets set
  # db_instance_identifier; aurora-cluster / serverless set
  # db_cluster_identifier. Exactly one is non-null on
  # aws_db_proxy_target (Phase 6).
  db_instance_identifier = var.target_type == "rds-instance" ? var.target_identifier : null
  db_cluster_identifier  = var.target_type == "rds-instance" ? null : var.target_identifier
}
