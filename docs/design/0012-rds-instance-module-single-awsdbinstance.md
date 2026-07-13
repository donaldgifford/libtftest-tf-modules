---
id: DESIGN-0012
title: "RDS instance module (single aws_db_instance)"
status: Implemented
author: Donald Gifford
created: 2026-07-09
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0012: RDS instance module (single aws_db_instance)

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
  - [Module file layout](#module-file-layout)
  - [Inherited scaffolding (unchanged from serverless)](#inherited-scaffolding-unchanged-from-serverless)
  - [What differs: the non-Aurora storage + instance surface](#what-differs-the-non-aurora-storage--instance-surface)
  - [Engine + parameter-family resolution](#engine--parameter-family-resolution)
  - [Resources](#resources)
  - [The RDS-Proxy composition output contract](#the-rds-proxy-composition-output-contract)
  - [Validation surface](#validation-surface)
- [API / Interface Changes](#api--interface-changes)
  - [Input surface](#input-surface)
  - [Output surface](#output-surface)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [Q1 — Instance class and storage sizing: required or defaulted? — RESOLVED (a)](#q1--instance-class-and-storage-sizing-required-or-defaulted--resolved-a)
  - [Q2 — Default storage type — RESOLVED (a)](#q2--default-storage-type--resolved-a)
  - [Q3 — Storage autoscaling default — RESOLVED (a)](#q3--storage-autoscaling-default--resolved-a)
  - [Q4 — Multi-AZ default — RESOLVED (a)](#q4--multi-az-default--resolved-a)
  - [Q5 — Non-Aurora read replicas — RESOLVED (a)](#q5--non-aurora-read-replicas--resolved-a)
  - [Q6 — CA certificate identifier handling — RESOLVED (a)](#q6--ca-certificate-identifier-handling--resolved-a)
  - [Q7 — Blue/Green deployment support — RESOLVED (a)](#q7--bluegreen-deployment-support--resolved-a)
  - [Q8 — Default engine majors in the parameter-family map — RESOLVED (b)](#q8--default-engine-majors-in-the-parameter-family-map--resolved-b)
- [References](#references)
<!--toc:end-->

## Overview

`modules/rds/instance` is a single, non-clustered `aws_db_instance` for
Postgres or MySQL workloads that don't need Aurora — cost-sensitive
services, stateful prototypes, and low-volume internal tools where a
single-AZ (or optionally Multi-AZ) instance is the right shape. It is the
second module in the RDS family laid out in
[DESIGN-0007](0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md),
sitting alongside the already-shipped `serverless`
([IMPL-0007](../impl/0007-aurora-serverless-v2-module-implementation.md)) and
`proxy` ([IMPL-0010](../impl/0010-rds-proxy-module-implementation.md)) modules.

This doc pins the module's resource graph, input/output surface, and test
plan to the **as-built conventions** the `serverless` module established
(not just the original DESIGN-0007 sketch), so an IMPL can proceed without
re-litigating scaffolding. The open decisions specific to a single instance
— storage autoscaling, `storage_type`, Multi-AZ, non-Aurora read replicas —
are collected in [Open Questions](#open-questions) for review.

## Goals and Non-Goals

### Goals

- **A from-scratch single-instance RDS module** for `postgres` and `mysql`,
  matching the fleet's per-AWS-API-surface decomposition (no
  `terraform-aws-modules/*` wrapping).
- **Reuse the `serverless` scaffolding verbatim** where it applies: VPC
  remote-state read, module-managed-or-BYO KMS, granular security-group
  rules, AWS-managed master password, parameter-family lookup, the
  validation-split doctrine (variable-validation vs `lifecycle.precondition`).
- **Be a valid RDS Proxy target.** The module emits the same seven
  remote-state outputs the `proxy` module reads for `target_type =
  "rds-instance"` (see [DESIGN-0010](0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md)),
  including the four proxy-composition outputs already present on
  `serverless`.
- **Encryption-at-rest and network isolation on by default** — module-managed
  KMS key (BYO-able), private subnets from the VPC remote state, no public
  endpoint unless explicitly opted in.
- **Storage that can grow.** Single instances (unlike Aurora) have a
  fixed `allocated_storage` that can run out; the module makes storage
  autoscaling a first-class, opt-in capability (see Q3).

### Non-Goals

- **Aurora.** Clustered engines are the `cluster` / `serverless` /
  `read-replica` modules' concern. `instance` is `aws_db_instance` only.
- **Non-Aurora read replicas in this module.** Cross-instance read replicas
  (`replicate_source_db`) are deferred to a separate `instance-replica`
  module per DESIGN-0007 Q6 — revisited in Q5 now that we're building.
- **Schema migrations / app users / GRANTs.** Out of band
  ([ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md)).
- **Other engines.** Oracle, SQL Server, MariaDB, Db2 out of scope for v1;
  adding one is additive (engine validation + parameter-family map entry).
- **Backup verification / restore drills.** AWS-side backups are configured;
  restore drills are an operational workstream, not module code.

## Background

The `serverless` module (IMPL-0007) established every cross-cutting pattern
this module reuses, so the "how" is settled — this design is mostly about the
`aws_db_instance`-specific surface that has no Aurora analogue:
`allocated_storage`, `max_allocated_storage` (storage autoscaling),
`storage_type` / `iops` / `storage_throughput`, and `multi_az`. Aurora
abstracts storage away (it grows automatically, billed per GB-month), so
none of these appear in the `serverless` or `cluster` modules; `instance`
has to model them deliberately.

The rollout order in DESIGN-0007 put `instance` second (after `serverless`,
before `cluster`). That still holds: `instance` reuses the serverless
scaffolding on the simpler non-clustered API and does not block on the
cluster ↔ read-replica remote-state contract.

Provider baseline is unchanged from the rest of the family: `hashicorp/aws
~> 6.2`, Terraform `>= 1.1` (the `>= 1.1` pin is why cross-variable checks
live in `lifecycle.precondition` rather than `variable.validation`).

## Detailed Design

### Position in the RDS module family

```text
modules/rds/
├── instance/      ← THIS MODULE — single aws_db_instance (postgres / mysql)
├── cluster/       — Aurora provisioned (DESIGN-0013)
├── read-replica/  — Aurora reader instances via remote state (DESIGN-0014)
└── serverless/    — Aurora Serverless v2 (shipped, IMPL-0007)
```

`instance` is a **source-of-truth state file**, like `serverless`: it reads
no other module's remote state (only the VPC stack's), and its own outputs
are the consumer contract — including as an RDS Proxy target keyed
`${region}/rds/instance/${identifier}/terraform.tfstate` (the key the proxy
module composes for `target_type = "rds-instance"`).

### Module file layout

Mirror the `serverless` split exactly (the VPC remote-state data source lives
in `main.tf`, networking resources in `network.tf`):

```text
modules/rds/instance/
├── versions.tf          — required_version >= 1.1, aws ~> 6.2
├── variables.tf         — Required inputs / Optional inputs banners
├── locals.tf            — kms_key_arn coalesce, parameter-family + port maps
├── kms.tf               — count-gated aws_kms_key + alias (prevent_destroy)
├── main.tf              — data.terraform_remote_state.vpc
├── network.tf           — aws_db_subnet_group + aws_security_group + rules
├── parameter_groups.tf  — aws_db_parameter_group (NO cluster param group)
├── instance.tf          — aws_db_instance.this + preconditions
├── outputs.tf           — instance contract + 4 proxy-composition outputs
├── README.md            — operator guidance stub
├── USAGE.md             — terraform-docs generated
├── tests/               — plan-only gate
└── tests-localstack/    — apply suite (+ FINDINGS.md, fixtures/setup)
```

### Inherited scaffolding (unchanged from serverless)

The following carry over **verbatim** (swapping the `-rds-serverless`
name suffix for `-rds-instance`):

- **VPC remote state** (`main.tf`): `data.terraform_remote_state.vpc`,
  backend `s3`, key `${var.region}/vpc/${var.vpc_name}/terraform.tfstate`,
  `use_path_style = true`. Consumes `outputs.vpc_id` and
  `outputs.private_subnet_ids` (the EKS-cluster contract — **not**
  `database_subnet_ids` as the DESIGN-0007 draft said).
- **KMS** (`kms.tf`): `count = var.kms_key_arn == null ? 1 : 0` on both
  `aws_kms_key.this` and `aws_kms_alias.this`; `enable_key_rotation = true`,
  `deletion_window_in_days = 30`, `lifecycle { prevent_destroy = true }` on
  the key; alias `alias/${var.identifier_prefix}-rds-instance`.
- **KMS resolution** (`locals.tf`):
  `kms_key_arn = coalesce(var.kms_key_arn, try(aws_kms_key.this[0].arn, null))`.
- **Networking** (`network.tf`): `aws_db_subnet_group.this` over
  `private_subnet_ids`; `aws_security_group.this`; one
  `aws_vpc_security_group_ingress_rule.consumer` per
  `var.allowed_consumer_sg_ids` (`for_each = toset(...)`,
  `referenced_security_group_id = each.value`, from/to port =
  `local.engine_default_port`, `ip_protocol = "tcp"`); one all-outbound
  `aws_vpc_security_group_egress_rule.all` (`0.0.0.0/0`, `-1`).
- **Credentials**: `manage_master_user_password = true` by default;
  `master_username` defaults to a flat `"admin"` (the serverless module's
  IMPL-0007 Q4 resolution — a single default, not per-engine). AWS provisions
  and rotates the secret; the ARN is a module output.
- **IAM database auth**: `var.iam_database_authentication_enabled` (default
  `false`), composable with the SG gate.

### What differs: the non-Aurora storage + instance surface

`aws_db_instance` has a fixed storage allocation and single-node topology,
so the module adds inputs that have no Aurora equivalent:

- **`allocated_storage`** (GB) — the initial storage size. Required or
  defaulted? See Q1.
- **`max_allocated_storage`** (GB) — enables RDS storage autoscaling when
  `> allocated_storage`; AWS grows storage up to this ceiling automatically.
  Default behaviour is the subject of Q3. When set, the module adds
  `lifecycle { ignore_changes = [allocated_storage] }` so AWS-driven growth
  doesn't show as perpetual drift.
- **`storage_type`** (`gp3` / `gp2` / `io2`) and, for `io2`/`gp3`-above-
  threshold, **`iops`** and **`storage_throughput`**. Default in Q2.
- **`multi_az`** (bool) — synchronous standby in a second AZ. Default in Q4.
- **`instance_class`** — required or defaulted (Q1). No `db.serverless`
  here; a concrete class like `db.t4g.micro` / `db.m6g.large`.
- **`port`** — optional override, defaulting to `local.engine_default_port`
  (5432 / 3306).
- **`ca_cert_identifier`** — the RDS CA bundle for the server cert (Q6).

### Engine + parameter-family resolution

Identical mechanism to `serverless`, but for the non-Aurora engines and a
plain `aws_db_parameter_group` (no cluster parameter group):

```hcl
# locals.tf (illustrative)
parameter_family_map = {
  "postgres:18" = "postgres18"
  "postgres:17" = "postgres17"
  "postgres:16" = "postgres16"
  "mysql:8.4"   = "mysql8.4"
  "mysql:8.0"   = "mysql8.0"
}

default_major_map = {
  "postgres" = "18"   # Q8-b: newest GA major
  "mysql"    = "8.4"  # Q8-b: newest GA major
}

engine_default_port_map = {
  "postgres" = 5432
  "mysql"    = 3306
}
```

`engine` is validated to `^(postgres|mysql)$`. `engine_version` is optional
(`null` → AWS default for the engine); when set, it is normalised to the
major (`split(".", …)[0]` for postgres) to key the family map. An
unresolvable family surfaces as a `lifecycle.precondition` failure on
`aws_db_instance.this` with a clear "set `var.parameter_family` or extend the
map" message — same as the serverless cluster precondition.

### Resources

- `aws_db_subnet_group.this` — over `private_subnet_ids`.
- `aws_security_group.this` + granular ingress/egress rules.
- `aws_kms_key.this[0]` + `aws_kms_alias.this[0]` (count-gated).
- `aws_db_parameter_group.this` — `name_prefix = "${var.identifier_prefix}-"`,
  `family = local.resolved_parameter_family`, `lifecycle {
  create_before_destroy = true }`.
- `aws_db_instance.this` — the load-bearing resource:
  - `identifier = var.identifier_prefix`.
  - `engine`, `engine_version`, `instance_class`, `allocated_storage`,
    `max_allocated_storage`, `storage_type`, `iops`, `storage_throughput`.
  - `db_subnet_group_name = aws_db_subnet_group.this.name`.
  - `vpc_security_group_ids = [aws_security_group.this.id]`.
  - `parameter_group_name = aws_db_parameter_group.this.name`.
  - `port = local.engine_default_port` (or `var.db_port`).
  - `db_name = var.database_name`.
  - `storage_encrypted = true`, `kms_key_id = local.kms_key_arn`.
  - `manage_master_user_password = var.manage_master_user_password`,
    `master_username = var.master_username`,
    `master_user_secret_kms_key_id = local.kms_key_arn`.
  - `iam_database_authentication_enabled`.
  - `multi_az`, `publicly_accessible` (default `false`),
    `deletion_protection` (default `true`), `apply_immediately` (default
    `false`), `auto_minor_version_upgrade` (default `true`).
  - `backup_retention_period`, `backup_window`, `maintenance_window`.
  - `skip_final_snapshot` (default `false`), `final_snapshot_identifier`.
  - `ca_cert_identifier` (Q6), `performance_insights_enabled` +
    `performance_insights_kms_key_id`, `monitoring_interval` +
    `monitoring_role_arn` (enhanced monitoring, same opt-in pattern).
  - `lifecycle`: preconditions (see below) plus `ignore_changes =
    [allocated_storage]` when autoscaling is active.

### The RDS-Proxy composition output contract

The `proxy` module reads exactly seven outputs from a target's remote state
(DESIGN-0010 / IMPL-0010 Phase 2). The `serverless` module emits all seven;
`instance` **must** emit the same names with the instance-resource
equivalents:

```hcl
output "master_user_secret_arn" {
  value = try(aws_db_instance.this.master_user_secret[0].secret_arn, null)
}
output "master_user_secret_kms_key_arn" {
  value = try(aws_db_instance.this.master_user_secret[0].kms_key_id, null)
}
output "security_group_id" { value = aws_security_group.this.id }
output "db_subnet_ids"     { value = aws_db_subnet_group.this.subnet_ids }
output "vpc_id"            { value = aws_security_group.this.vpc_id }
output "engine"           { value = aws_db_instance.this.engine }
output "iam_database_authentication_enabled" {
  value = aws_db_instance.this.iam_database_authentication_enabled
}
```

Note the deliberate expression choices copied from `serverless`: `vpc_id`
reads the SG resource attribute (not the remote-state value), and both
secret-derived outputs use `try(...master_user_secret[0]..., null)` so they
are null-safe when `manage_master_user_password = false`.

### Validation surface

Following the established doctrine — single-variable shape →
`variable.validation`; cross-variable or resolved-at-plan invariants →
`lifecycle.precondition` on `aws_db_instance.this`:

- **Variable validations**: `identifier_prefix` regex
  (`^[a-z][a-z0-9-]{0,61}[a-z0-9]$`); `engine` (`^(postgres|mysql)$`);
  `engine_version` (`^(\d+\.\d+|\d+)$` or null); `allowed_consumer_sg_ids`
  (each `^sg-[a-f0-9]+$`); `backup_retention_period` in `[1,35]`;
  `allocated_storage` ≥ 20 (AWS floor); `storage_type` in
  `["gp2","gp3","io2"]`; `enhanced_monitoring_interval` in
  `{0,1,5,10,15,30,60}`; `db_port` null or `[1,65535]`.
- **Preconditions** on `aws_db_instance.this`:
  `local.resolved_parameter_family != null`; `skip_final_snapshot ||
  final_snapshot_identifier != null`; `max_allocated_storage == 0 ||
  max_allocated_storage >= allocated_storage`; `enhanced_monitoring_interval
  == 0 || enhanced_monitoring_role_arn != null`; and (if Q2 lands on
  provisioned IOPS) `storage_type != "io2" || iops != null`.

## API / Interface Changes

Greenfield module; every consumer is new.

### Input surface

| Input | Type | Required? | Default |
|-------|------|-----------|---------|
| `region` | string | yes | — |
| `remote_state_bucket` | string | yes | — |
| `vpc_name` | string | yes | — |
| `identifier_prefix` | string | yes | — |
| `engine` | string | yes | — |
| `instance_class` | string | yes | — |
| `allocated_storage` | number | yes | — |
| `engine_version` | string | no | null (engine default) |
| `max_allocated_storage` | number | no | null (autoscaling off) |
| `storage_type` | string | no | "gp3" |
| `iops` | number | no | null |
| `storage_throughput` | number | no | null |
| `multi_az` | bool | no | false |
| `db_port` | number | no | null (engine default) |
| `database_name` | string | no | null |
| `kms_key_arn` | string | no | null (module-managed) |
| `allowed_consumer_sg_ids` | list(string) | no | [] |
| `iam_database_authentication_enabled` | bool | no | false |
| `manage_master_user_password` | bool | no | true |
| `master_username` | string | no | "admin" |
| `backup_retention_period` | number | no | 7 |
| `preferred_backup_window` | string | no | "02:00-03:00" |
| `preferred_maintenance_window` | string | no | "sun:04:00-sun:05:00" |
| `deletion_protection` | bool | no | true |
| `publicly_accessible` | bool | no | false |
| `apply_immediately` | bool | no | false |
| `auto_minor_version_upgrade` | bool | no | true |
| `parameter_family` | string | no | resolved |
| `ca_cert_identifier` | string | no | null (AWS default CA) |
| `final_snapshot_identifier` | string | no | null |
| `skip_final_snapshot` | bool | no | false |
| `performance_insights_enabled` | bool | no | false |
| `enhanced_monitoring_interval` | number | no | 0 |
| `enhanced_monitoring_role_arn` | string | no | null |
| `tags` | map(string) | no | {} |

### Output surface

Instance-shaped contract plus the four proxy-composition outputs:
`instance_identifier`, `endpoint`, `address`, `port`,
`master_user_secret_arn`, `kms_key_arn`, `security_group_id`,
`db_subnet_group_name`, `engine`, `engine_version_actual`,
`db_parameter_group_name`, and the composition set (`db_subnet_ids`,
`vpc_id`, `master_user_secret_kms_key_arn`,
`iam_database_authentication_enabled`).

## Data Model

No application schema. The module manages the RDS engine, storage, network,
and KMS. Master credentials are an AWS-managed Secrets Manager secret
(`manage_master_user_password = true`), encrypted with the same KMS key as
storage; the ARN is emitted as an output. App users / roles / GRANTs are out
of scope.

## Testing Strategy

Per [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md),
mirroring the serverless suites:

- **`tests/` plan-only gate** — fake provider (four `skip_*` flags),
  `override_data` stubbing `data.terraform_remote_state.vpc` (`vpc_id` +
  `private_subnet_ids`), BYO `kms_key_arn` so `local.kms_key_arn` is
  plan-known. Runs: default postgres + mysql shape; managed-KMS count
  (`kms_key_arn = null` → 1 key + 1 alias); BYO-KMS (0 KMS resources);
  parameter-family resolution (engine+version → family); SG ingress
  (2 consumers → 2 rules, empty → 0, mysql → 3306); storage autoscaling
  (`max_allocated_storage` set → `ignore_changes` + precondition passes);
  and a `validation.tftest.hcl` of `expect_failures` negatives (bad engine,
  bad `allocated_storage`, bad `storage_type`, inverted
  `max_allocated_storage`, snapshot-required, identifier shape,
  monitoring-role-required).
- **`tests-localstack/` apply suite** — a `setup` fixture (VPC + private
  subnets + S3 stub state) then `apply_default` provisioning the full
  single-instance stack; a `plan_mysql` for cheaper second-engine coverage.
  RDS `aws_db_instance` is broadly supported on LocalStack Community; the
  suite is **tier-agnostic** (no Pro-only surface here — unlike `proxy`, so
  **no `tests-localstack-pro/`**). Any 501 follows the IMPL-0005 Phase 9
  fall-back (comment the apply, document in `FINDINGS.md`, add `plan_smoke`).
- **macOS caveat** (same as serverless / proxy FINDINGS): the apply boots a
  real embedded Postgres, so `/var/lib/localstack` must be a Docker **named
  volume**, not the `lstk` default macOS bind mount, or `initdb` fails on
  data-dir ownership.

## Migration / Rollout Plan

Greenfield; no existing consumers. Ships as its own IMPL doc, feature branch,
and PR — second in the DESIGN-0007 order (after `serverless`, independent of
`cluster`/`read-replica`). Steps: scaffold from serverless → adapt to
`aws_db_instance` → plan-only tests green → LocalStack apply probe (+
FINDINGS) → `terraform-docs` USAGE → README table regen (`just readme`) →
mark this DESIGN Implemented.

## Open Questions

All eight questions were resolved 2026-07-09. Each heading records the chosen
option; the **Resolved** line states the decision, and the alternatives are
retained for the record.

### Q1 — Instance class and storage sizing: required or defaulted? — RESOLVED (a)

**Resolved: a.** Both `instance_class` and `allocated_storage` are required
with no default — sizing is workload-specific and cost-bearing. USAGE +
`terraform test` examples show a cheap starter (`db.t4g.micro`, 20 GB).

- **a (chosen):** Both **required, no default** — same posture as
  `serverless` requiring `min_acu`/`max_acu`. Sizing is workload-specific and
  cost-bearing; forcing an explicit choice avoids a surprise bill from a
  silent default. `terraform test` + USAGE examples show a cheap starter
  (`db.t4g.micro`, 20 GB).
- **b:** Default `instance_class = "db.t4g.micro"` and `allocated_storage =
  20` (cheapest viable) — fastest onboarding for prototypes, but risks
  under-provisioned prod instances.
- **c:** Require `instance_class`, default `allocated_storage = 20`
  (compromise — the storage floor is a safe AWS minimum, the class is not).
- **other:** ______

### Q2 — Default storage type — RESOLVED (a)

**Resolved: a.** Default `storage_type = "gp3"`, with `iops` /
`storage_throughput` as optional overrides (null → AWS baseline).

- **a (chosen):** Default **`gp3`** — decouples IOPS/throughput from
  size, cheaper than gp2 at scale, AWS's current recommendation. Expose
  `iops`/`storage_throughput` as optional overrides (null → AWS baseline).
- **b:** Default **`gp2`** — matches older AWS defaults; simpler (no
  iops/throughput knobs), but worse price/perf.
- **c:** Leave **`null`** and let AWS pick the account/engine default —
  minimal opinion, but the default has shifted over time (gp2 → gp3) and is
  non-obvious in plans.
- **d:** Default **`io2`** provisioned IOPS — highest performance, but
  expensive and wrong for the cost-sensitive workloads this module targets.
- **other:** ______

### Q3 — Storage autoscaling default — RESOLVED (a)

**Resolved: a.** Expose `max_allocated_storage`, default `null` (off);
operators opt in. When set, add `lifecycle { ignore_changes =
[allocated_storage] }` and a `max >= allocated_storage` precondition.

- **a (chosen):** Expose `max_allocated_storage` with default **`null`
  (off)**; operators opt in. When set, add `lifecycle { ignore_changes =
  [allocated_storage] }` and a precondition `max >= allocated_storage`. Off
  by default keeps cost predictable and avoids silent growth on runaway
  workloads.
- **b:** Default autoscaling **on** at `2 × allocated_storage` — protects
  against out-of-space outages for single instances (which, unlike Aurora,
  can hard-stop when full), at the cost of a less predictable bill.
- **c:** Omit the input entirely for v1 — smallest surface, but leaves the
  most common single-instance failure mode (disk full) unaddressed.
- **other:** ______

### Q4 — Multi-AZ default — RESOLVED (a)

**Resolved: a.** Default `multi_az = false`; operators opt into HA per
instance.

- **a (chosen):** Default **`false`** — matches DESIGN-0007 (cost;
  single-AZ acceptable for the prototype/low-volume target). Operators opt
  into HA per instance.
- **b:** Default **`true`** — HA by default (safer for anything
  prod-adjacent), roughly doubles instance cost.
- **other:** ______

### Q5 — Non-Aurora read replicas — RESOLVED (a)

**Resolved: a.** Defer cross-instance read replicas to a separate
`modules/rds/instance-replica` module (symmetric with the Aurora
`read-replica` module), composed via this module's remote state. Not v1 scope;
file a follow-up DESIGN when a consumer materialises.

- **a (chosen):** **Defer to a separate `modules/rds/instance-replica`**
  module (symmetric with the Aurora `read-replica` module), composed via this
  module's remote state — matches DESIGN-0007 Q6-b. Keeps `instance`'s input
  surface clean and its state small. Not v1 scope; file a follow-up DESIGN
  when a consumer materialises.
- **b:** Add `replicate_source_db` + a `replicas` map **inside this module**
  — one plan for primary + replicas, but couples replica lifecycle to the
  primary's blast radius (the exact coupling we avoided on the Aurora side).
- **c:** Out of scope entirely, no successor module planned.
- **other:** ______

### Q6 — CA certificate identifier handling — RESOLVED (a)

**Resolved: a.** Expose `var.ca_cert_identifier` (optional, default `null` →
AWS account default CA), so operators can pre-stage a CA rotation without a
module change.

- **a (chosen):** Expose `var.ca_cert_identifier` (optional, default
  **`null`** → AWS account default CA). Lets operators pin
  `rds-ca-rsa2048-g1` ahead of a CA rotation without a module change, but
  doesn't force a value that AWS rotates on its own cadence.
- **b:** **Pin** a default (`rds-ca-rsa2048-g1`) — explicit and
  reproducible, but becomes stale and needs a module bump each CA cycle.
- **c:** Omit the input — smallest surface; operators can't pre-stage a CA
  rotation.
- **other:** ______

### Q7 — Blue/Green deployment support — RESOLVED (a)

**Resolved: a.** Blue/Green is out of scope for the instance module v1. The
fleet-wide posture — an opt-in toggle defaulting off, whenever any RDS module
adds it — is recorded in
[ADR-0017](../adr/0017-rds-blue-green-deployments-are-opt-in-and-default-off.md).

- **a (chosen):** **Out of scope for v1.** RDS Blue/Green
  (`blue_green_update`) is a major-upgrade/parameter-change safety tool that
  adds real complexity (a shadow instance, cutover semantics). Defer to a
  follow-up once a consumer needs low-downtime major upgrades.
- **b:** Expose `blue_green_update { enabled = true }` as an opt-in toggle
  now — future-proofs major upgrades, but adds test surface and edge cases
  before there's a consumer.
- **other:** ______

### Q8 — Default engine majors in the parameter-family map — RESOLVED (b)

**Resolved: b.** Seed the **newest GA majors**: `postgres → 18`,
`mysql → 8.4` (RDS PostgreSQL 18 GA'd Nov 2025; RDS MySQL 8.4 is the current
LTS). To keep the RDS family on one version posture, the shipped `serverless`
(Aurora) module is bumped to match — Aurora PostgreSQL `16 → 18` (Aurora PG 18
GA'd 2026-06-11) — in companion **PR #32**. The `locals.tf` illustration above
reflects these values.

- **a (recommended, not chosen):** Seed **`postgres` → `16`, `mysql` → `8.0`**
  (matches the serverless module's `default_major_map`, keeps the family
  lookups consistent across the RDS family). Newer majors are additive map
  entries + a Renovate bump.
- **b (chosen):** Seed the newest GA majors — most current. Diverges from the
  shipped serverless defaults, so those are bumped in lockstep (PR #32).
- **c:** No default major — require `engine_version` whenever the family
  can't be resolved. Explicit, but noisier for the common case.
- **other:** ______

## References

- [DESIGN-0007](0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS module family layout (parent design; Q1–Q7 resolutions this doc inherits).
- [DESIGN-0010](0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md) — RDS Proxy module (the seven-output composition contract this module must satisfy as a `target_type = "rds-instance"`).
- [IMPL-0007](../impl/0007-aurora-serverless-v2-module-implementation.md) — Aurora Serverless v2 implementation (the as-built scaffolding this module reuses).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state`.
- [ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md) — Terraform manages AWS APIs only; schema migrations out-of-band.
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants.
- [ADR-0017](../adr/0017-rds-blue-green-deployments-are-opt-in-and-default-off.md) — RDS Blue/Green deployments are opt-in and default off (resolves Q7).
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy.
- [`aws_db_instance` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance).
