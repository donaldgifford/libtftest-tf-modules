---
id: DESIGN-0007
title: "RDS module layout: instance, Aurora cluster, Aurora read replica, Aurora Serverless"
status: Draft
author: Donald Gifford
created: 2026-05-27
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0007: RDS module layout: instance, Aurora cluster, Aurora read replica, Aurora Serverless

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-27

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Module decomposition](#module-decomposition)
  - [Shared scaffolding](#shared-scaffolding)
  - [Cross-module composition: remote state](#cross-module-composition-remote-state)
  - [modules/rds/instance — single RDS instance](#modulesrdsinstance--single-rds-instance)
  - [modules/rds/cluster — Aurora provisioned cluster](#modulesrdscluster--aurora-provisioned-cluster)
  - [modules/rds/read-replica — Aurora cluster instance attached via remote state](#modulesrdsread-replica--aurora-cluster-instance-attached-via-remote-state)
  - [modules/rds/serverless — Aurora Serverless v2](#modulesrdsserverless--aurora-serverless-v2)
  - [Engine matrix](#engine-matrix)
- [API / Interface Changes](#api--interface-changes)
  - [Input surface (per module, common subset)](#input-surface-per-module-common-subset)
  - [Output surface (per module, common subset)](#output-surface-per-module-common-subset)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [Q1 — count vs foreach on read-replica instances — RESOLVED (foreach)](#q1--count-vs-foreach-on-read-replica-instances--resolved-foreach)
  - [Q2 — RDS-managed master password vs caller-managed Secrets Manager — RESOLVED (AWS-managed default)](#q2--rds-managed-master-password-vs-caller-managed-secrets-manager--resolved-aws-managed-default)
  - [Q3 — Parameter family resolution: static map vs data source — RESOLVED (static map)](#q3--parameter-family-resolution-static-map-vs-data-source--resolved-static-map)
  - [Q4 — Engine version pinning strategy — RESOLVED (optional + auto-minor on)](#q4--engine-version-pinning-strategy--resolved-optional--auto-minor-on)
  - [Q5 — Connectivity contract — RESOLVED (SG-source-list, IAM auth opt-in)](#q5--connectivity-contract--resolved-sg-source-list-iam-auth-opt-in)
  - [Q6 — Cross-instance read replicas on modules/rds/instance — RESOLVED (separate module, deferred)](#q6--cross-instance-read-replicas-on-modulesrdsinstance--resolved-separate-module-deferred)
  - [Q7 — tests-localstack tier handling — RESOLVED (Community default, Pro also supported)](#q7--tests-localstack-tier-handling--resolved-community-default-pro-also-supported)
- [References](#references)
<!--toc:end-->

## Overview

Four sibling Terraform modules under `modules/rds/` covering the
common RDS / Aurora consumer surface the fleet needs:

1. **`modules/rds/instance`** — a single (non-clustered) `aws_db_instance` for
   Postgres or MySQL workloads that don't need Aurora.
2. **`modules/rds/cluster`** — an Aurora provisioned cluster (`aws_rds_cluster` +
   one `aws_rds_cluster_instance`) defaulting to a single-writer
   topology. Source-of-truth state for any read replicas attached
   later.
3. **`modules/rds/read-replica`** — additional `aws_rds_cluster_instance`
   resources attached to an existing cluster, composed via
   `data.terraform_remote_state` against the cluster module's S3 key.
4. **`modules/rds/serverless`** — Aurora Serverless v2 (`aws_rds_cluster`
   with `engine_mode = "provisioned"` + `serverlessv2_scaling_configuration`).

Each module supports two engines initially: **Postgres** and **MySQL**.
Both flavors share the same module surface and resource topology;
only the `engine` / `engine_version` / parameter family inputs
differ.

## Goals and Non-Goals

### Goals

- **Match the existing fleet's module-decomposition pattern.** EKS
  is split four ways (cluster / managed-node-group / addons /
  pod-identity-access); ECR is split two ways (pull-through-cache /
  org-registry). RDS follows the same per-AWS-API-surface
  decomposition — each module is one Terraform plan, one cluster /
  instance, one consumer concern.
- **Read-replica module composes via remote state.** The cluster
  is the source-of-truth state file; read-replica consumes
  `cluster_identifier` + `cluster_resource_id` from it. Matches
  ADR-0001 cross-module composition posture.
- **Single-writer default on Aurora cluster module.** Operators
  bump replica count via the read-replica module (separate plan,
  separate blast radius), not by tuning `instance_count` on the
  cluster module. Keeps each plan small and reversible.
- **Postgres + MySQL both supported per module.** Engine choice is
  a `var.engine` input; defaults differ per engine (parameter
  family, default port, default instance class) but the module
  resource graph is identical.
- **Encryption-at-rest on by default.** Module-managed KMS key per
  cluster / instance (BYO-able via `var.kms_key_arn`), matching the
  cluster / org-registry modules' KMS handling.
- **Network isolation by default.** Modules read VPC + subnets via
  `data.terraform_remote_state.vpc` (same convention as the EKS
  cluster + managed-node-group modules). No public endpoints by
  default; gated behind an opt-in `var.publicly_accessible` toggle.

### Non-Goals

- **Aurora Multi-Master (Multi-Writer) topology.** Out of scope.
  Single-writer-plus-replicas is the only topology supported.
  Multi-writer's consistency model + IAM surface diverges enough to
  warrant a separate module if/when needed.
- **Cross-region replicas.** Out of scope for v1. The read-replica
  module attaches to the same-region cluster. Cross-region requires
  `aws_rds_global_cluster` plus a different remote-state shape.
- **RDS Proxy.** Out of scope. The proxy lives at a different layer
  (consumer/IAM-mediated connection pooling); files as a follow-up
  module if/when needed.
- **Other engines.** Oracle, SQL Server, MariaDB, Aurora Postgres
  ML, Aurora Limitless out of scope for v1. Adding an engine is
  additive (variable validation + parameter-family lookup); deferred
  until a concrete consumer.
- **Schema migrations.** Modules manage the database server; schema
  management (Flyway / Liquibase / Atlas / Prisma) is delivery-layer
  out-of-band (same posture as
  [ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md)
  for Kubernetes manifests).
- **Backup verification / restore drills.** AWS-side backups +
  retention are configured by the module; periodic restore-into-
  fresh-cluster drills are an operational workstream, not module
  code.
- **Per-engine PITR + snapshot lifecycle as data-API objects.** AWS
  manages snapshot lifecycle natively (`backup_retention_period`,
  `delete_automated_backups`, `final_snapshot_identifier`); no need
  for a parallel module surface.

## Background

The fleet currently provides EKS + ECR coverage; the immediate next
gap is the data tier. Most workloads in the parent org's roadmap
need either:

- A small Postgres / MySQL **single instance** for stateful
  prototypes or low-volume services (cheap, single-AZ acceptable).
- An **Aurora cluster** for production workloads that need
  high availability and read scaling — defaults to single-instance
  writer (cost), with read replicas added as separate Terraform
  plans only when load justifies them.
- **Aurora Serverless v2** for workloads with bursty / unpredictable
  load where compute should scale to a configured floor/ceiling
  range (e.g., dev environments, internal tools).

These three concerns have meaningfully different cost / topology /
operational profiles, but they overlap enough on inputs (VPC,
subnets, KMS, security group, parameter group) that they should
share scaffolding and remote-state composition conventions.

Provider-side, all four modules sit on `hashicorp/aws ~> 6.2`
(fleet pin); none need provider features beyond what's available in
v6.45.0.

## Detailed Design

### Module decomposition

```text
modules/
└── rds/
    ├── instance/        — single aws_db_instance (Postgres / MySQL)
    ├── cluster/         — Aurora provisioned, single-writer default
    ├── read-replica/    — additional aws_rds_cluster_instance(s),
    │                     consuming cluster module's remote state
    └── serverless/      — Aurora Serverless v2
```

Each module:

- Pins `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`.
- Carries its own scaffolding (`.terraform-docs.yml`, `.tflint.hcl`,
  `README.md` stub, generated `USAGE.md`).
- Tested with `terraform test` plan-only suite in `tests/`
  (per [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md)).
- Opt-in `tests-localstack/` apply suite per RFC-0001 gap-discovery
  pattern.

### Shared scaffolding

- **Engine input contract** (per module): `var.engine` =
  `"postgres" | "mysql" | "aurora-postgresql" | "aurora-mysql"`,
  validated to the subset that the specific module supports
  (instance: `postgres` / `mysql`; cluster + read-replica +
  serverless: `aurora-postgresql` / `aurora-mysql`).
  `var.engine_version` is an optional caller-pinned value (defaults
  to AWS's "default for this engine" if null — verify at
  implementation time whether v6 provider exposes this as
  `data.aws_rds_engine_version`).
- **Parameter family resolution.** Each engine has a default
  parameter family (`postgres16`, `mysql8.4`, `aurora-postgresql16`,
  `aurora-mysql8.0`) that the module resolves from `var.engine` +
  `var.engine_version` via a static map in `locals.tf`. Operators
  override via `var.parameter_family` for engine-minor pinning.
- **KMS key handling.** Module-managed `aws_kms_key` +
  `aws_kms_alias` count-gated on `var.kms_key_arn == null`. Same
  pattern as `modules/eks/cluster` and `modules/ecr/org-registry`.
- **Network composition.** All four modules read VPC + subnets via
  `data.terraform_remote_state.vpc` (S3 backend, `use_path_style =
  true` for LocalStack compatibility). Inputs:
  `var.remote_state_bucket`, `var.region`, `var.vpc_name`.
  Expected remote-state outputs from the VPC stack:
  `database_subnet_ids`, `vpc_id`, `vpc_cidr_block`.
- **Subnet group.** Each module (except read-replica) emits an
  `aws_db_subnet_group` over the VPC's `database_subnet_ids`.
  Read-replica reuses the cluster's existing subnet group.
- **Security group.** Each module (except read-replica) emits an
  `aws_security_group` for the DB tier with ingress rules limited
  to peer consumer SGs (passed in as `var.allowed_consumer_sg_ids`).
  Read-replica reuses the cluster's SG.
- **Credentials.** All four modules use AWS RDS managed master-user
  password (`manage_master_user_password = true`) by default
  (per Q2 resolution) — AWS provisions and rotates the password in
  Secrets Manager; consumers read the secret ARN via the module
  output. Opt-out available via
  `var.manage_master_user_password = false` (then the operator
  wires their own secret as the documented escape hatch).
- **IAM database authentication (opt-in).** Per Q5 resolution,
  each module exposes
  `var.iam_database_authentication_enabled` (default `false`).
  When true, IAM auth is enabled on the engine and consumers can
  obtain a connection token via `aws rds generate-db-auth-token`.
  This is composable with the SG ingress gate, not a replacement.
- **Backups.** `backup_retention_period` default 7 days,
  `backup_window` default `"02:00-03:00"` (UTC); both override-able.
- **Storage encryption.** `storage_encrypted = true`,
  `kms_key_id = local.kms_key_arn` (module-managed or BYO).
- **Deletion safety.** `deletion_protection = true` by default —
  matches the org-registry module's `prevent_destroy` KMS posture.
  `skip_final_snapshot = false` by default; final snapshot name
  derived from `var.identifier_prefix` + timestamp suffix.

### Cross-module composition: remote state

- **Cluster module is the source-of-truth state file.** Its
  outputs are the consumer contract for `read-replica` (and any
  future RDS-adjacent module like a proxy module). The cluster
  state key follows the fleet convention:

  ```text
  ${var.region}/rds/cluster/${var.cluster_identifier}/terraform.tfstate
  ```

- **`read-replica` reads the cluster's state** via
  `data.terraform_remote_state.rds_cluster`:

  ```hcl
  data "terraform_remote_state" "rds_cluster" {
    backend = "s3"
    config = {
      bucket = var.remote_state_bucket
      key    = "${var.region}/rds/cluster/${var.cluster_identifier}/terraform.tfstate"
      region = var.region
    }
  }
  ```

  Required cluster outputs the read-replica consumes:
  `cluster_identifier`, `cluster_resource_id`, `engine`,
  `engine_version_actual`, `db_subnet_group_name`,
  `security_group_id`, `kms_key_id`.

- **`instance` and `serverless`** read no other-module remote state —
  they're standalone source modules. Consumers (apps, IAM roles)
  read THEIR remote state, same convention.

### `modules/rds/instance` — single RDS instance

For workloads that don't need Aurora (cost-sensitive, low traffic,
prototypes, single-AZ tolerance).

**Resources:**

- `aws_db_subnet_group.this` over the VPC's `database_subnet_ids`.
- `aws_security_group.this` (DB tier) with ingress on the engine's
  default port from `var.allowed_consumer_sg_ids`.
- `aws_kms_key.this[0]` + `aws_kms_alias.this[0]` (count-gated on
  `var.kms_key_arn == null`).
- `aws_db_parameter_group.this` for the resolved parameter family.
- `aws_db_instance.this` with:
  - `engine` / `engine_version` / `instance_class` /
    `allocated_storage` from inputs.
  - `db_subnet_group_name = aws_db_subnet_group.this.name`.
  - `vpc_security_group_ids = [aws_security_group.this.id]`.
  - `parameter_group_name = aws_db_parameter_group.this.name`.
  - `storage_encrypted = true`, `kms_key_id = local.kms_key_arn`.
  - `manage_master_user_password = true`.
  - `multi_az = var.multi_az` (default `false` — operators opt in).
  - `publicly_accessible = false` (default), `deletion_protection
    = true` (default).
  - `apply_immediately = false` (default — apply in next maintenance
    window unless overridden).
  - `final_snapshot_identifier = "${var.identifier_prefix}-final-${formatdate("YYYYMMDD-hhmmss", timestamp())}"`
    — caveat: `timestamp()` re-evaluates each plan; pinning the
    snapshot name to apply-time only via a `lifecycle.ignore_changes`
    on that attribute keeps plans clean.

**Outputs:**

- `instance_identifier`, `endpoint`, `port`, `address`,
  `master_user_secret_arn` (the AWS-managed secret), `kms_key_arn`,
  `security_group_id`, `db_subnet_group_name`.

### `modules/rds/cluster` — Aurora provisioned cluster

For production workloads needing HA + read scaling. Defaults to
single-instance writer; read-replica module attaches additional
instances as separate Terraform plans.

**Resources:**

- `aws_db_subnet_group.this` (same as instance module).
- `aws_security_group.this` (same).
- `aws_kms_key.this[0]` + alias (same gating).
- `aws_rds_cluster_parameter_group.this` for the resolved Aurora
  family.
- `aws_db_parameter_group.this` (for cluster instances).
- `aws_rds_cluster.this` with:
  - `engine` = `aurora-postgresql` or `aurora-mysql`.
  - `engine_mode = "provisioned"`.
  - `db_subnet_group_name`, `vpc_security_group_ids`,
    `db_cluster_parameter_group_name`, `storage_encrypted`,
    `kms_key_id`, `manage_master_user_password` (same as instance).
  - `backup_retention_period`, `preferred_backup_window`,
    `preferred_maintenance_window`.
  - `deletion_protection = true`, `skip_final_snapshot = false`,
    `final_snapshot_identifier` (same pattern as instance).
- `aws_rds_cluster_instance.writer` (single instance; the writer
  in a single-writer topology):
  - `cluster_identifier = aws_rds_cluster.this.id`.
  - `instance_class = var.instance_class`.
  - `engine = aws_rds_cluster.this.engine`.
  - `engine_version = aws_rds_cluster.this.engine_version`.
  - `db_parameter_group_name = aws_db_parameter_group.this.name`.
  - `publicly_accessible = false`.
  - `apply_immediately = false`.

**Outputs (consumer contract for `read-replica`):**

- `cluster_identifier`, `cluster_resource_id`,
  `cluster_endpoint`, `reader_endpoint`, `port`,
  `engine`, `engine_version_actual`,
  `db_subnet_group_name`, `security_group_id`,
  `kms_key_id`, `db_parameter_group_name`,
  `master_user_secret_arn`.

### `modules/rds/read-replica` — Aurora cluster instance attached via remote state

Each invocation adds one or more `aws_rds_cluster_instance` resources
to an existing Aurora cluster. Consumers spin up one of these per
read-scale-out event.

**Inputs:**

- `remote_state_bucket`, `region`, `cluster_identifier` —
  composing the cluster's remote-state key.
- `replicas` (`map(object({ instance_class = string,
  availability_zone = optional(string) }))`) — per Q1 resolution:
  one entry per replica, keyed by stable identifier suffix. Single
  replica is a one-entry map; preserves identity across additions
  / removals.
- `identifier_prefix` (`string`) — names compose as
  `<identifier_prefix>-replica-<map-key>`.
- `apply_immediately` (`bool`, default `false`).
- `tags`.

**Resources:**

- `data.terraform_remote_state.rds_cluster` reading the cluster's
  state.
- `aws_rds_cluster_instance.replica` with
  `for_each = var.replicas` (per Q1 resolution — keyed by stable
  identifier, removing replica #1 of N doesn't renumber the rest).
  - `cluster_identifier = data.terraform_remote_state.rds_cluster.outputs.cluster_identifier`.
  - `engine`, `engine_version`, `db_parameter_group_name` all
    sourced from the cluster's remote-state outputs (single
    source of truth — replica engine drift is impossible by
    construction).
  - `instance_class = each.value.instance_class`.
  - `availability_zone = each.value.availability_zone` (null →
    Aurora auto-distributes).
  - `publicly_accessible = false`.

**Outputs:**

- `replica_identifiers` (map keyed the same as `var.replicas`),
  `replica_endpoints` (same shape).

**Why a separate module rather than `instance_count` on the cluster
module?** Three reasons:

1. **Blast radius.** Adding / removing replicas is a smaller, more
   frequent operation than cluster lifecycle changes. Separate
   Terraform state means each replica change is one plan, one
   apply, one targeted blast radius.
2. **Consumer ergonomics.** A team adding read scale can author
   their own read-replica module instantiation without touching
   the cluster's source code or its larger state file.
3. **Replica diversity.** Different consumers may want different
   `instance_class` / parameter group / AZ pinning per replica
   pool. A separate module per replica pool is the natural
   factoring.

### `modules/rds/serverless` — Aurora Serverless v2

For workloads with bursty load where compute should scale to a
configured floor/ceiling range.

**Resources:**

- Same scaffolding as cluster (subnet group, security group, KMS,
  parameter groups).
- `aws_rds_cluster.this`:
  - `engine_mode = "provisioned"` — Serverless v2 uses the
    provisioned engine_mode with a serverless scaling
    configuration (NOT `engine_mode = "serverless"`, which is v1
    and on a deprecation path).
  - `serverlessv2_scaling_configuration {
    min_capacity = var.min_acu;
    max_capacity = var.max_acu; }`.
  - `engine` = `aurora-postgresql` or `aurora-mysql`.
- `aws_rds_cluster_instance.this` (single instance — Aurora
  Serverless v2 requires at least one cluster instance):
  - `instance_class = "db.serverless"` (the special instance
    class that signals Serverless v2 compute).
  - Other attrs same as cluster module's writer.

**Outputs:** same shape as cluster module — `cluster_identifier`,
endpoints, port, etc. — so the same downstream consumer pattern
applies.

### Engine matrix

| Module | postgres | mysql | aurora-postgresql | aurora-mysql |
|--------|:--------:|:-----:|:-----------------:|:------------:|
| `instance` | ✓ | ✓ | ✗ | ✗ |
| `cluster` | ✗ | ✗ | ✓ | ✓ |
| `read-replica` | ✗ | ✗ | ✓ (inherited) | ✓ (inherited) |
| `serverless` | ✗ | ✗ | ✓ | ✓ |

Engine versions pinned via Renovate against the engine's
`PARAMETER_FAMILY` regex (e.g., `^postgres1[5-9]$`,
`^aurora-postgresql1[5-9]$`). Engine-minor bumps are
in-place-apply-safe for RDS; engine-major bumps trigger a
maintenance-window apply and warrant a deliberate operator PR.

## API / Interface Changes

This is a greenfield set of modules. Every consumer is new.

### Input surface (per module, common subset)

| Input | Type | Required? | Default |
|-------|------|-----------|---------|
| `region` | string | yes | — |
| `remote_state_bucket` | string | yes (instance / cluster / serverless / read-replica) | — |
| `vpc_name` | string | yes (instance / cluster / serverless) | — |
| `cluster_identifier` | string | yes (read-replica only — and is the cluster's stable id) | — |
| `identifier_prefix` | string | yes | — |
| `engine` | string | yes | — |
| `engine_version` | string | no | null (use engine default) |
| `instance_class` | string | yes (instance / cluster / read-replica) | — |
| `allocated_storage` | number | yes (instance only) | — |
| `multi_az` | bool | no | false (instance only) |
| `kms_key_arn` | string | no | null (module-managed) |
| `allowed_consumer_sg_ids` | list(string) | no | [] |
| `iam_database_authentication_enabled` | bool | no | false (per Q5) |
| `manage_master_user_password` | bool | no | true |
| `master_username` | string | no | "postgres" or "admin" (per engine) |
| `backup_retention_period` | number | no | 7 |
| `deletion_protection` | bool | no | true |
| `publicly_accessible` | bool | no | false |
| `apply_immediately` | bool | no | false |
| `parameter_family` | string | no | resolved from engine + version |
| `min_acu` / `max_acu` | number | yes (serverless only) | — |
| `replicas` | map(object) | yes (read-replica only) | — — per Q1 resolution |
| `tags` | map(string) | no | {} |

### Output surface (per module, common subset)

Cluster + serverless emit the cluster-shaped contract; instance
emits the instance-shaped contract; read-replica emits a list of
replica identifiers and endpoints.

## Data Model

No application schema; the modules manage RDS engine + storage +
network configuration. The "data" being modeled is the RDS API
surface plus its dependencies (VPC subnets, security groups, KMS).

Master credentials are AWS-managed Secrets Manager secrets
(`manage_master_user_password = true`) by default — the secret ARN
is emitted as a module output. Schema-management secrets (app users,
roles, GRANTs) are out of scope per Non-Goals.

## Testing Strategy

Per [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md):

- **`terraform test` plan-only suite** (`tests/`) per module:
  - Default-shape resource counts (engine variants: postgres, mysql
    for `instance`; aurora-postgresql, aurora-mysql for the three
    Aurora modules).
  - BYO KMS shape — zero module-managed KMS resources; references
    flow to the BYO ARN.
  - Validation negatives — bad engine, bad multi_az on serverless
    (Serverless v2 has no concept of multi_az), bad engine_version
    format, bad min/max ACU ordering (`min > max`).
  - Parameter family resolution — given engine X + version Y, the
    expected family Z is selected from the static map.
  - Read-replica suite: stub the cluster's remote-state outputs
    via `override_data` and assert each replica's
    `cluster_identifier` resolves correctly; assert
    `engine_version_actual` flows through unmodified.
- **`tests-localstack` apply suite** (opt-in) per module:
  - **Default tier: LocalStack Community.** Pro is also supported
    and well-covered (per Q7 resolution). RDS is broadly
    implemented in Community; Aurora-specific endpoints get the
    same coverage on Pro. Suites are tier-agnostic by construction
    — no test gates on edition.
  - LocalStack supports RDS (`aws_db_instance`,
    `aws_rds_cluster`, `aws_rds_cluster_instance`,
    `aws_db_subnet_group`, `aws_db_parameter_group`,
    `aws_rds_cluster_parameter_group`) — gap-discovery probe
    confirms at implementation time. If any API 501s, follow the
    IMPL-0005 Phase 9 pattern (comment out the apply, document the
    gap in `FINDINGS.md`, fall back to `plan_smoke`).
  - `data.terraform_remote_state.vpc` is fed via the existing
    test fixture pattern (stub S3 bucket with handcrafted state
    file — same approach as `modules/eks/managed-node-group`'s
    `tests-localstack/`).
- **Post-apply smoke (operator workflow, not CI):** `psql` or
  `mysql` connect through the cluster endpoint with the
  AWS-managed password from Secrets Manager. README documents the
  recipe per module.

## Migration / Rollout Plan

Greenfield modules; no existing consumers. Rollout order:

1. **`modules/rds/serverless`** first — Aurora Serverless v2 is the
   most common starting workload (dev environments, bursty internal
   tools, prototypes). Establishes the Aurora parameter-family
   lookups + KMS handling + AWS-managed master password pattern
   that the other Aurora modules reuse.
2. **`modules/rds/instance`** second — standalone single
   `aws_db_instance` for cost-sensitive Postgres / MySQL workloads.
   Reuses the parameter-family + KMS + Secrets-Manager scaffolding
   from `serverless` but on the non-clustered AWS surface
   (`aws_db_instance` instead of `aws_rds_cluster`).
3. **`modules/rds/cluster`** third — Aurora provisioned, single-
   writer default. Establishes the remote-state contract that
   `read-replica` depends on. Lands once `serverless` has battle-
   tested the Aurora cluster scaffolding.
4. **`modules/rds/read-replica`** fourth — depends on `cluster`'s
   remote-state contract being pinned (must merge AFTER `cluster`).

Each module gets its own IMPL doc + feature branch + PR (same
cadence as IMPL-0001 through IMPL-0006).

## Open Questions

All seven questions resolved 2026-05-27 and folded into the
relevant sections above.

### Q1 — `count` vs `for_each` on `read-replica` instances — RESOLVED (`for_each`)

**Resolved:** `for_each` over a typed object map
(`map(object({ instance_class = string, availability_zone =
optional(string) }))`); a single replica is a one-entry map. Match
the `for_each`-over-named-keys pattern used by the
managed-node-group module. Preserves identity across additions /
removals — removing replica #1 of N doesn't renumber the others.
Read-replica module section above + the inputs table reflect this.

### Q2 — RDS-managed master password vs caller-managed Secrets Manager — RESOLVED (AWS-managed default)

**Resolved:** default `manage_master_user_password = true` —
AWS provisions and rotates the password in Secrets Manager;
consumers read the secret ARN via the module output
(`master_user_secret_arn`). Cheapest operational surface; matches
the Secrets-Manager-first posture of the pull-through-cache
module. Opt-out (`manage_master_user_password = false`) is a
documented escape hatch for operators migrating from a pre-
existing secret — adds `password` + `secret_arn` inputs and a
documented bootstrap dance but is not the default code path.

### Q3 — Parameter family resolution: static map vs data source — RESOLVED (static map)

**Resolved:** static `locals.tf` map from `(engine, major_version)`
to `parameter_family` for v1. Engine-family drift is rare (about
once a year per engine) and shows up as a Renovate PR bumping the
map. A small inline TODO comment in `locals.tf` points at the
data-source-driven alternative
(`data.aws_rds_engine_version`) for future revisit if drift
becomes painful.

### Q4 — Engine version pinning strategy — RESOLVED (optional + auto-minor on)

**Resolved:** `var.engine_version` is optional (default `null` →
use AWS default for the engine);
`auto_minor_version_upgrade` defaults `true` (matches AWS
posture). Engine-major upgrades are explicit operator PRs bumping
`var.engine_version`. Renovate is configured to PR engine-major
bumps on a slow cadence (manual review required); minor upgrades
flow through AWS's maintenance window without Terraform churn.

### Q5 — Connectivity contract — RESOLVED (SG-source-list, IAM auth opt-in)

**Resolved:** `var.allowed_consumer_sg_ids` is the v1 connectivity
contract — same pattern as the EKS node-SG ingress rules. IAM
database authentication is opt-in via
`var.iam_database_authentication_enabled` (default `false`); when
true, it adds an authentication layer rather than replacing the
SG gate. The two are composable: SG limits *reachability*, IAM
limits *authentication* once reached.

### Q6 — Cross-instance read replicas on `modules/rds/instance` — RESOLVED (separate module, deferred)

**Resolved:** path (b) — when a consumer needs cross-instance read
replicas for the non-Aurora `instance` module, a separate
`modules/rds/instance-replica` module ships alongside it (symmetric
with `modules/rds/read-replica` on the Aurora side). Keeps the
`instance` module's input surface clean. Deferred to a follow-up
DESIGN if/when a consumer materializes — not v1 scope.

### Q7 — `tests-localstack` tier handling — RESOLVED (Community default, Pro also supported)

**Resolved:** LocalStack Community is the default test tier for
the RDS modules. Pro is also supported and well-covered for RDS —
the test suites should pass identically on either tier (RDS is
broadly implemented in Community; Aurora-specific endpoints get
the same coverage on Pro). The `tests-localstack/` suites are
**tier-agnostic by construction**: no test gates on edition.
[INV-0002](../investigation/0002-fleet-wide-localstack-pro-auto-detection-harness-for-tests.md)
remains relevant for the fleet but is not load-bearing for these
modules.

Implementation-time verification step: during IMPL of the first
module (per the Rollout Plan, `modules/rds/serverless`), probe
both tiers; if any API 501s differentially, document in that
module's `FINDINGS.md` and revisit this resolution.

## References

- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state` (drives the cluster ↔ read-replica composition).
- [ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md) — Terraform manages AWS API resources only; schema migrations are delivered out-of-band (mentioned under Non-Goals).
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants.
- [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md) — libtftest for apply-time runtime validation.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module Testing Strategy.
- [DESIGN-0002](0002-eks-cluster-module.md) — EKS cluster module shape (precedent for KMS handling + SG + remote-state composition).
- [DESIGN-0006](0006-org-wide-ecr-oci-artifact-registry.md) — Org-wide ECR OCI artifact registry (precedent for `prevent_destroy` KMS handling + opt-in resource emission).
- [INV-0002](../investigation/0002-fleet-wide-localstack-pro-auto-detection-harness-for-tests.md) — Fleet-wide LocalStack Pro auto-detection harness (relevant to Q7).
- [Aurora Serverless v2 documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html).
- [`aws_rds_cluster` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster).
- [`aws_db_instance` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance).
