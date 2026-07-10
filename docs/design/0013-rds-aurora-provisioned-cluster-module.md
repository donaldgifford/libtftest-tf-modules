---
id: DESIGN-0013
title: "RDS Aurora provisioned cluster module"
status: Implemented
author: Donald Gifford
created: 2026-07-09
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0013: RDS Aurora provisioned cluster module

**Status:** Implemented
**Author:** Donald Gifford
**Date:** 2026-07-09

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Position in the RDS module family](#position-in-the-rds-module-family)
  - [Relationship to the serverless module](#relationship-to-the-serverless-module)
  - [Module file layout](#module-file-layout)
  - [Resources](#resources)
  - [The source-of-truth output contract](#the-source-of-truth-output-contract)
  - [Validation surface](#validation-surface)
- [API / Interface Changes](#api--interface-changes)
  - [Input surface](#input-surface)
  - [Output surface](#output-surface)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [Q1 — Strictly single-writer, or optional inline readers? — RESOLVED (a)](#q1--strictly-single-writer-or-optional-inline-readers--resolved-a)
  - [Q2 — Default writer instance class — RESOLVED (a)](#q2--default-writer-instance-class--resolved-a)
  - [Q3 — Aurora storage type (I/O-Optimized) — RESOLVED (a)](#q3--aurora-storage-type-io-optimized--resolved-a)
  - [Q4 — Aurora MySQL Backtrack — RESOLVED (a)](#q4--aurora-mysql-backtrack--resolved-a)
  - [Q5 — Cross-region / global cluster support — RESOLVED (a)](#q5--cross-region--global-cluster-support--resolved-a)
  - [Q6 — CloudWatch logs exports default — RESOLVED (a)](#q6--cloudwatch-logs-exports-default--resolved-a)
  - [Q7 — Cluster-level custom endpoints — RESOLVED (a)](#q7--cluster-level-custom-endpoints--resolved-a)
  - [Q8 — Mixed provisioned + Serverless v2 instances — RESOLVED (a)](#q8--mixed-provisioned--serverless-v2-instances--resolved-a)
- [References](#references)
<!--toc:end-->

## Overview

`modules/rds/cluster` is an **Aurora provisioned cluster** (`aws_rds_cluster`
with `engine_mode = "provisioned"` + a single `aws_rds_cluster_instance`
writer) for `aurora-postgresql` / `aurora-mysql` production workloads that
need high availability and read scaling. It defaults to a **single-writer**
topology; additional reader instances are added out-of-band via the
`read-replica` module ([DESIGN-0014](0014-rds-aurora-read-replica-module.md))
as separate Terraform plans, so each replica change has its own small blast
radius.

Critically, this module is the **source-of-truth state file** for the
cluster ↔ read-replica composition
([ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md)):
its outputs are the contract `read-replica` reads from remote state, and it
is also a valid RDS Proxy target (`target_type = "aurora-cluster"`). The
design reuses the shipped `serverless` module's scaffolding almost entirely —
the only structural difference is dropping the `serverlessv2_scaling_
configuration` block and taking a concrete `instance_class` instead of the
`db.serverless` sentinel.

## Goals and Non-Goals

### Goals

- **Aurora provisioned cluster** for `aurora-postgresql` / `aurora-mysql`,
  single-writer by default, from scratch (no `terraform-aws-modules/*`).
- **Reuse serverless scaffolding verbatim** — VPC remote state, KMS
  (managed-or-BYO), subnet group, security group + granular rules,
  parameter groups (cluster + instance), AWS-managed master password,
  IAM-auth opt-in, the validation-split doctrine.
- **Be the read-replica composition anchor.** Emit the full consumer
  contract (`cluster_identifier`, `cluster_resource_id`,
  `engine_version_actual`, `db_subnet_group_name`, `security_group_id`,
  `kms_key_id`, `db_parameter_group_name`, …) at the fleet-standard state key
  `${region}/rds/cluster/${identifier}/terraform.tfstate`.
- **Be a valid RDS Proxy target** — emit the same seven proxy-composition
  outputs `serverless` emits (DESIGN-0010 / IMPL-0010 Phase 2).
- **Small, reversible plans.** Single writer keeps the cluster plan minimal;
  scale-out is a separate module/plan (see the DESIGN-0007 rationale).
- **Encryption + isolation on by default** (module-managed KMS, private
  subnets, no public endpoint).

### Non-Goals

- **Read replicas in this module.** Reader instances are the `read-replica`
  module's job. This module provisions exactly one writer instance
  (revisited in Q1).
- **Aurora Serverless v2.** That is the shipped `serverless` module. Mixing
  `db.serverless` readers into a provisioned cluster is Q8.
- **Aurora Multi-Master / multi-writer.** Out of scope (DESIGN-0007
  non-goal) — different consistency + IAM surface.
- **Cross-region / global clusters** (`aws_rds_global_cluster`). Out of scope
  for v1 (Q5).
- **Schema migrations / app users.** Out of band
  ([ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md)).
- **Other Aurora engines / features** (Aurora Limitless, Babelfish, ML
  integrations). Deferred until a concrete consumer.

## Background

The `serverless` module (IMPL-0007) already ships an `aws_rds_cluster` with
`engine_mode = "provisioned"` — Aurora Serverless v2 *is* a provisioned
cluster with a `serverlessv2_scaling_configuration` block and a
`db.serverless` instance. A provisioned (non-serverless) cluster is therefore
the *simpler* case: remove the scaling block, replace the `db.serverless`
instance class with a real one (`db.r6g.large`, `db.t4g.medium`, …). Every
other resource — KMS, subnet group, SG, both parameter groups, the master
secret, the preconditions — is already battle-tested in `serverless` and
verified live on LocalStack Pro 2026.6.0.

DESIGN-0007 puts `cluster` third in the rollout (after `serverless` and
`instance`), because it establishes the remote-state contract that
`read-replica` (fourth) depends on. That ordering holds: `read-replica` must
merge after this module pins its output names.

Provider baseline unchanged: `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`.

## Detailed Design

### Position in the RDS module family

```text
modules/rds/
├── instance/      — single aws_db_instance (DESIGN-0012)
├── cluster/       ← THIS MODULE — Aurora provisioned, single-writer default
├── read-replica/  — reader instances attached via THIS module's remote state
└── serverless/    — Aurora Serverless v2 (shipped, IMPL-0007)
```

### Relationship to the serverless module

The cleanest framing for the IMPL: **`cluster` = `serverless` with two
edits.**

| Aspect | `serverless` (shipped) | `cluster` (this design) |
|--------|------------------------|-------------------------|
| `aws_rds_cluster.engine_mode` | `"provisioned"` | `"provisioned"` (same) |
| Scaling block | `serverlessv2_scaling_configuration { min/max }` | **removed** |
| Writer `instance_class` | `"db.serverless"` (hardcoded) | `var.instance_class` (a real class) |
| `min_acu` / `max_acu` inputs | required | **removed** |
| Everything else | KMS, SG, subnet group, param groups, master secret, preconditions, outputs | **identical** |

Every other file (`versions.tf`, `locals.tf`, `kms.tf`, `main.tf`,
`network.tf`, `parameter_groups.tf`, `outputs.tf`) is a near-verbatim copy
with the `-rds-serverless` name suffix swapped for `-rds-cluster`.

### Module file layout

```text
modules/rds/cluster/
├── versions.tf          — required_version >= 1.1, aws ~> 6.2
├── variables.tf         — Required / Optional banners
├── locals.tf            — kms_key_arn coalesce, Aurora parameter-family + port maps
├── kms.tf               — count-gated aws_kms_key + alias (prevent_destroy)
├── main.tf              — data.terraform_remote_state.vpc
├── network.tf           — aws_db_subnet_group + aws_security_group + rules
├── parameter_groups.tf  — aws_rds_cluster_parameter_group + aws_db_parameter_group
├── cluster.tf           — aws_rds_cluster.this + preconditions
├── instance.tf          — aws_rds_cluster_instance.writer + precondition
├── outputs.tf           — full read-replica contract + 4 proxy outputs
├── README.md / USAGE.md
├── tests/               — plan-only gate
└── tests-localstack/    — apply suite (+ FINDINGS.md, fixtures/setup)
```

### Resources

- `aws_db_subnet_group.this`, `aws_security_group.this` + granular ingress
  (per consumer SG) / egress (all-outbound) rules — as serverless.
- `aws_kms_key.this[0]` + `aws_kms_alias.this[0]` — count-gated on
  `var.kms_key_arn == null`, `prevent_destroy`, rotation, 30-day window.
- `aws_rds_cluster_parameter_group.this` + `aws_db_parameter_group.this` —
  `name_prefix` + `create_before_destroy`, `family =
  local.resolved_parameter_family` from the Aurora map (`aurora-postgresql16`
  / `aurora-mysql8.0`, keyed `engine:major`).
- `aws_rds_cluster.this`:
  - `cluster_identifier = var.identifier_prefix`.
  - `engine = var.engine` (`aurora-postgresql` / `aurora-mysql`),
    `engine_mode = "provisioned"`, `engine_version = var.engine_version`.
  - `db_cluster_parameter_group_name`, `db_subnet_group_name`,
    `vpc_security_group_ids = [aws_security_group.this.id]`.
  - `storage_encrypted = true`, `kms_key_id = local.kms_key_arn`,
    `master_user_secret_kms_key_id = local.kms_key_arn`.
  - `manage_master_user_password`, `master_username`, `database_name`.
  - `iam_database_authentication_enabled`.
  - `backup_retention_period`, `preferred_backup_window`,
    `preferred_maintenance_window`.
  - `deletion_protection = true`, `skip_final_snapshot = false`,
    `final_snapshot_identifier`.
  - `storage_type` (Q3), `enabled_cloudwatch_logs_exports` (Q6),
    `backtrack_window` for Aurora MySQL (Q4).
  - **No** `serverlessv2_scaling_configuration`.
  - `lifecycle` preconditions: `resolved_parameter_family != null`;
    `skip_final_snapshot || final_snapshot_identifier != null`.
- `aws_rds_cluster_instance.writer` (single instance):
  - `cluster_identifier = aws_rds_cluster.this.id`,
    `identifier = "${var.identifier_prefix}-1"`.
  - `instance_class = var.instance_class` (a real class — Q2).
  - `engine`, `engine_version` sourced from `aws_rds_cluster.this` (single
    source of truth, no drift).
  - `db_subnet_group_name`, `db_parameter_group_name`.
  - `publicly_accessible = false`, `apply_immediately`,
    `auto_minor_version_upgrade`.
  - `performance_insights_enabled` + `performance_insights_kms_key_id` (conditional),
    `monitoring_interval` + `monitoring_role_arn` (enhanced monitoring opt-in),
    `promotion_tier` (default `0` — the writer is tier 0).
  - `lifecycle` precondition: `enhanced_monitoring_interval == 0 ||
    enhanced_monitoring_role_arn != null`.

### The source-of-truth output contract

This module's outputs serve two consumers, and must be a superset satisfying
both:

1. **`read-replica`** reads (DESIGN-0007): `cluster_identifier`,
   `cluster_resource_id`, `engine`, `engine_version_actual`,
   `db_subnet_group_name`, `security_group_id`, `kms_key_id` /
   `kms_key_arn`, `db_parameter_group_name`.
2. **`proxy`** (`target_type = "aurora-cluster"`) reads the seven-output
   composition set: `master_user_secret_arn`,
   `master_user_secret_kms_key_arn`, `security_group_id`, `db_subnet_ids`,
   `vpc_id`, `engine`, `iam_database_authentication_enabled`.

The full output set (identical shape to `serverless` plus
`cluster_instance_identifier`):

```text
cluster_identifier, cluster_resource_id, cluster_endpoint, reader_endpoint,
port, engine, engine_version_actual, db_subnet_group_name, security_group_id,
kms_key_arn, master_user_secret_arn, db_cluster_parameter_group_name,
db_parameter_group_name, cluster_instance_identifier
# + proxy-composition set:
db_subnet_ids, vpc_id, master_user_secret_kms_key_arn,
iam_database_authentication_enabled
```

Same null-safe expressions as serverless: `master_user_secret_arn` /
`master_user_secret_kms_key_arn` use `try(...master_user_secret[0]..., null)`;
`vpc_id` reads `aws_security_group.this.vpc_id`.

### Validation surface

Same doctrine, Aurora-flavoured:

- **Variable validations**: `identifier_prefix` regex; `engine`
  (`^aurora-(postgresql|mysql)$`); `engine_version` (`^(\d+\.\d+|\d+)$` or
  null); `allowed_consumer_sg_ids` (each `^sg-[a-f0-9]+$`);
  `backup_retention_period` in `[1,35]`; `enhanced_monitoring_interval` in
  `{0,1,5,10,15,30,60}`; `promotion_tier` in `[0,15]` if exposed;
  `storage_type` in `["aurora","aurora-iopt1"]` if exposed (Q3).
- **Preconditions** on `aws_rds_cluster.this`:
  `resolved_parameter_family != null`; `skip_final_snapshot ||
  final_snapshot_identifier != null`; and (if Q4 lands) `backtrack_window ==
  0 || engine == "aurora-mysql"`. On `aws_rds_cluster_instance.writer`: the
  enhanced-monitoring-role precondition.

## API / Interface Changes

Greenfield module.

### Input surface

Same required core as serverless, swapping `min_acu`/`max_acu` for
`instance_class`:

| Input | Type | Required? | Default |
|-------|------|-----------|---------|
| `region` | string | yes | — |
| `remote_state_bucket` | string | yes | — |
| `vpc_name` | string | yes | — |
| `identifier_prefix` | string | yes | — |
| `engine` | string | yes | — |
| `instance_class` | string | yes | — |
| `engine_version` | string | no | null |
| `storage_type` | string | no | null (Aurora Standard) |
| `backtrack_window` | number | no | 0 (aurora-mysql only) |
| `enabled_cloudwatch_logs_exports` | list(string) | no | [] |
| `kms_key_arn` | string | no | null (module-managed) |
| `allowed_consumer_sg_ids` | list(string) | no | [] |
| `iam_database_authentication_enabled` | bool | no | false |
| `manage_master_user_password` | bool | no | true |
| `master_username` | string | no | "admin" |
| `database_name` | string | no | null |
| `backup_retention_period` | number | no | 7 |
| `preferred_backup_window` | string | no | "02:00-03:00" |
| `preferred_maintenance_window` | string | no | "sun:04:00-sun:05:00" |
| `deletion_protection` | bool | no | true |
| `publicly_accessible` | bool | no | false |
| `apply_immediately` | bool | no | false |
| `auto_minor_version_upgrade` | bool | no | true |
| `parameter_family` | string | no | resolved |
| `final_snapshot_identifier` | string | no | null |
| `skip_final_snapshot` | bool | no | false |
| `performance_insights_enabled` | bool | no | false |
| `enhanced_monitoring_interval` | number | no | 0 |
| `enhanced_monitoring_role_arn` | string | no | null |
| `tags` | map(string) | no | {} |

### Output surface

The full source-of-truth contract above.

## Data Model

No application schema; the module manages the Aurora cluster + writer
instance, network, KMS, and parameter groups. Master credentials are an
AWS-managed Secrets Manager secret, KMS-encrypted with the module key; the
ARN is an output. App users / roles / GRANTs out of scope.

## Testing Strategy

Mirroring the serverless suites (RFC-0001):

- **`tests/` plan-only gate** — fake provider, `override_data` VPC stub, BYO
  KMS in the shared `variables{}`. Runs: default `aurora-postgresql` +
  `aurora-mysql` shape (engine, `engine_mode = "provisioned"`, **no**
  serverless scaling block, `instance_class` is the real class,
  `storage_encrypted`, `deletion_protection`); managed-KMS count; BYO-KMS;
  parameter-family resolution; SG ingress (2 / 0 / mysql-port); and a
  `validation.tftest.hcl` of `expect_failures` negatives (bad engine, bad
  version, bad backup retention, snapshot-required precondition,
  identifier shape, monitoring-role-required precondition).
- **`tests-localstack/` apply suite** — `setup` fixture (VPC + private
  subnets + S3 stub state) then `apply_default` provisioning the full Aurora
  provisioned cluster + writer; `plan_mysql` for cheaper second-engine
  coverage. Aurora provisioned clusters apply on LocalStack Pro (verified for
  the near-identical serverless stack on Pro 2026.6.0). **Tier-agnostic;
  no `tests-localstack-pro/`** (this is not a Pro-only surface like proxy —
  though in practice Aurora needs Pro's native RDS provider; document the
  observed tier in `FINDINGS.md` at IMPL time). 501s follow the IMPL-0005
  Phase 9 fall-back.
- **macOS caveat** — same embedded-Postgres named-volume requirement as
  serverless / proxy.

## Migration / Rollout Plan

Greenfield; ships third in the DESIGN-0007 order. It **must merge before**
`read-replica`, whose remote-state read depends on this module's pinned
output names. Steps: fork serverless → delete the scaling block + `min/max
acu`, add `instance_class` → plan-only tests → LocalStack apply probe (+
FINDINGS) → USAGE + README regen → mark Implemented. When `read-replica`
lands, add a note to this module's README pointing at the composition key.

## Open Questions

All eight questions were resolved 2026-07-09 (all **a**). Each heading records
the chosen option; the **Resolved** line states the decision, and the
alternatives are retained for the record.

### Q1 — Strictly single-writer, or optional inline readers? — RESOLVED (a)

**Resolved: a.** Strictly single writer — reader instances are the
`read-replica` module's job (DESIGN-0014, separate plan + blast radius). This
module provisions exactly `aws_rds_cluster_instance.writer`.

- **a (chosen):** **Strictly single writer.** Reader instances are the
  `read-replica` module's job (separate plan, separate blast radius) — the
  core DESIGN-0007 factoring. This module provisions exactly
  `aws_rds_cluster_instance.writer`. Keeps the cluster plan small and
  reversible.
- **b:** Expose an optional `reader_instances` map (or `reader_count`) so a
  caller can stand up writer + N readers in one plan — fewer moving parts for
  simple cases, but couples reader lifecycle to the cluster's state and
  duplicates the read-replica module's surface.
- **c:** Single writer now, but design the outputs so a *future* inline
  reader option is additive — i.e. commit to (a) for v1 but explicitly
  reserve the input name.
- **other:** ______

### Q2 — Default writer instance class — RESOLVED (a)

**Resolved: a.** `instance_class` is required with no default (sizing is
workload- and cost-specific). USAGE shows starters — `db.r6g.large` (prod),
`db.t4g.medium` (dev).

- **a (chosen):** **Required, no default** — sizing is workload- and
  cost-specific (same posture as serverless requiring ACUs and the instance
  module's Q1). USAGE shows a sensible starter (`db.r6g.large` for prod,
  `db.t4g.medium` for dev).
- **b:** Default **`db.r6g.large`** — a reasonable prod-grade Graviton
  default, but a surprising bill for someone who forgets to set it.
- **c:** Default **`db.t4g.medium`** — cheap burstable default good for dev,
  under-sized for prod (T-class is not recommended for steady prod Aurora).
- **other:** ______

### Q3 — Aurora storage type (I/O-Optimized) — RESOLVED (a)

**Resolved: a.** Expose `var.storage_type` (optional, default `null` → Aurora
**Standard**); cost-conscious high-I/O clusters opt into `aurora-iopt1`.

- **a (chosen):** Expose `var.storage_type` (optional, default **`null`**
  → Aurora **Standard**). Lets cost-conscious high-I/O clusters opt into
  `aurora-iopt1` (I/O-Optimized: no per-request I/O charges, ~30% higher
  instance/storage rate) without forcing it on low-I/O clusters where
  Standard is cheaper.
- **b:** Default **`aurora-iopt1`** — predictable billing (no I/O surprises),
  but more expensive for the many low-I/O clusters.
- **c:** Omit the input — smallest surface, but no way to opt into
  I/O-Optimized without a module change.
- **other:** ______

### Q4 — Aurora MySQL Backtrack — RESOLVED (a)

**Resolved: a.** Expose `var.backtrack_window` (optional, default `0` = off),
with a precondition restricting non-zero values to `aurora-mysql` (Backtrack
is Aurora-MySQL-only).

- **a (chosen):** Expose `var.backtrack_window` (optional, default
  **`0` = off**), and add a precondition that it's only non-zero for
  `aurora-mysql` (Backtrack is Aurora-MySQL-only). Off by default keeps
  storage cost down; available for consumers who want fast rewind.
- **b:** Omit it for v1 — smallest surface; add later when a consumer asks.
- **c:** Default it **on** at a small window (e.g. 24h) for aurora-mysql —
  handy safety net, but adds cost silently and does nothing for postgres.
- **other:** ______

### Q5 — Cross-region / global cluster support — RESOLVED (a)

**Resolved: a.** Cross-region / global clusters are out of scope for v1; file
a follow-up DESIGN when cross-region DR is needed.

- **a (chosen):** **Out of scope for v1** (DESIGN-0007 non-goal). A
  global cluster needs `aws_rds_global_cluster` and a different remote-state
  shape; file a follow-up DESIGN when a consumer needs cross-region DR.
- **b:** Add an optional `global_cluster_identifier` passthrough so this
  cluster can join an externally-managed global cluster — small surface, but
  invites half-supported cross-region expectations without the full design.
- **other:** ______

### Q6 — CloudWatch logs exports default — RESOLVED (a)

**Resolved: a.** Expose `var.enabled_cloudwatch_logs_exports` (optional,
default `[]` = off); operators opt into the engine-specific set.

- **a (chosen):** Expose the input, default **`[]`** (off). Log exports
  cost money (CloudWatch ingestion) and the right set is engine- and
  workload-specific; operators opt in (`["postgresql"]`, or
  `["audit","error","slowquery"]` for MySQL).
- **b:** Default a sensible per-engine set (postgres → `["postgresql"]`,
  mysql → `["error","slowquery"]`) — observability on by default, at some
  CloudWatch cost.
- **c:** Omit the input for v1.
- **other:** ______

### Q7 — Cluster-level custom endpoints — RESOLVED (a)

**Resolved: a.** Cluster-level custom endpoints are out of scope for v1; the
built-in writer/reader endpoints suffice. Revisit alongside DESIGN-0014 if
instance-group routing is needed.

- **a (chosen):** **Out of scope for v1.** The cluster already emits the
  built-in writer (`cluster_endpoint`) and reader (`reader_endpoint`)
  endpoints. Custom endpoints (grouping specific instances) are a
  read-replica-topology concern; revisit alongside DESIGN-0014 if a consumer
  needs instance-group routing.
- **b:** Expose an optional `custom_endpoints` map now — future-proofs
  advanced routing, but adds surface before there's a consumer and overlaps
  the read-replica module's remit.
- **other:** ______

### Q8 — Mixed provisioned + Serverless v2 instances — RESOLVED (a)

**Resolved: a.** Mixed provisioned + Serverless v2 instances are out of scope;
`cluster` is all-provisioned. If mixed topologies are needed, design them
explicitly (likely via the read-replica module).

- **a (chosen):** **Out of scope** — a provisioned cluster with
  `db.serverless` reader instances (Aurora's "mixed-configuration" cluster)
  blurs the line with the `serverless` module. Keep `cluster` = all
  provisioned instances; if mixed topologies are needed, design them
  explicitly (likely in the read-replica module, which could attach a
  `db.serverless` reader to a provisioned cluster).
- **b:** Allow the writer to stay provisioned while readers (via
  read-replica) can be `db.serverless` — matches a real AWS pattern
  (cheap serverless readers under a provisioned writer), but needs the
  read-replica object to carry `instance_class = "db.serverless"` and extra
  validation.
- **other:** ______

## References

- [DESIGN-0007](0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS module family layout (parent design).
- [DESIGN-0014](0014-rds-aurora-read-replica-module.md) — Aurora read-replica module (the primary consumer of this module's remote-state contract).
- [DESIGN-0010](0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md) — RDS Proxy module (this cluster is a valid `target_type = "aurora-cluster"`).
- [IMPL-0007](../impl/0007-aurora-serverless-v2-module-implementation.md) — Aurora Serverless v2 implementation (the as-built scaffolding this module forks).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state` (drives cluster ↔ read-replica).
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy.
- [`aws_rds_cluster` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster).
- [`aws_rds_cluster_instance` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance).
