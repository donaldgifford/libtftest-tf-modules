---
id: IMPL-0007
title: "Aurora Serverless v2 Module Implementation"
status: Draft
author: Donald Gifford
created: 2026-05-27
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0007: Aurora Serverless v2 Module Implementation

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-27

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Module scaffolding + variable surface](#phase-1-module-scaffolding--variable-surface)
  - [Phase 2: Data sources + locals (parameter family map)](#phase-2-data-sources--locals-parameter-family-map)
  - [Phase 3: KMS key (gated BYO with prevent_destroy)](#phase-3-kms-key-gated-byo-with-prevent_destroy)
  - [Phase 4: Subnet group + security group](#phase-4-subnet-group--security-group)
  - [Phase 5: Parameter groups (cluster + instance)](#phase-5-parameter-groups-cluster--instance)
  - [Phase 6: Aurora Serverless v2 cluster](#phase-6-aurora-serverless-v2-cluster)
  - [Phase 7: Cluster instance (db.serverless)](#phase-7-cluster-instance-dbserverless)
  - [Phase 8: Outputs (consumer contract)](#phase-8-outputs-consumer-contract)
  - [Phase 9: terraform test plan-only suite](#phase-9-terraform-test-plan-only-suite)
  - [Phase 10: tests-localstack gap-discovery suite](#phase-10-tests-localstack-gap-discovery-suite)
  - [Phase 11: README, USAGE, audits, CLAUDE.md update](#phase-11-readme-usage-audits-claudemd-update)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions (all resolved)](#open-questions)
- [References](#references)
<!--toc:end-->

## Objective

Ship `modules/rds/serverless` — an Aurora Serverless v2 Terraform module
supporting Postgres + MySQL engines, with module-managed KMS, AWS-managed
master password (Secrets Manager), opt-in IAM database authentication, and
network composition via `data.terraform_remote_state.vpc`. First module in
the RDS rollout per DESIGN-0007 §Migration / Rollout Plan; establishes the
Aurora parameter-family lookups, KMS handling, and Secrets-Manager-first
posture that the other three RDS modules (`instance`, `cluster`,
`read-replica`) will reuse.

**Implements:** [DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md)

## Scope

### In Scope

- `modules/rds/serverless/` directory under the existing `modules/rds/`
  parent (created by the design-doc PR).
- Aurora Serverless v2 cluster: `aws_rds_cluster` with
  `engine_mode = "provisioned"` + `serverlessv2_scaling_configuration`,
  plus exactly one `aws_rds_cluster_instance` with
  `instance_class = "db.serverless"`.
- Engine support: `aurora-postgresql` and `aurora-mysql`. Static parameter
  family map in `locals.tf` per DESIGN-0007 Q3 resolution.
- Module-managed KMS key (BYO-able via `var.kms_key_arn`), AWS-managed
  master password (Secrets Manager) per DESIGN-0007 Q2.
- Opt-in IAM database authentication per DESIGN-0007 Q5; SG-source-list
  ingress contract via `var.allowed_consumer_sg_ids`.
- `terraform test` plan-only suite covering both engines, BYO KMS shape,
  validation negatives, parameter-family resolution.
- `tests-localstack/` apply suite (LocalStack Community default; Pro also
  verified per DESIGN-0007 Q7) with the IMPL-0005 Phase 9 fall-back pattern
  if any RDS APIs return 501.
- README documenting prereqs, instantiation patterns, post-apply
  `psql` / `mysql` smoke recipe.

### Out of Scope

- The other three RDS modules (`instance`, `cluster`, `read-replica`).
  Each gets its own IMPL doc + feature branch + PR per DESIGN-0007's
  rollout order. This IMPL covers `serverless` only.
- Cross-region replicas, Aurora Multi-Master, RDS Proxy, non-Postgres /
  non-MySQL engines, schema migrations — all DESIGN-0007 Non-Goals.
- `data.terraform_remote_state.vpc` contract changes — this module
  consumes the existing VPC remote-state shape; standardizing across the
  fleet is a separate ADR if/when needed.
- Backup verification / restore drills (operational workstream, not
  module code per DESIGN-0007 Non-Goals).

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its
tasks are checked off, its success criteria are met, and a conventional
commit has landed.

Quality gates per the donald-loop directive:

- After each task: `just tf fmt rds/serverless`, `just tf lint
  rds/serverless`, `just tf validate rds/serverless`.
- After each phase: `go-architect` review before new Go code (N/A here —
  Terraform-only module), `go-review` after Go code (N/A), `terraform
  test` plan-only suite must pass for any phase that touched HCL.
- Conventional commit per numbered task per the donald-loop directive.

---

### Phase 1: Module scaffolding + variable surface

Establish the file layout (`main.tf`, `variables.tf`, `versions.tf`,
`locals.tf`, `outputs.tf`, `.tflint.hcl`, `.terraform-docs.yml`,
`README.md` stub) and the full input contract. No resources yet — just
the surface area + validations.

#### Tasks

- [x] Create `modules/rds/serverless/` directory; copy scaffolding files
      verbatim from `modules/ecr/org-registry/` (`.terraform-docs.yml`,
      `.tflint.hcl`) per the per-module conventions in CLAUDE.md.
- [x] Author `versions.tf` pinning `hashicorp/aws ~> 6.2`, Terraform
      `>= 1.1` (matches fleet pin).
- [x] Author `variables.tf` with the full input contract from
      DESIGN-0007 §Input surface, including:
  - Required: `region`, `remote_state_bucket`, `vpc_name`,
    `identifier_prefix`, `engine`, `min_acu`, `max_acu` (per Q2
    resolution — both required, no defaults).
  - **Variable description for `min_acu` / `max_acu` (Q2 resolution)**:
    explicitly call out two suggested ranges in the description text:
    `"... Suggested ranges: dev = min 0.5 / max 4; production
    starter = min 0.5 / max 16. Tune to your workload's load shape."`
    Surfaces the ergonomic defaults in `terraform-docs` output
    without baking them into the variable's `default` field.
  - Optional: `engine_version` (default null), `kms_key_arn` (default
    null), `allowed_consumer_sg_ids` (default `[]`),
    `iam_database_authentication_enabled` (default false),
    `manage_master_user_password` (default true),
    `master_username` (default `"admin"` per Q4 resolution — single
    default for both engines; consumers override per-engine if they
    want `"postgres"`),
    `database_name` (default null per Q11 resolution — no initial DB
    created when null),
    `backup_retention_period` (default 7 per Q7),
    `preferred_backup_window` (default `"02:00-03:00"` per Q7),
    `preferred_maintenance_window` (default
    `"sun:04:00-sun:05:00"` per Q7),
    `deletion_protection` (default true),
    `publicly_accessible` (default false),
    `apply_immediately` (default false per Q8),
    `parameter_family` (default null — resolved per engine in locals),
    `auto_minor_version_upgrade` (default true per DESIGN-0007 Q4),
    `final_snapshot_identifier` (default null per Q9 — required at
    destroy time when `skip_final_snapshot = false`),
    `skip_final_snapshot` (default false),
    `performance_insights_enabled` (default false per Q6),
    `enhanced_monitoring_interval` (default 0 per Q6 — disabled),
    `enhanced_monitoring_role_arn` (default null per Q6 — caller-
    supplied; module does not provision the IAM role),
    `tags` (default `{}`).
- [x] Each variable carries a `description`, `type`, `default`
      (optional only), `nullable` (where applicable), and a `validation`
      block for any input with a constrained shape. Critically, place
      `nullable` AFTER `validation` per the custom tflint rule (sibling
      pattern in `modules/ecr/org-registry/variables.tf`).
- [x] Validation blocks for:
  - `engine`: regex `^aurora-(postgresql|mysql)$`.
  - `engine_version` (if non-null): regex matching engine-major (e.g.,
    `^(\d+\.\d+|\d+)$`).
  - `min_acu`, `max_acu`: numeric, `>= 0.5` and `<= 256` (the
    Aurora Serverless v2 range), `min_acu <= max_acu` enforced via
    a `lifecycle.precondition` on the cluster resource (variable-level
    cross-var validation requires terraform >= 1.9; fleet pin is 1.1).
  - `backup_retention_period`: `>= 1 && <= 35`.
  - `identifier_prefix`: regex `^[a-z][a-z0-9-]{0,61}[a-z0-9]$`
    (AWS RDS identifier shape, 1-63 chars).
  - `allowed_consumer_sg_ids`: each entry matches `^sg-[a-f0-9]+$`.
- [x] Stub `main.tf`, `locals.tf`, `outputs.tf` with header comments
      (resources land in later phases).
- [x] Create `modules/rds/serverless/README.md` stub (one-line pointer
      to `USAGE.md`).

#### Success Criteria

- `just tf validate rds/serverless` succeeds (variables typed correctly,
  no resource references resolving to nothing yet).
- `just tf fmt rds/serverless` reports no diffs.
- `just tf lint rds/serverless` passes (zero violations on the custom
  `terraform_tautological_naming`, `variable_attribute_order` rules).
- `terraform-docs .` renders all variables into `USAGE.md` between the
  `<!-- BEGIN_TF_DOCS -->` markers.

---

### Phase 2: Data sources + locals (parameter family map)

Wire `data.aws_caller_identity.current` and
`data.terraform_remote_state.vpc`; populate the static parameter family
map in `locals.tf` per DESIGN-0007 Q3 resolution.

#### Tasks

- [x] Add `data.aws_caller_identity.current` (ADR-0001 identity carve-
      out — used for tags and any future ARN scoping).
- [x] Add `data.terraform_remote_state.vpc` with `backend = "s3"`,
      `use_path_style = true`, key
      `${var.region}/vpc/${var.vpc_name}/terraform.tfstate`. Consumed
      outputs (per Q1 resolution): `private_subnet_ids`, `vpc_id` —
      reuses the existing EKS-cluster remote-state contract.
- [x] Populate `locals.tf`:
  - `account_id = data.aws_caller_identity.current.account_id`.
  - `kms_key_arn = coalesce(var.kms_key_arn, try(aws_kms_key.this[0].arn, null))`
    (Phase 3 declares the gated KMS resource; the `try()` keeps Phase 2
    plan-valid before Phase 3 lands — same pattern used in
    `modules/ecr/org-registry/locals.tf`).
  - `parameter_family_map = { "aurora-postgresql:16" = "aurora-postgresql16", "aurora-postgresql:15" = "aurora-postgresql15", "aurora-mysql:8.0" = "aurora-mysql8.0", "aurora-mysql:5.7" = "aurora-mysql5.7" }`
    (extend list at implementation time after probing
    `aws rds describe-db-engine-versions`).
  - `default_major_map = { "aurora-postgresql" = "16", "aurora-mysql" = "8.0" }`
    per Q3 resolution — pins a default engine major per engine for
    parameter-family lookup when `var.engine_version` is null. Renovate
    bumps these as new engine versions GA.
  - `engine_major = var.engine_version != null ? split(".", var.engine_version)[0] : local.default_major_map[var.engine]`.
  - `resolved_parameter_family = coalesce(var.parameter_family, lookup(local.parameter_family_map, "${var.engine}:${local.engine_major}", null))` —
    error message if lookup returns null surfaces via a precondition on
    the cluster resource ("engine + major combination not in the static
    family map — set var.parameter_family explicitly or update the map").
  - `kms_alias_name = "alias/${var.identifier_prefix}-rds-serverless"`.
  - Inline `TODO` comment per DESIGN-0007 Q3 pointing at
    `data.aws_rds_engine_version` as the future replacement for the
    static map.
  - **No `default_master_username_map` local** — Q4 resolution picks a
    single default `"admin"` baked into the variable; no per-engine
    indirection.
- [x] Reference data-source + local values at the use site (no
      aliasing locals for plain passthroughs per ADR-0001 / CLAUDE.md).

#### Success Criteria

- `just tf validate rds/serverless` succeeds.
- `just tf fmt rds/serverless` reports no diffs.
- `terraform plan` against a `tests/` fixture with stub VPC remote-state
  outputs resolves all data sources and computed locals (a smoke `run`
  in the test suite proves this; full validation lands in Phase 9).

---

### Phase 3: KMS key (gated BYO with prevent_destroy)

Mirror `modules/ecr/org-registry`'s KMS handling. Module-managed key +
alias when caller doesn't supply one; `lifecycle.prevent_destroy = true`
on the managed key (cluster data outlives Terraform churn; operator must
empty the cluster + lift the lifecycle block deliberately to destroy).

#### Tasks

- [x] Create `modules/rds/serverless/kms.tf`:
  - `aws_kms_key.this` with `count = var.kms_key_arn == null ? 1 : 0`,
    `enable_key_rotation = true`, `deletion_window_in_days = 30`,
    `description = "KMS key for Aurora Serverless v2 cluster ${var.identifier_prefix} encryption at rest"`,
    `lifecycle { prevent_destroy = true }`.
  - `aws_kms_alias.this` with same count gate; `name =
    local.kms_alias_name`, `target_key_id = aws_kms_key.this[0].key_id`.
  - `tags = var.tags`.
- [x] Verify `local.kms_key_arn` resolves correctly in BOTH modes:
  - BYO mode (`var.kms_key_arn != null`): the literal ARN flows through.
  - Module-managed mode: `try(aws_kms_key.this[0].arn, null)` resolves
    to the managed key's ARN at plan time.

#### Success Criteria

- `just tf validate rds/serverless` succeeds.
- A `tests/` smoke run with `var.kms_key_arn = null` creates the KMS
  key + alias resources in plan output.
- A second smoke run with `var.kms_key_arn = "arn:aws:kms:..."` creates
  zero KMS resources and references the BYO ARN downstream.

---

### Phase 4: Subnet group + security group

DB-tier networking. Subnet group over `database_subnet_ids` from VPC
remote state; security group with ingress on the engine's default port
from `var.allowed_consumer_sg_ids`.

#### Tasks

- [x] Create `modules/rds/serverless/network.tf` (or fold into
      `main.tf` — match existing single-file conventions for small
      modules; split per concern when files grow):
  - `aws_db_subnet_group.this`:
    - `name = "${var.identifier_prefix}-rds-serverless"`.
    - `subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids`
      (per Q1 resolution — reuses the existing EKS-cluster remote-
      state contract; future hardening to a dedicated database-tier
      subnet list can be additive).
    - `tags = var.tags`.
  - `aws_security_group.this`:
    - `name = "${var.identifier_prefix}-rds-serverless"`.
    - `vpc_id = data.terraform_remote_state.vpc.outputs.vpc_id`.
    - `tags = var.tags`.
- [x] Engine-default-port resolution via locals:
  - `local.engine_default_port_map = { "aurora-postgresql" = 5432, "aurora-mysql" = 3306 }`.
  - `local.engine_default_port = local.engine_default_port_map[var.engine]`.
- [x] Three granular `aws_vpc_security_group_*_rule` resources (the
      cluster module's pattern — no inline ingress/egress on the SG
      itself):
  - One `aws_vpc_security_group_ingress_rule` per entry in
    `var.allowed_consumer_sg_ids` via `for_each = toset(var.allowed_consumer_sg_ids)`;
    `referenced_security_group_id = each.value`,
    `from_port = local.engine_default_port`,
    `to_port = local.engine_default_port`,
    `ip_protocol = "tcp"`.
  - One `aws_vpc_security_group_egress_rule` for all-outbound (RDS needs
    outbound to AWS endpoints).
- [x] Verify the SG-source-list rule count matches
      `length(var.allowed_consumer_sg_ids)` in the test suite (deferred
      assertion to Phase 9 `sg_ingress.tftest.hcl`).

#### Success Criteria

- `just tf validate rds/serverless` succeeds.
- Test fixture with two stub consumer SGs (`["sg-aaa", "sg-bbb"]`)
  produces exactly two ingress rules with the expected
  `referenced_security_group_id` values.
- `just tf lint rds/serverless` passes (the granular SG rules are the
  modern pattern per the `terraform-style` custom plugin).

---

### Phase 5: Parameter groups (cluster + instance)

Aurora needs two parameter groups: an `aws_rds_cluster_parameter_group`
for cluster-level params and an `aws_db_parameter_group` for instance-
level params. Both resolved against `local.resolved_parameter_family`.

#### Tasks

- [x] Create `modules/rds/serverless/parameter_groups.tf`:
  - `aws_rds_cluster_parameter_group.this`:
    - `name_prefix = "${var.identifier_prefix}-cluster-"`.
    - `family = local.resolved_parameter_family`.
    - `description = "Cluster parameter group for ${var.identifier_prefix}"`.
    - `tags = var.tags`.
    - `lifecycle { create_before_destroy = true }` — parameter group
      renames are destroy-then-create; CBD prevents downtime.
  - `aws_db_parameter_group.this`:
    - `name_prefix = "${var.identifier_prefix}-instance-"`.
    - `family = local.resolved_parameter_family`.
    - `description = "Instance parameter group for ${var.identifier_prefix}"`.
    - `tags = var.tags`.
    - `lifecycle { create_before_destroy = true }`.
- [x] No custom `parameter` blocks in v1 — operators override defaults
      by passing a `parameter_family` that points at a different family
      (e.g., engine-minor pin). Per-parameter customization deferred
      until a concrete consumer materializes (additive variable surface
      change, easy follow-up PR).

#### Success Criteria

- `just tf validate rds/serverless` succeeds.
- Both parameter groups resolve `family =
  local.resolved_parameter_family` at plan time.
- A negative test case where `var.engine = "aurora-postgresql"` +
  `var.engine_version = "9.99"` (not in the static map) +
  `var.parameter_family = null` produces a clear precondition error.

---

### Phase 6: Aurora Serverless v2 cluster

The core resource: `aws_rds_cluster` with `engine_mode = "provisioned"`
(NOT `"serverless"` — that's v1) + `serverlessv2_scaling_configuration
{ min_capacity, max_capacity }`. AWS-managed master password,
encryption at rest, deletion protection on by default.

#### Tasks

- [x] Create `modules/rds/serverless/cluster.tf`:
  - `aws_rds_cluster.this`:
    - `cluster_identifier = var.identifier_prefix`.
    - `database_name = var.database_name` (per Q11 — null OK; no
      initial database created).
    - `engine = var.engine`.
    - `engine_mode = "provisioned"`.
    - `engine_version = var.engine_version` (null OK — AWS picks default).
    - `serverlessv2_scaling_configuration { min_capacity = var.min_acu; max_capacity = var.max_acu }`.
    - `master_username = var.master_username` (default `"admin"` per
      Q4 resolution — no local-side per-engine indirection).
    - `manage_master_user_password = var.manage_master_user_password`.
    - `master_user_secret_kms_key_id = local.kms_key_arn` (per Q12 —
      same key as the cluster's storage encryption; one KMS key per
      module pattern matches the org-registry precedent).
    - `db_subnet_group_name = aws_db_subnet_group.this.name`.
    - `vpc_security_group_ids = [aws_security_group.this.id]`.
    - `db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name`.
    - `storage_encrypted = true`.
    - `kms_key_id = local.kms_key_arn`.
    - `iam_database_authentication_enabled = var.iam_database_authentication_enabled`.
    - `backup_retention_period = var.backup_retention_period`.
    - `preferred_backup_window = var.preferred_backup_window`.
    - `preferred_maintenance_window = var.preferred_maintenance_window`.
    - `deletion_protection = var.deletion_protection`.
    - `skip_final_snapshot = var.skip_final_snapshot`.
    - `final_snapshot_identifier = var.final_snapshot_identifier`
      (per Q9 — optional input, default null; required at destroy time
      when `skip_final_snapshot = false`; the lifecycle precondition
      below enforces the cross-variable invariant).
    - `apply_immediately = var.apply_immediately`.
    - `tags = var.tags`.
    - `lifecycle { precondition { condition = var.min_acu <= var.max_acu; error_message = "..." } }`
      (cross-variable invariant enforcement — terraform 1.1
      `variable.validation` can't reference other vars).
    - `lifecycle { precondition { condition = local.resolved_parameter_family != null; error_message = "engine + major combination not in static parameter_family_map — set var.parameter_family explicitly or extend the map in locals.tf" } }`.
    - `lifecycle { precondition { condition = var.skip_final_snapshot || var.final_snapshot_identifier != null; error_message = "final_snapshot_identifier must be set when skip_final_snapshot = false (the default). Supply via -var at destroy time." } }`
      per Q9.
  - Place attributes in alphabetical order (scalar args first, then
    blocks alphabetically) per the custom `resource_parameter_order`
    tflint rule (sibling pattern in
    `modules/ecr/org-registry/templates.tf`).

#### Success Criteria

- `just tf validate rds/serverless` succeeds.
- `just tf lint rds/serverless` passes (alphabetical attribute order
  enforced).
- Test suite verifies:
  - `engine_mode` resolves to `"provisioned"` (NOT `"serverless"`).
  - `serverlessv2_scaling_configuration` block has both
    `min_capacity` and `max_capacity` set.
  - `storage_encrypted = true` and `kms_key_id` references
    `local.kms_key_arn`.
  - `manage_master_user_password = true` by default.
  - `master_username = "admin"` by default (per Q4).
  - `database_name = null` by default (per Q11).
  - `deletion_protection = true` by default.
  - Destroy-without-final-snapshot precondition fires when
    `skip_final_snapshot = false` + `final_snapshot_identifier = null`
    (per Q9).

---

### Phase 7: Cluster instance (db.serverless)

Aurora Serverless v2 requires at least one `aws_rds_cluster_instance`
with the special `instance_class = "db.serverless"`. The instance is
what makes the cluster reachable; without it, the cluster is a
metadata-only object.

#### Tasks

- [ ] Append to `modules/rds/serverless/cluster.tf` (or split into
      `instance.tf` if the file grows past ~150 lines):
  - `aws_rds_cluster_instance.this`:
    - `cluster_identifier = aws_rds_cluster.this.id`.
    - `instance_class = "db.serverless"`.
    - `engine = aws_rds_cluster.this.engine`.
    - `engine_version = aws_rds_cluster.this.engine_version`.
    - `db_subnet_group_name = aws_db_subnet_group.this.name`.
    - `db_parameter_group_name = aws_db_parameter_group.this.name`.
    - `publicly_accessible = var.publicly_accessible`.
    - `auto_minor_version_upgrade = var.auto_minor_version_upgrade`.
    - `apply_immediately = var.apply_immediately`.
    - `performance_insights_enabled = var.performance_insights_enabled`
      (per Q6 — default `false`; caller opts in).
    - `performance_insights_kms_key_id = var.performance_insights_enabled ? local.kms_key_arn : null`
      (only set when PI is enabled; reuses the module's KMS key).
    - `monitoring_interval = var.enhanced_monitoring_interval` (per
      Q6 — default `0` = disabled).
    - `monitoring_role_arn = var.enhanced_monitoring_role_arn` (per
      Q6 — caller-supplied; module does not provision the role per
      the "manage AWS API resources only, no cross-service IAM
      helpers" boundary).
    - `tags = var.tags`.
    - Alphabetical attribute ordering per the tflint rule.
- [ ] `var.performance_insights_enabled` (default `false`),
      `var.enhanced_monitoring_interval` (default `0`),
      `var.enhanced_monitoring_role_arn` (default `null`) already added
      to `variables.tf` in Phase 1 per Q6 resolution.

#### Success Criteria

- `just tf validate rds/serverless` succeeds.
- Test suite verifies `instance_class = "db.serverless"` literally
  (the Serverless v2 signal).
- `engine` / `engine_version` flow from cluster outputs (single source
  of truth — instance can't drift from cluster).

---

### Phase 8: Outputs (consumer contract)

The consumer-facing surface. Outputs must remain stable — once published
under `outputs.tf`, downstream modules consume them via remote state.
Renaming or removing an output breaks consumers.

#### Tasks

- [ ] Author `modules/rds/serverless/outputs.tf` with the following
      outputs, each carrying a `description`:
  - `cluster_identifier` (= `aws_rds_cluster.this.id`).
  - `cluster_resource_id` (= `aws_rds_cluster.this.cluster_resource_id`
    — the immutable AWS-internal ID, useful for IAM auth policies).
  - `cluster_endpoint` (= `aws_rds_cluster.this.endpoint` — writer
    endpoint).
  - `reader_endpoint` (= `aws_rds_cluster.this.reader_endpoint`).
  - `port` (= `aws_rds_cluster.this.port`).
  - `engine` (= `aws_rds_cluster.this.engine`).
  - `engine_version_actual` (=
    `aws_rds_cluster.this.engine_version_actual` — the resolved
    version, important when `var.engine_version = null`).
  - `db_subnet_group_name`.
  - `security_group_id`.
  - `kms_key_arn` (= `local.kms_key_arn` — BYO ARN or managed key ARN
    transparently).
  - `master_user_secret_arn` (= `try(aws_rds_cluster.this.master_user_secret[0].secret_arn, null)`
    — null when `manage_master_user_password = false`).
  - `db_cluster_parameter_group_name`.
  - `db_parameter_group_name`.
  - `cluster_instance_identifier`.
- [ ] No `sensitive = true` flags — none of these outputs are secret
      values (the secret ARN is metadata; the secret value is in
      Secrets Manager).
- [ ] Re-run `terraform-docs .` to render outputs into `USAGE.md`.

#### Success Criteria

- `just tf validate rds/serverless` succeeds.
- Every output has a description.
- `USAGE.md` regenerated cleanly between
  `<!-- BEGIN_TF_DOCS -->` markers.

---

### Phase 9: terraform test plan-only suite

Per ADR-0013 and RFC-0001, the plan-only `terraform test` suite is the
baseline. Lives in `modules/rds/serverless/tests/`. No LocalStack
required; runs in ~1-2 seconds.

#### Tasks

- [ ] Create `modules/rds/serverless/tests/` directory.
- [ ] Author `tests/default.tftest.hcl`:
  - One `run` per engine (`aurora-postgresql` + `aurora-mysql`).
  - Asserts on resource counts (1 cluster, 1 instance, 1 cluster
    parameter group, 1 db parameter group, 1 subnet group, 1 SG, 1
    KMS key, 1 KMS alias).
  - Asserts `engine_mode = "provisioned"`,
    `instance_class = "db.serverless"`,
    `storage_encrypted = true`, `deletion_protection = true`,
    `manage_master_user_password = true`.
  - Uses `override_data` to stub
    `data.terraform_remote_state.vpc` outputs (handcrafted JSON state
    file produced inline via `override_data { ... values = { ... } }`).
  - Uses `override_data` to stub
    `data.aws_caller_identity.current`.
- [ ] Author `tests/byo_kms.tftest.hcl`:
  - `var.kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/byo-test"`.
  - Asserts zero `aws_kms_key.this` resources and zero
    `aws_kms_alias.this` resources.
  - Asserts cluster's `kms_key_id` references the BYO ARN.
- [ ] Author `tests/parameter_family_resolution.tftest.hcl`:
  - Run 1: `engine = "aurora-postgresql"`, `engine_version = "16"` →
    asserts `local.resolved_parameter_family = "aurora-postgresql16"`.
  - Run 2: `engine = "aurora-mysql"`, `engine_version = "8.0"` →
    asserts `"aurora-mysql8.0"`.
  - Run 3: `parameter_family = "aurora-postgresql15"` (override) →
    asserts override wins.
- [ ] Author `tests/sg_ingress.tftest.hcl`:
  - `var.allowed_consumer_sg_ids = ["sg-aaa1234567", "sg-bbb7654321"]`
    → asserts exactly two
    `aws_vpc_security_group_ingress_rule.consumer` resources with the
    expected `referenced_security_group_id` values.
  - Empty list → zero ingress rules (cluster reachable from nowhere —
    operator-explicit posture).
- [ ] Author `tests/validation.tftest.hcl` with `expect_failures` on:
  - `var.engine = "postgres"` (rejected — only aurora-* engines).
  - `var.engine_version = "16-beta"` (rejected by Q10 loose regex —
    accepts only `\d+` or `\d+.\d+`).
  - `var.min_acu = 0` (rejected — Serverless v2 minimum is 0.5).
  - `var.max_acu = 512` (rejected — Serverless v2 max is 256).
  - `var.min_acu = 8, var.max_acu = 4` (rejected — precondition on
    cluster resource).
  - `var.backup_retention_period = 0` (rejected — minimum is 1).
  - `var.identifier_prefix = "InvalidUpperCase"` (rejected — RDS
    identifier shape lowercase only).
  - `var.skip_final_snapshot = false` + `var.final_snapshot_identifier = null`
    (rejected by Q9 precondition on the cluster resource).
- [ ] Author `tests/iam_db_auth.tftest.hcl`:
  - Default → `iam_database_authentication_enabled = false`.
  - With `var.iam_database_authentication_enabled = true` → cluster
    attribute resolves to true.
- [ ] All test files start with a `provider "aws"` block matching the
      sibling pattern (LocalStack-style fake credentials + skips).
- [ ] BYO KMS used in any test that asserts on `local.kms_key_arn`-
      dependent attributes so the value is plan-known (lesson learned
      from IMPL-0006 — module-managed KMS ARN is unknown at plan).

#### Success Criteria

- `just tf test rds/serverless` passes all runs.
- Total wall-clock time < 5 seconds.
- Coverage: both engines, BYO + managed KMS, IAM auth on/off, ingress
  list shapes, all validation negatives.

---

### Phase 10: tests-localstack gap-discovery suite

Opt-in apply suite per RFC-0001 Phase 2. Defaults to LocalStack
Community per DESIGN-0007 Q7; verifies tier-agnosticism by also
running against Pro (per the Q7 implementation-time verification step).

#### Tasks

- [ ] Create `modules/rds/serverless/tests-localstack/` directory.
- [ ] Create `tests-localstack/fixture/` with:
  - `vpc_state.tf` — builds a VPC + database subnets, writes a
    handcrafted state file (matching the VPC remote-state contract)
    to an S3 bucket inside LocalStack.
  - `kms_state.tf` (if needed for BYO testing) — provisions a real
    KMS key inside LocalStack.
- [ ] Probe LocalStack Community + Pro support matrix for:
  - `aws_db_subnet_group` — likely supported on both tiers.
  - `aws_rds_cluster` (with `engine_mode = "provisioned"` +
    Serverless v2 scaling config) — Aurora Serverless v2 specifically
    is the highest-risk surface for LocalStack support.
  - `aws_rds_cluster_instance` (with `instance_class = "db.serverless"`).
  - `aws_db_parameter_group` + `aws_rds_cluster_parameter_group`.
  - `aws_security_group` + granular SG rules.
  - `aws_kms_key` + `aws_kms_alias`.
  - `aws_secretsmanager_secret` (created implicitly by
    `manage_master_user_password = true`).
- [ ] Author `tests-localstack/apply_localstack.tftest.hcl` (per Q5
      resolution):
  - `run "setup"` — applies the VPC fixture to land the stub remote-
    state file in S3.
  - `run "apply_default"` (engine = `aurora-postgresql`) — applies
    the module against LocalStack with default vars + the fixture's
    state bucket. If `CreateDBCluster` with `engine_mode =
    "provisioned"` + `serverlessv2_scaling_configuration` 501s on
    Community, follow the IMPL-0005 Phase 9 fall-back: comment out
    the apply, document in `FINDINGS.md`, leave a `plan_smoke` run
    active to prove endpoint resolution + plan-time validation.
  - `run "plan_mysql"` (engine = `aurora-mysql`) — plan-only against
    LocalStack endpoints. Proves the MySQL engine path resolves
    against LocalStack's provider endpoint config + plan-time
    validation. Cheaper than a second apply and catches engine-
    divergent plan-time gaps.
- [ ] Author `tests-localstack/FINDINGS.md`:
  - **Finding #1**: gap-discovery results for each RDS API
    (Community + Pro coverage matrix).
  - **Finding #2**: tier-agnostic-by-construction verification per
    DESIGN-0007 Q7 — both tiers exercised identically; any
    differential 501 documented and filed as
    sneakystack / libtftest backlog.
- [ ] Cross-reference `pull-through-cache` and `org-registry`
      `FINDINGS.md` patterns; reuse the writeup conventions.

#### Success Criteria

- `just tf test-localstack rds/serverless` either:
  - (best case) passes a full `apply_default` run, or
  - (fall-back) passes a `plan_smoke` against LocalStack with
    the commented-out apply preserved + a clear `FINDINGS.md`
    explaining the gap.
- `FINDINGS.md` documents both Community and Pro test runs.
- Total wall-clock time < 90 seconds (matches sibling LocalStack
  suites).

---

### Phase 11: README, USAGE, audits, CLAUDE.md update

Polish + documentation. Brings the module to "ready for consumer
adoption" state.

#### Tasks

- [ ] Expand `modules/rds/serverless/README.md` with:
  - Prerequisites (VPC module landed first, S3 backend bucket exists,
    LocalStack tier note).
  - Instantiation patterns: minimal Postgres example, minimal MySQL
    example, BYO KMS example, opt-in IAM auth example.
  - Post-apply smoke recipe: how to retrieve the AWS-managed password
    from Secrets Manager (`aws secretsmanager get-secret-value`) and
    connect via `psql` or `mysql` through a bastion / VPN.
  - Operational gotchas:
    - `deletion_protection = true` by default — flip to `false` for
      a deliberate destroy plan.
    - KMS key `prevent_destroy = true` — two-step destroy procedure
      (empty cluster → remove lifecycle block → destroy).
    - Engine-major upgrade is a destructive plan; operators bump
      `var.engine_version` deliberately + apply in a maintenance
      window.
    - Scaling boundary changes (`min_acu` / `max_acu`) are in-place-
      apply-safe.
- [ ] Regenerate `USAGE.md` via `terraform-docs .`.
- [ ] Add a "Aurora Serverless v2 module shape" section to
      `CLAUDE.md` (~150-line block following the
      `modules/ecr/org-registry` precedent).
- [ ] Update `CLAUDE.md` repository-purpose section to list the new
      `modules/rds/` family — note serverless as the first to land.
- [ ] Update IMPL-0007 status from `Draft` → `Completed`; tick all
      tasks in this file.
- [ ] `just docs lint` passes.
- [ ] Final audit pass: `just tf all rds/serverless`
      (validate + lint + fmt + test) passes cleanly.

#### Success Criteria

- `just docs lint` passes (no markdownlint violations).
- `just tf all rds/serverless` passes.
- `README.md` and `USAGE.md` both rendered and up-to-date.
- `CLAUDE.md` has the new module-shape section + repository-purpose
  bump.
- IMPL-0007 status flipped to Completed; all tasks ticked.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/rds/serverless/versions.tf` | Create | Provider + Terraform version pins |
| `modules/rds/serverless/variables.tf` | Create | Full input contract |
| `modules/rds/serverless/locals.tf` | Create | Parameter family map, engine port map, KMS ARN coalesce |
| `modules/rds/serverless/main.tf` | Create | `data.aws_caller_identity.current`, `data.terraform_remote_state.vpc` |
| `modules/rds/serverless/kms.tf` | Create | Gated `aws_kms_key` + alias with `prevent_destroy` |
| `modules/rds/serverless/network.tf` | Create | DB subnet group + SG + granular ingress/egress rules |
| `modules/rds/serverless/parameter_groups.tf` | Create | Cluster + instance parameter groups |
| `modules/rds/serverless/cluster.tf` | Create | `aws_rds_cluster` (Serverless v2 mode) + `aws_rds_cluster_instance` |
| `modules/rds/serverless/outputs.tf` | Create | Consumer-contract outputs |
| `modules/rds/serverless/.tflint.hcl` | Create | Copy from sibling module |
| `modules/rds/serverless/.terraform-docs.yml` | Create | Copy from sibling module |
| `modules/rds/serverless/README.md` | Create | Stub + (Phase 11) full README |
| `modules/rds/serverless/USAGE.md` | Create | Generated by terraform-docs |
| `modules/rds/serverless/tests/*.tftest.hcl` | Create | 6 test files, ~12 runs |
| `modules/rds/serverless/tests-localstack/apply_localstack.tftest.hcl` | Create | Apply suite (or plan_smoke fall-back) |
| `modules/rds/serverless/tests-localstack/fixture/*.tf` | Create | VPC remote-state fixture |
| `modules/rds/serverless/tests-localstack/FINDINGS.md` | Create | Gap-discovery writeup |
| `CLAUDE.md` | Modify | Add "Aurora Serverless v2 module shape" section; update repository-purpose list |
| `docs/impl/0007-aurora-serverless-v2-module-implementation.md` | Modify | Tick tasks per phase; flip status to Completed |

## Testing Plan

- **Plan-only `terraform test` suite** (`tests/`) — covers both engines,
  BYO + managed KMS, IAM auth on/off, SG ingress list shapes, validation
  negatives (engine, ACU range, ACU ordering precondition, retention,
  identifier shape), parameter-family resolution (engine + version
  combos + explicit override).
- **`tests-localstack/` gap-discovery suite** — exercises the module
  against LocalStack Community as default tier per DESIGN-0007 Q7; same
  suite verified against Pro per the Q7 implementation-time verification
  step. Fall-back to `plan_smoke` + commented-out apply if Aurora
  Serverless v2 APIs 501 on either tier (IMPL-0005 Phase 9 pattern).
- **No libtftest Go suite for this module** — per ADR-0013, the EKS
  cluster module is the sole side-by-side reference; new modules default
  to `terraform test` alone. Post-apply runtime invariants
  (`pg_isready` / `mysqladmin ping` through the cluster endpoint, AWS-
  managed password rotation, IAM auth token generation) are filed as
  libtftest / sneakystack backlog per RFC-0001 §Phase 3.

## Dependencies

- **DESIGN-0007** must be merged before this IMPL ships (PR #17 at
  time of writing).
- **The fleet VPC module** must already exist + be applied + writing
  state to S3 with the expected output shape (`vpc_id`,
  `private_subnet_ids` per Q1 resolution — reuses the existing
  EKS-cluster remote-state contract). Consumers without a VPC module
  need to land one first; this is an organizational prerequisite, not
  a module prerequisite the code can solve.
- **LocalStack Pro 2026.5.0 image** for the optional Pro verification
  step in Phase 10 (Community is sufficient for the default run).
- **No new tooling pins in `mise.toml`** — Terraform, terraform-docs,
  tflint, just, docz already pinned at fleet versions.
- **No upstream Terraform provider bumps** required —
  `hashicorp/aws ~> 6.2` (resolving to v6.45.0) supports every
  resource referenced.

## Open Questions

All thirteen questions resolved 2026-05-27 and folded into the
relevant Phase sections above. Resolutions summarized below.

### Q1 — VPC remote-state contract field name for database subnets — RESOLVED (b)

**Resolved:** `private_subnet_ids` — reuse the existing EKS-cluster
remote-state contract per CLAUDE.md. Cluster module's outputs are the
fleet's source of truth for VPC composition; introducing a new
`database_subnet_ids` output would have forced a VPC-module change as
a prerequisite. Future hardening (dedicated DB-tier subnet list,
restrictive NACLs) can be additive — a separate variable for an
explicit subnet override, plus an ADR documenting the tier boundary.

### Q2 — Default `min_acu` / `max_acu` bounds — RESOLVED (a, with suggested ranges in description)

**Resolved:** No defaults; both `min_acu` and `max_acu` are required
inputs. ACU range is a load-shape decision per consumer; forcing the
input makes the cost decision visible at instantiation time. Suggested
ranges surface via the variable `description` field — Phase 1 task
includes the exact text: `"... Suggested ranges: dev = min 0.5 / max 4;
production starter = min 0.5 / max 16. Tune to your workload's load
shape."` — so `terraform-docs` output advertises the ergonomic
starting points without baking them into `default`.

### Q3 — `engine_version = null` default handling — RESOLVED (a)

**Resolved:** Pin a default engine major per engine in `locals.tf`:
`default_major_map = { "aurora-postgresql" = "16", "aurora-mysql" =
"8.0" }`. When `var.engine_version` is null, the module uses these
for the parameter family lookup AND passes `engine_version = null`
to `aws_rds_cluster` (AWS picks the actual default at apply time).
Renovate bumps the default major as new engine versions GA — annual
cadence per engine. Phase 2 locals carry the map; Phase 6's
precondition surfaces a clear error when the resolved family is
unknown.

### Q4 — Default `master_username` per engine — RESOLVED (other — single default `"admin"`)

**Resolved:** Single `var.master_username` input with default
`"admin"` for both engines. Simpler than the per-engine map (no
locals indirection); marginally surprising for Postgres operators
who expect the AWS console default `"postgres"` but easy to
override. Phase 1 variable definition carries the default; Phase 6
references the var directly at the cluster's `master_username`
attribute. No `default_master_username_map` local needed.

### Q5 — tests-localstack apply matrix — RESOLVED (a)

**Resolved:** One `apply_default` run with `aurora-postgresql` + a
second `plan_mysql` run that's plan-only against LocalStack
endpoints. Covers the most common engine fully (catches LocalStack
RDS gaps end-to-end); the MySQL path gets endpoint-resolution +
plan-time-validation coverage. Wall-clock budget ~75s. Phase 10
tasks reflect both runs. IMPL-0005 Phase 9 fall-back (501 →
`plan_smoke` + comment-out + FINDINGS.md) still applies if Aurora
Serverless v2 isn't implemented on LocalStack.

### Q6 — Performance Insights + Enhanced Monitoring defaults — RESOLVED (b)

**Resolved:** Both Performance Insights and Enhanced Monitoring off
by default; module does NOT provision the monitoring IAM role.
Conservative on cost; caller opts in to either via explicit vars
(`var.performance_insights_enabled = true`,
`var.enhanced_monitoring_interval > 0`,
`var.enhanced_monitoring_role_arn = "arn:..."`). Module-side IAM
role provisioning would cross the "manage AWS API resources only,
no cross-service helpers" boundary; consumer-supplied is more
composable across the four RDS modules.

### Q7 — `backup_retention_period` + windows defaults — RESOLVED (a)

**Resolved:** Defaults as designed: `backup_retention_period = 7`,
`preferred_backup_window = "02:00-03:00"`,
`preferred_maintenance_window = "sun:04:00-sun:05:00"`. 7-day
retention matches the AWS RDS default; the chosen UTC windows are
off-peak in most US timezones. Operators override per-cluster when
load shape warrants. Phase 1 variable defaults reflect these
values.

### Q8 — `apply_immediately` default — RESOLVED (a)

**Resolved:** `apply_immediately = false` by default; changes land
in the next maintenance window. Matches AWS-recommended posture
and prevents accidental cluster reboots from benign tag/parameter
changes. Operators flip to `true` per-cluster for dev environments
or urgent fixes via `var.apply_immediately = true`.

### Q9 — `final_snapshot_identifier` shape — RESOLVED (a)

**Resolved:** `var.final_snapshot_identifier` is an optional input
(default null); `var.skip_final_snapshot` is a separate toggle
(default `false`). When destroying with `skip_final_snapshot =
false`, the caller MUST supply a non-null `final_snapshot_identifier`
via `-var`. Phase 6 cluster resource carries a precondition
enforcing this; Phase 9 validation tests cover the negative case
(both null + skip=false fails). Avoids `timestamp()` plan noise,
forces operators to think about snapshot naming deliberately,
matches AWS console / CLI ergonomics.

### Q10 — Engine-major version validation — RESOLVED (a)

**Resolved:** Loose validation: regex `^(\d+\.\d+|\d+)$` only.
Accepts `"16"`, `"16.4"`, `"8.0"`, etc. Doesn't enumerate valid
versions (those drift between provider releases and AWS API
rollouts). The Phase 6 parameter family lookup precondition
serves as the stricter gate — an engine + major combination not
in the static map fails at plan with a clear error message.

### Q11 — Expose `database_name` input — RESOLVED (a)

**Resolved:** Add `var.database_name` as optional input, default
null → no initial database created. Lets consumers declaratively
land an initial DB if they want one; defaulting to null preserves
the "module manages infrastructure, not schema" posture from
DESIGN-0007 Non-Goals. Phase 1 variable definition + Phase 6
cluster attribute reference carry the wiring.

### Q12 — Master user secret KMS key — RESOLVED (a)

**Resolved:** Same KMS key as the cluster. Both encryptions
(storage at rest + master user secret in Secrets Manager) ride on
`local.kms_key_arn`. Simplifies the module surface; one KMS key
per module matches the org-registry precedent.
`master_user_secret_kms_key_id = local.kms_key_arn` at Phase 6.

### Q13 — Test framework engine matrix file layout — RESOLVED (a)

**Resolved:** One `default.tftest.hcl` with two runs (one per
engine). Mirrors the IMPL-0006 `validation.tftest.hcl` multi-run
pattern. Keeps the engine matrix close together; diff-readable
when one engine regresses. Phase 9 task list reflects the
single-file-two-runs shape.

## References

- [DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS module layout (the design this IMPL implements).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state`.
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants.
- [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md) — libtftest for apply-time validation.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy.
- [IMPL-0005](0005-ecr-pull-through-cache-module-implementation.md) — Sibling IMPL for the relocated pull-through-cache module (LocalStack 501 fallback pattern, FINDINGS.md shape).
- [IMPL-0006](0006-org-wide-ecr-oci-artifact-registry-module-implementation.md) — Sibling IMPL for the org-registry module (KMS handling with `prevent_destroy`, schema-gap workaround, BYO-KMS-in-tests pattern, alphabetical resource attribute ordering).
- [Aurora Serverless v2 documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.html).
- [`aws_rds_cluster` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster).
- [`aws_rds_cluster_instance` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance).
