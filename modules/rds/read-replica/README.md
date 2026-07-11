<!-- markdownlint-disable-file MD025 MD041 -->
# Aurora Read-Replica Module

Attaches one or more Aurora **reader instances** (`aws_rds_cluster_instance`)
to an **existing** cluster provisioned by `modules/rds/cluster` (IMPL-0012). A
pure consumer of the cluster's remote state (ADR-0001) — it owns no cluster,
subnet group, security group, or KMS key. A `for_each` over a typed `replicas`
map creates one reader per entry, named `<identifier_prefix>-replica-<key>`,
with engine / engine version / subnet group / parameter group all inherited
from the cluster's remote state (drift-proof by construction).

Implements
[IMPL-0013](../../../docs/impl/0013-rds-aurora-read-replica-module-implementation.md)
/ [DESIGN-0014](../../../docs/design/0014-rds-aurora-read-replica-module.md).

See [USAGE.md](USAGE.md) for the generated input / output reference.

## Prerequisites

1. **A cluster provisioned by `modules/rds/cluster` (IMPL-0012)** in the same
   account + region, with its state written to S3 at
   `<region>/rds/cluster/<cluster_identifier>/terraform.tfstate`. This module
   reads the cluster's outputs — `cluster_identifier`, `engine`,
   `engine_version_actual`, `db_subnet_group_name`, `db_parameter_group_name`
   — from that state. `cluster_identifier` here is the cluster module's
   `var.identifier_prefix`.
2. **S3 backend bucket** (`var.remote_state_bucket`) exists and is reachable
   from the runner.
3. **LocalStack** — optional. A reader is Aurora (real embedded PostgreSQL) and
   the apply bridges the cluster's state through a real S3 object, so the full
   apply is **Pro-gated** (`tests-localstack-pro/`, off by default); the
   always-on `tests-localstack/` suite is a Community-safe `plan_smoke`. See
   [`tests-localstack/FINDINGS.md`](tests-localstack/FINDINGS.md).

## Instantiation

### Single reader

```hcl
module "platform_db_readers" {
  source = "git::https://github.com/your-org/libtftest-tf-modules.git//modules/rds/read-replica?ref=v1.0.0"

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  cluster_identifier  = "platform-db" # the cluster module's identifier_prefix
  identifier_prefix   = "platform-db"

  replicas = {
    r1 = { instance_class = "db.r6g.large" }
  }

  tags = { Service = "platform-api" }
}
```

### Three readers with per-reader tuning

```hcl
module "analytics_readers" {
  source = "..."

  region              = "us-east-1"
  remote_state_bucket = "your-org-tfstate"
  cluster_identifier  = "analytics-db"
  identifier_prefix   = "analytics-db"

  replicas = {
    # A reporting reader pinned to an AZ, higher failover priority.
    reporting = {
      instance_class    = "db.r6g.xlarge"
      availability_zone = "us-east-1a"
      promotion_tier    = 5
    }
    # Two general read-scaling readers on the default tier (15).
    read-1 = { instance_class = "db.r6g.large" }
    read-2 = { instance_class = "db.r6g.large" }
  }
}
```

Each reader is named `<identifier_prefix>-replica-<key>` (e.g.
`analytics-db-replica-reporting`). `promotion_tier` defaults to 15 — below the
writer's tier 0 — so a reader never outranks the writer during failover. Set a
lower tier on a reader you want promoted first.

### Connecting

The module emits per-reader endpoints for **targeted** routing:

```hcl
output "reporting_endpoint" {
  value = module.analytics_readers.replica_endpoints["reporting"]
}
```

For **load-balanced** reads across all readers, use the **cluster's** own
`reader_endpoint` output (from the `cluster` module) — this module deliberately
does not create a new pooled endpoint (DESIGN-0014 non-goal).

## Operational gotchas

### A cluster destroy/recreate forces reader replacement

The readers attach by `cluster_identifier`, and the cluster's immutable
`cluster_resource_id` changes if the cluster is destroyed and recreated. A
recreated cluster is a different cluster; the readers must be replaced to
attach to it. Treat cluster recreation as a fleet event — plan the readers
alongside it (DESIGN-0014 Q7). Routine cluster updates (parameter changes,
engine-minor upgrades) do **not** change `cluster_resource_id` and leave the
readers in place.

### Engine / version / parameter group are inherited — not set here

`engine`, `engine_version`, `db_subnet_group_name`, and
`db_parameter_group_name` all come from the cluster's remote state, pinned onto
each reader so they show explicitly in the reader plan (Q5-a). To change them,
change the cluster and re-apply this module — never diverge a reader from its
cluster.

### Enhanced Monitoring needs a role ARN per reader

A reader with `monitoring_interval > 0` must also set `monitoring_role_arn`
(the module does not provision the role — supply a pre-existing
`rds-monitoring-role` ARN). A precondition enforces this at plan time.

### Key stability

`replicas` uses `for_each`, so each reader is addressed by its map key, not a
positional index. Removing a middle key does **not** renumber or replace the
survivors — only the removed reader is destroyed. Keep keys stable across
applies.

## Tests

```bash
# Plan-only suite (~5s, no LocalStack):
just tf test rds/read-replica

# Community plan_smoke (offline-safe, plan-only):
just tf test-localstack rds/read-replica

# Pro apply suite (opt-in — needs LocalStack Pro; see FINDINGS.md):
just tf test-localstack-pro rds/read-replica
```

## Module map

| File | Purpose |
|------|---------|
| `versions.tf` | Provider + Terraform version pins |
| `variables.tf` | Pointer surface + the hybrid `replicas` map(object) + validations |
| `main.tf` | `data.terraform_remote_state.rds_cluster` (the cluster state read) |
| `locals.tf` | Aliased cluster remote-state outputs |
| `replicas.tf` | `aws_rds_cluster_instance.replica` (`for_each`) + 3 preconditions |
| `outputs.tf` | `replica_identifiers` + `replica_endpoints` maps |
| `tests/` | Plan-only `terraform test` suite (11 runs) |
| `tests-localstack/` | Community `plan_smoke` + FINDINGS.md |
| `tests-localstack-pro/` | Pro apply suite + `fixtures/cluster` (real cluster module, Q4-b) |
