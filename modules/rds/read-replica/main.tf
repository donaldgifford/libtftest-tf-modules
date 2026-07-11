#--------------------------------------------------------------
# RDS Aurora read-replica module — entrypoint
#
# Attaches one or more Aurora reader instances
# (aws_rds_cluster_instance) to an EXISTING cluster provisioned by
# modules/rds/cluster (IMPL-0012). This module owns no cluster, subnet
# group, security group, or KMS key — all of those are the cluster's,
# read via data.terraform_remote_state against the cluster's S3 state
# key (ADR-0001 / DESIGN-0014). Structurally the closest sibling to the
# proxy module: a pure consumer of another RDS module's remote state.
#
# The reader inputs are just pointers (region, remote_state_bucket,
# cluster_identifier, identifier_prefix) plus a typed replicas map that
# drives a for_each over aws_rds_cluster_instance.replica (replicas.tf).
# Engine, engine version, subnet group, and parameter group are all
# inherited from the cluster remote state — drift-proof by construction.
#
# The terraform_remote_state data source lands in Phase 2 (main.tf) and
# the aliased cluster-output locals in Phase 2 (locals.tf); the readers
# land in Phase 3 (replicas.tf).
#--------------------------------------------------------------
