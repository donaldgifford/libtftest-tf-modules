#--------------------------------------------------------------
# Aurora reader instances
#
# One aws_rds_cluster_instance per var.replicas entry, attached to the
# existing cluster (local.cluster_identifier from remote state). Each
# reader is named <identifier_prefix>-replica-<key>. engine +
# engine_version are pinned from the cluster's remote state so a reader
# can't drift from the cluster (Q5); db_subnet_group_name +
# db_parameter_group_name are the cluster's, set explicitly so they show
# in the reader plan (Q5-a). Storage encryption / KMS / SG are
# cluster-owned and inherited automatically — not re-set here.
#
# promotion_tier defaults to 15 (below the writer's tier 0) so a reader
# never outranks the writer during failover. availability_zone = null
# lets Aurora place the reader automatically.
#--------------------------------------------------------------

resource "aws_rds_cluster_instance" "replica" {
  for_each = var.replicas

  cluster_identifier           = local.cluster_identifier
  identifier                   = "${var.identifier_prefix}-replica-${each.key}"
  instance_class               = each.value.instance_class
  engine                       = local.engine
  engine_version               = local.engine_version_actual
  db_subnet_group_name         = local.db_subnet_group_name
  db_parameter_group_name      = local.db_parameter_group_name
  apply_immediately            = var.apply_immediately
  auto_minor_version_upgrade   = each.value.auto_minor_version_upgrade
  availability_zone            = each.value.availability_zone
  monitoring_interval          = each.value.monitoring_interval
  monitoring_role_arn          = each.value.monitoring_role_arn
  performance_insights_enabled = each.value.performance_insights_enabled
  promotion_tier               = each.value.promotion_tier
  publicly_accessible          = each.value.publicly_accessible
  tags                         = var.tags

  lifecycle {
    # Q7-design — stale / wrong / partially-applied cluster state. If the
    # cluster's remote state doesn't carry a cluster_identifier, the
    # readers have nothing valid to attach to; fail the plan with a
    # message naming the expected state key rather than emitting a broken
    # attach at apply.
    precondition {
      condition     = local.cluster_identifier != null
      error_message = "Cluster remote state resolved a null cluster_identifier. Confirm modules/rds/cluster has been applied for cluster_identifier=${var.cluster_identifier} with state at ${var.region}/rds/cluster/${var.cluster_identifier}/terraform.tfstate in bucket ${var.remote_state_bucket}."
    }

    # Q7 — the composed identifier must stay within the AWS 63-char RDS
    # limit. The per-key length bound in variables.tf is self-contained;
    # this cross-variable check (identifier_prefix + key) lives in a
    # precondition per the validation-split doctrine (terraform >= 1.1).
    precondition {
      condition     = length("${var.identifier_prefix}-replica-${each.key}") <= 63
      error_message = "Composed reader identifier '${var.identifier_prefix}-replica-${each.key}' exceeds the AWS 63-char RDS identifier limit. Shorten identifier_prefix or the replicas key."
    }

    # Q4-design — per-reader Enhanced Monitoring requires a role ARN. The
    # module does not provision the role (module-boundary policy, IMPL-0007
    # Q6); the caller supplies a pre-existing rds-monitoring-role ARN.
    precondition {
      condition     = each.value.monitoring_interval == 0 || each.value.monitoring_role_arn != null
      error_message = "replicas[\"${each.key}\"] sets monitoring_interval > 0 but monitoring_role_arn is null. Supply the ARN of a pre-existing rds-monitoring-role (the module does not provision it)."
    }
  }
}
