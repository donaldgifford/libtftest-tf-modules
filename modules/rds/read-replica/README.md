# modules/rds/read-replica

Aurora **reader instances** (`aws_rds_cluster_instance`) attached to an
**existing** cluster provisioned by `modules/rds/cluster` (IMPL-0012). A pure
consumer of the cluster's remote state (ADR-0001) — it owns no cluster, subnet
group, security group, or KMS key. A `for_each` over a typed `replicas` map
creates one reader per entry, named `<identifier_prefix>-replica-<key>`.

See [`USAGE.md`](USAGE.md) for the generated input/output reference and
[IMPL-0013](../../../docs/impl/0013-rds-aurora-read-replica-module-implementation.md)
/ [DESIGN-0014](../../../docs/design/0014-rds-aurora-read-replica-module.md)
for the design and implementation plan.
