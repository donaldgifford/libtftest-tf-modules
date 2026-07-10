#--------------------------------------------------------------
# modules/rds/cluster — Aurora provisioned cluster
#
# An Aurora provisioned cluster (aws_rds_cluster with
# engine_mode = "provisioned" + a single aws_rds_cluster_instance
# writer) for aurora-postgresql / aurora-mysql production workloads
# that need high availability and read scaling. Single-writer by
# default; readers are added out-of-band via modules/rds/read-replica.
#
# This module is the source-of-truth remote state for the
# cluster <-> read-replica composition (ADR-0001) and a valid RDS
# Proxy target (target_type = "aurora-cluster"). It forks
# modules/rds/serverless per DESIGN-0013 / IMPL-0012, dropping the
# serverlessv2_scaling_configuration block + min/max ACU inputs and
# taking a concrete var.instance_class instead of the db.serverless
# sentinel.
#
# The VPC remote-state data source lands in Phase 2.
#--------------------------------------------------------------
