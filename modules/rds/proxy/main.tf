#--------------------------------------------------------------
# RDS Proxy module — entrypoint
#
# Places an Amazon RDS Proxy in front of an RDS or Aurora data-tier
# module. Composition flows through the target's remote state
# (ADR-0001 / DESIGN-0010 Q3): a single data.terraform_remote_state
# reads the target DB module's outputs — master_user_secret_arn, the
# DB security group, subnet IDs, vpc_id, the secret CMK, engine, the
# instance/cluster identifier, and the IAM-auth flag — keyed on
# var.target_type + var.target_identifier. The proxy's own inputs are
# just pointers (region, name, target_type, target_identifier,
# remote_state_bucket) plus behaviour knobs (TLS, timeouts, pool
# config, the optional Aurora READ_ONLY endpoint, consumer SGs).
#
# A single module serves rds-instance, aurora-cluster, and serverless
# targets via var.target_type; the resource graph is identical bar one
# attribute on aws_db_proxy_target.
#
# The terraform_remote_state data source and the engine-family locals
# land in Phase 3 (locals.tf + the data block below).
#--------------------------------------------------------------
