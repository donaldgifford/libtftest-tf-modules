#--------------------------------------------------------------
# Aliased cluster remote-state outputs
#
# A thin locals layer aliasing the cluster outputs consumed by the
# readers, read from data.terraform_remote_state.rds_cluster (main.tf).
# Security group + KMS are cluster-owned; readers inherit them
# automatically and never re-set them, so they are not aliased here.
#
#   cluster_identifier      — attach each reader to this cluster.
#   engine                  — passthrough so the reader engine can't
#                             drift from the cluster (Q5).
#   engine_version_actual   — the version AWS actually applied on the
#                             cluster; pinned onto each reader so the
#                             reader plan shows it explicitly (Q5-a),
#                             even though Aurora would inherit it.
#   db_subnet_group_name    — the cluster's subnet group (inherited).
#   db_parameter_group_name — the cluster's instance parameter group,
#                             set explicitly on each reader (Q5-a).
#--------------------------------------------------------------

locals {
  cluster_outputs = data.terraform_remote_state.rds_cluster.outputs

  cluster_identifier      = local.cluster_outputs.cluster_identifier
  engine                  = local.cluster_outputs.engine
  engine_version_actual   = local.cluster_outputs.engine_version_actual
  db_subnet_group_name    = local.cluster_outputs.db_subnet_group_name
  db_parameter_group_name = local.cluster_outputs.db_parameter_group_name
}
