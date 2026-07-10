# modules/rds/cluster

Aurora **provisioned** cluster (single-writer) for `aurora-postgresql` /
`aurora-mysql`. `aws_rds_cluster` (`engine_mode = "provisioned"`) plus one
`aws_rds_cluster_instance` writer with a concrete `instance_class`.

This module is the **source-of-truth remote state** for the cluster ↔
read-replica composition and a valid RDS Proxy target
(`target_type = "aurora-cluster"`).

See [`USAGE.md`](USAGE.md) for the generated input/output reference and
[IMPL-0012](../../../docs/impl/0012-rds-aurora-provisioned-cluster-module-implementation.md)
/ [DESIGN-0013](../../../docs/design/0013-rds-aurora-provisioned-cluster-module.md)
for the design and implementation plan.
