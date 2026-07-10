---
id: IMPL-0011
title: "RDS instance module implementation"
status: Draft
author: Donald Gifford
created: 2026-07-09
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0011: RDS instance module implementation

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-07-09

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Module scaffolding, version pins, and variable surface](#phase-1-module-scaffolding-version-pins-and-variable-surface)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Data sources and locals (non-Aurora parameter-family map)](#phase-2-data-sources-and-locals-non-aurora-parameter-family-map)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: KMS key (managed-or-BYO, prevent-destroy)](#phase-3-kms-key-managed-or-byo-prevent-destroy)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Subnet group and security group](#phase-4-subnet-group-and-security-group)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: DB parameter group (single, no cluster group)](#phase-5-db-parameter-group-single-no-cluster-group)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: The DB instance resource and storage surface](#phase-6-the-db-instance-resource-and-storage-surface)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
  - [Phase 7: Outputs (instance contract plus proxy composition)](#phase-7-outputs-instance-contract-plus-proxy-composition)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
  - [Phase 8: Plan-only terraform test suite](#phase-8-plan-only-terraform-test-suite)
    - [Tasks](#tasks-7)
    - [Success Criteria](#success-criteria-7)
  - [Phase 9: tests-localstack apply suite and FINDINGS](#phase-9-tests-localstack-apply-suite-and-findings)
    - [Tasks](#tasks-8)
    - [Success Criteria](#success-criteria-8)
  - [Phase 10: README, USAGE, CLAUDE.md, and docz closeout](#phase-10-readme-usage-claudemd-and-docz-closeout)
    - [Tasks](#tasks-9)
    - [Success Criteria](#success-criteria-9)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [Q1 — Scaffolding fork source — RESOLVED (a)](#q1--scaffolding-fork-source--resolved-a)
  - [Q2 — Stubbing VPC remote state and KMS in plan-only tests — RESOLVED (a)](#q2--stubbing-vpc-remote-state-and-kms-in-plan-only-tests--resolved-a)
  - [Q3 — Storage-autoscaling drift handling — RESOLVED (a)](#q3--storage-autoscaling-drift-handling--resolved-a)
  - [Q4 — Exposing storage throughput in v1 — RESOLVED (a)](#q4--exposing-storage-throughput-in-v1--resolved-a)
  - [Q5 — Apply-suite LocalStack tier — RESOLVED (a)](#q5--apply-suite-localstack-tier--resolved-a)
  - [Q6 — MySQL coverage layout — RESOLVED (a)](#q6--mysql-coverage-layout--resolved-a)
  - [Q7 — Custom parameter blocks in the DB parameter group — RESOLVED (a)](#q7--custom-parameter-blocks-in-the-db-parameter-group--resolved-a)
- [References](#references)
<!--toc:end-->

## Objective

Ship `modules/rds/instance` — a single, non-clustered `aws_db_instance` for
`postgres` / `mysql` workloads that don't need Aurora. The module forks the
shipped `serverless` scaffolding verbatim (VPC remote state, managed-or-BYO
KMS, granular SG rules, AWS-managed master password, parameter-family lookup,
the validation-split doctrine) and swaps the Aurora cluster + `db.serverless`
instance for a single `aws_db_instance` with the non-Aurora storage surface
(`allocated_storage`, `max_allocated_storage`, `storage_type`, `iops`,
`multi_az`). It is a valid RDS Proxy target (`target_type = "rds-instance"`)
and emits the seven proxy-composition outputs. Second module in the
DESIGN-0007 rollout — after `serverless`, independent of `cluster` /
`read-replica`.

**Implements:**
[DESIGN-0012](../design/0012-rds-instance-module-single-awsdbinstance.md) (all
eight open questions resolved: Q1a, Q2a, Q3a, Q4a, Q5a, Q6a, Q7a, Q8b), the
`instance` slot of
[DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md).

## Scope

### In Scope

- A new `modules/rds/instance/` module: scaffolding, the full input surface
  with validations, VPC remote-state read, managed-or-BYO KMS, DB subnet
  group + security group with granular rules, a single `aws_db_parameter_group`,
  the `aws_db_instance` resource, and outputs.
- Both engines from the start: `postgres` and `mysql`, resolved through a
  static non-Aurora parameter-family map in `locals.tf` (default majors
  `postgres → 18`, `mysql → 8.4` per DESIGN-0012 Q8b).
- The non-Aurora storage surface: `allocated_storage` (required),
  `max_allocated_storage` (autoscaling, default off), `storage_type`
  (default `gp3`), `iops`, `storage_throughput`, `multi_az` (default false),
  `ca_cert_identifier` (default null).
- The seven proxy-composition outputs (`master_user_secret_arn`,
  `master_user_secret_kms_key_arn`, `security_group_id`, `db_subnet_ids`,
  `vpc_id`, `engine`, `iam_database_authentication_enabled`) plus the
  instance-shaped consumer contract.
- Plan-only `terraform test` suite (the gate) + a `tests-localstack/` apply
  suite (Community default, tier-agnostic — no `tests-localstack-pro/`).
- Module README, generated `USAGE.md`, `CLAUDE.md` inventory update, docz
  closeout.

### Out of Scope

- **Aurora** (`cluster` / `serverless` / `read-replica` modules' concern).
- **Non-Aurora read replicas** (`replicate_source_db`) — deferred to a future
  `modules/rds/instance-replica` module per DESIGN-0012 Q5.
- **Blue/Green deployments** — out of scope for v1 per DESIGN-0012 Q7 /
  [ADR-0017](../adr/0017-rds-blue-green-deployments-are-opt-in-and-default-off.md).
- **Other engines** (Oracle, SQL Server, MariaDB, Db2), schema migrations /
  app users, backup restore drills — all DESIGN-0012 Non-Goals.
- **VPC remote-state contract changes** — consumes the existing `vpc_id` /
  `private_subnet_ids` shape (IMPL-0007 Q1).

## Implementation Phases

Each phase builds on the previous one and is committed as its own conventional
commit. A phase is complete when all its tasks are checked off and its success
criteria are met. Gate commands are the `justfile` recipes
(`just tf <action> rds/instance`).

Quality gates per the `/terraform` skill + the repo conventions:

- After each task: `just tf fmt rds/instance`, `just tf lint rds/instance`,
  `just tf validate rds/instance`.
- After each phase that touched HCL: the plan-only `just tf test rds/instance`
  suite must pass (once it exists, Phase 8 onward; earlier phases prove
  resolution via `just tf validate`).
- No Go code in this module — the `/terraform` conventions apply, not the
  go-development plugin.

---

### Phase 1: Module scaffolding, version pins, and variable surface

Establish the file layout and the full input contract. No resources yet —
just the surface area and the single-variable validations. Fork the file split
from `serverless` (Q1).

#### Tasks

- [ ] Create `modules/rds/instance/`; copy `.terraform-docs.yml` and
      `.tflint.hcl` verbatim from `modules/rds/serverless/` (per the per-module
      convention in CLAUDE.md).
- [ ] Author `versions.tf` pinning `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`.
- [ ] Author `variables.tf` with the DESIGN-0012 §Input surface. **Required**:
      `region`, `remote_state_bucket`, `vpc_name`, `identifier_prefix`,
      `engine`, `instance_class`, `allocated_storage` (Q1a — no defaults).
      **Optional** (defaults from the design table): `engine_version` (null),
      `max_allocated_storage` (null → autoscaling off, Q3a), `storage_type`
      (`"gp3"`, Q2a), `iops` (null), `storage_throughput` (null, see Q4),
      `multi_az` (false, Q4a-design), `db_port` (null), `database_name` (null),
      `kms_key_arn` (null), `allowed_consumer_sg_ids` (`[]`),
      `iam_database_authentication_enabled` (false),
      `manage_master_user_password` (true), `master_username` (`"admin"`),
      `backup_retention_period` (7), `preferred_backup_window`
      (`"02:00-03:00"`), `preferred_maintenance_window`
      (`"sun:04:00-sun:05:00"`), `deletion_protection` (true),
      `publicly_accessible` (false), `apply_immediately` (false),
      `auto_minor_version_upgrade` (true), `parameter_family` (null → resolved),
      `ca_cert_identifier` (null, Q6a-design), `final_snapshot_identifier`
      (null), `skip_final_snapshot` (false), `performance_insights_enabled`
      (false), `enhanced_monitoring_interval` (0), `enhanced_monitoring_role_arn`
      (null), `tags` (`{}`).
- [ ] Each variable carries `description` + `type` + `default` (optional only) +
      `nullable` — with `nullable` placed AFTER `validation` per the custom
      tflint attribute-order rule (sibling pattern in
      `modules/rds/serverless/variables.tf`).
- [ ] Single-variable `validation` blocks for: `engine` (`^(postgres|mysql)$`);
      `engine_version` if non-null (`^(\d+\.\d+|\d+)$`); `identifier_prefix`
      (`^[a-z][a-z0-9-]{0,61}[a-z0-9]$`); `allowed_consumer_sg_ids` (each
      `^sg-[a-f0-9]+$`); `backup_retention_period` in `[1,35]`;
      `allocated_storage >= 20` (AWS floor); `storage_type` in
      `["gp2","gp3","io2"]`; `enhanced_monitoring_interval` in
      `{0,1,5,10,15,30,60}`; `db_port` null or in `[1,65535]`.
- [ ] Stub `main.tf`, `locals.tf`, `outputs.tf` with header comments; create a
      `README.md` stub (one-line pointer to `USAGE.md`).

#### Success Criteria

- `just tf validate rds/instance` succeeds.
- `just tf fmt rds/instance` reports no diffs.
- `just tf lint rds/instance` passes the custom attribute-order rule (the
  `terraform_unused_*` warnings intrinsic to a variables-only phase clear once
  Phase 6 wires the resource — re-verified at Phase 6 and the Phase 10 gate).
- `just tf docs rds/instance` renders every variable into `USAGE.md`.

---

### Phase 2: Data sources and locals (non-Aurora parameter-family map)

Wire `data.terraform_remote_state.vpc` and populate `locals.tf`: the KMS-ARN
coalesce, the non-Aurora parameter-family map, the default-major map, and the
engine-port map.

#### Tasks

- [ ] `main.tf`: `data.terraform_remote_state.vpc` — `backend = "s3"`,
      `use_path_style = true`, key
      `${var.region}/vpc/${var.vpc_name}/terraform.tfstate`. Consumes
      `outputs.vpc_id` and `outputs.private_subnet_ids` (the EKS-cluster
      contract, IMPL-0007 Q1 — NOT `database_subnet_ids`).
- [ ] `locals.tf`:
  - `kms_key_arn = coalesce(var.kms_key_arn, try(aws_kms_key.this[0].arn, null))`
    (Phase 3 declares the gated key; `try()` keeps this phase plan-valid).
  - `parameter_family_map` for the non-Aurora engines:
    `{ "postgres:18"="postgres18", "postgres:17"="postgres17",
    "postgres:16"="postgres16", "mysql:8.4"="mysql8.4",
    "mysql:8.0"="mysql8.0" }` (extend after probing
    `aws rds describe-db-engine-versions`).
  - `default_major_map = { "postgres"="18", "mysql"="8.4" }` (Q8b — newest GA
    majors; Renovate bumps as new majors GA).
  - `engine_major = var.engine_version != null ? split(".", var.engine_version)[0] : local.default_major_map[var.engine]`
    (for MySQL the family key is `major.minor`, e.g. `8.4` / `8.0` — resolve
    the key accordingly, mirroring the serverless MySQL handling).
  - `resolved_parameter_family = coalesce(var.parameter_family, lookup(local.parameter_family_map, "${var.engine}:${local.engine_major}", null))`.
  - `engine_default_port_map = { "postgres"=5432, "mysql"=3306 }`;
    `engine_default_port = local.engine_default_port_map[var.engine]`.
  - `kms_alias_name = "alias/${var.identifier_prefix}-rds-instance"`.
  - Inline `TODO` pointing at `data.aws_rds_engine_version` as the future
    replacement for the static map (same note serverless carries).

#### Success Criteria

- `just tf validate rds/instance` succeeds.
- `just tf fmt rds/instance` reports no diffs.
- A `tests/` smoke run with stub VPC outputs resolves all data sources and
  computed locals (full assertion lands in Phase 8).

---

### Phase 3: KMS key (managed-or-BYO, prevent-destroy)

Verbatim from `serverless` / `org-registry`: module-managed key + alias when
the caller supplies none; `prevent_destroy` on the managed key.

#### Tasks

- [ ] `kms.tf`:
  - `aws_kms_key.this` with `count = var.kms_key_arn == null ? 1 : 0`,
    `enable_key_rotation = true`, `deletion_window_in_days = 30`,
    `description = "KMS key for RDS instance ${var.identifier_prefix} encryption at rest"`,
    `lifecycle { prevent_destroy = true }`, `tags = var.tags`.
  - `aws_kms_alias.this` with the same count gate; `name = local.kms_alias_name`,
    `target_key_id = aws_kms_key.this[0].key_id`.
- [ ] Verify `local.kms_key_arn` resolves in both modes (BYO literal ARN passes
      through; module-managed resolves `aws_kms_key.this[0].arn`).

#### Success Criteria

- `just tf validate rds/instance` succeeds.
- A `tests/` smoke run with `kms_key_arn = null` plans exactly 1 key + 1 alias;
  a second with a BYO ARN plans 0 KMS resources and references the BYO ARN.

---

### Phase 4: Subnet group and security group

DB-tier networking, verbatim from `serverless`. Subnet group over
`private_subnet_ids`; granular ingress rules on the engine port from
`var.allowed_consumer_sg_ids`; one all-outbound egress rule.

#### Tasks

- [ ] `network.tf`:
  - `aws_db_subnet_group.this` — `name = "${var.identifier_prefix}-rds-instance"`,
    `subnet_ids = data.terraform_remote_state.vpc.outputs.private_subnet_ids`,
    `tags = var.tags`.
  - `aws_security_group.this` — `name = "${var.identifier_prefix}-rds-instance"`,
    `vpc_id = data.terraform_remote_state.vpc.outputs.vpc_id`, `tags = var.tags`.
  - One `aws_vpc_security_group_ingress_rule.consumer` per entry via
    `for_each = toset(var.allowed_consumer_sg_ids)`;
    `referenced_security_group_id = each.value`, from/to port =
    `local.engine_default_port` (or `var.db_port`), `ip_protocol = "tcp"`.
  - One `aws_vpc_security_group_egress_rule.all` (all-outbound).

#### Success Criteria

- `just tf validate rds/instance` succeeds; `just tf lint rds/instance` passes.
- Two stub consumer SGs → exactly two ingress rules with the expected
  `referenced_security_group_id` values; empty list → zero ingress rules;
  `mysql` engine → port `3306`.

---

### Phase 5: DB parameter group (single, no cluster group)

Unlike Aurora, a single instance needs only one `aws_db_parameter_group` (no
cluster parameter group). Resolved against `local.resolved_parameter_family`.

#### Tasks

- [ ] `parameter_groups.tf`:
  - `aws_db_parameter_group.this` — `name_prefix = "${var.identifier_prefix}-"`,
    `family = local.resolved_parameter_family`,
    `description = "Instance parameter group for ${var.identifier_prefix}"`,
    `tags = var.tags`, `lifecycle { create_before_destroy = true }`.
- [ ] No custom `parameter` blocks in v1 (Q7) — operators repoint
      `var.parameter_family` for a different family; per-parameter tuning is a
      later additive change.

#### Success Criteria

- `just tf validate rds/instance` succeeds.
- The parameter group resolves `family = local.resolved_parameter_family` at
  plan time.
- A negative case (`engine = "postgres"`, `engine_version = "9.99"`,
  `parameter_family = null`) surfaces a clear precondition error (from Phase 6).

---

### Phase 6: The DB instance resource and storage surface

The load-bearing phase: `aws_db_instance.this` with the full storage /
credential / backup / monitoring surface and the plan-time preconditions.
Resolve the storage-autoscaling drift question (Q3) here.

#### Tasks

- [ ] `instance.tf`: `aws_db_instance.this` (alphabetical attribute order per
      the custom tflint rule):
  - `identifier = var.identifier_prefix`.
  - `engine`, `engine_version` (null OK), `instance_class`.
  - `allocated_storage`, `max_allocated_storage`, `storage_type`, `iops`,
    `storage_throughput` (see Q4).
  - `db_subnet_group_name = aws_db_subnet_group.this.name`,
    `vpc_security_group_ids = [aws_security_group.this.id]`,
    `parameter_group_name = aws_db_parameter_group.this.name`,
    `port = coalesce(var.db_port, local.engine_default_port)`,
    `db_name = var.database_name`.
  - `storage_encrypted = true`, `kms_key_id = local.kms_key_arn`.
  - `manage_master_user_password`, `master_username`,
    `master_user_secret_kms_key_id = local.kms_key_arn`.
  - `iam_database_authentication_enabled`, `multi_az`,
    `publicly_accessible`, `deletion_protection`, `apply_immediately`,
    `auto_minor_version_upgrade`, `ca_cert_identifier`.
  - `backup_retention_period`, `backup_window = var.preferred_backup_window`,
    `maintenance_window = var.preferred_maintenance_window`,
    `skip_final_snapshot`, `final_snapshot_identifier`.
  - `performance_insights_enabled` + `performance_insights_kms_key_id`
    (`var.performance_insights_enabled ? local.kms_key_arn : null`);
    `monitoring_interval = var.enhanced_monitoring_interval`,
    `monitoring_role_arn = var.enhanced_monitoring_role_arn`.
- [ ] `lifecycle.precondition`s on `aws_db_instance.this`:
      `local.resolved_parameter_family != null`; `var.skip_final_snapshot ||
      var.final_snapshot_identifier != null`; `var.max_allocated_storage ==
      null || var.max_allocated_storage >= var.allocated_storage`;
      `var.enhanced_monitoring_interval == 0 ||
      var.enhanced_monitoring_role_arn != null`; and (when `storage_type ==
      "io2"`) `var.iops != null`.
- [ ] **Resolve Q3 (storage-autoscaling drift).** Probe whether the AWS
      provider suppresses the `allocated_storage` diff once autoscaling has
      grown the volume (expected — the provider has built-in handling when
      `max_allocated_storage` is set). If confirmed, add NO `ignore_changes`;
      if drift appears in a targeted plan, fall back to the documented
      always-ignore posture and record the trade-off (manual resize suppressed)
      in the README. Record the outcome in `FINDINGS.md` (Phase 9).

#### Success Criteria

- `just tf validate rds/instance` succeeds; `just tf lint rds/instance` passes
  (alphabetical attribute order enforced).
- Plan asserts: `storage_encrypted = true`, `kms_key_id` references
  `local.kms_key_arn`, `multi_az` default `false`, `deletion_protection`
  default `true`, `storage_type` default `"gp3"`, `master_username` default
  `"admin"`.
- The four preconditions fire on their negative inputs (asserted in Phase 8).
- The Q3 storage-autoscaling drift behaviour is decided and recorded.

---

### Phase 7: Outputs (instance contract plus proxy composition)

The consumer-facing surface, including the seven proxy-composition outputs so
the module is a valid `target_type = "rds-instance"`.

#### Tasks

- [ ] `outputs.tf` (each with a `description`): `instance_identifier`,
      `endpoint`, `address`, `port`, `engine`, `engine_version_actual`,
      `db_subnet_group_name`, `db_parameter_group_name`, `security_group_id`,
      `kms_key_arn` (= `local.kms_key_arn`).
- [ ] The proxy-composition set (same names + null-safe expressions as
      `serverless`): `master_user_secret_arn` (=
      `try(aws_db_instance.this.master_user_secret[0].secret_arn, null)`),
      `master_user_secret_kms_key_arn` (=
      `try(aws_db_instance.this.master_user_secret[0].kms_key_id, null)`),
      `db_subnet_ids` (= `aws_db_subnet_group.this.subnet_ids`), `vpc_id`
      (= `aws_security_group.this.vpc_id`),
      `iam_database_authentication_enabled`.
- [ ] Regenerate `USAGE.md` (`just tf docs rds/instance`).

#### Success Criteria

- `just tf validate rds/instance` succeeds; every output has a description.
- The output names exactly match the seven the `proxy` module reads
  (cross-checked against `modules/rds/serverless/outputs.tf`).
- `USAGE.md` is current.

---

### Phase 8: Plan-only terraform test suite

Per [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md)
and RFC-0001, the plan-only suite in `tests/` is the gate. No LocalStack; runs
in ~1-2s. VPC remote state stubbed via `override_data` (Q2); BYO KMS in the
shared `variables{}` so `local.kms_key_arn` is plan-known.

#### Tasks

- [ ] `tests/default.tftest.hcl` — one run per engine (`postgres` + `mysql`):
      asserts engine, `storage_encrypted = true`, `deletion_protection = true`,
      `multi_az = false`, `storage_type = "gp3"`, `manage_master_user_password
      = true`, `master_username = "admin"`, parameter-family resolution
      (`postgres18` / `mysql8.4`), and the four proxy-composition outputs
      (`vpc_id`, `db_subnet_ids` length/contents,
      `iam_database_authentication_enabled = false`).
- [ ] `tests/kms.tftest.hcl` — managed-KMS count (`kms_key_arn = null` → 1 key
      + 1 alias) and BYO-KMS (0 KMS resources; `kms_key_id` = BYO ARN).
- [ ] `tests/parameter_family_resolution.tftest.hcl` — engine + version →
      family, and explicit `parameter_family` override wins.
- [ ] `tests/sg_ingress.tftest.hcl` — 2 consumers → 2 ingress rules; empty → 0;
      `mysql` → port 3306.
- [ ] `tests/storage_autoscaling.tftest.hcl` — `max_allocated_storage` set →
      precondition passes and (per Q3 outcome) the chosen drift posture holds;
      inverted (`max < allocated`) → precondition fails.
- [ ] `tests/validation.tftest.hcl` with `expect_failures`: bad `engine`
      (`aurora-postgresql`), bad `allocated_storage` (`10`), bad `storage_type`
      (`gp1`), inverted `max_allocated_storage`, snapshot-required precondition,
      bad `identifier_prefix`, monitoring-role-required precondition.
- [ ] All files open with the fake `provider "aws"` block (four `skip_*` flags).

#### Success Criteria

- `just tf test rds/instance` passes all runs in < 5s.
- Coverage: both engines, BYO + managed KMS, ingress shapes, storage
  autoscaling, all validation negatives.
- `just tf all rds/instance` is green.

---

### Phase 9: tests-localstack apply suite and FINDINGS

Opt-in apply suite per RFC-0001. `aws_db_instance` is broadly supported on
LocalStack Community, so this is **tier-agnostic — no `tests-localstack-pro/`**
(Q5). Any 501 follows the IMPL-0005 Phase 9 fall-back.

#### Tasks

- [ ] `tests-localstack/fixtures/setup/main.tf` — VPC + 3 private subnets across
      3 AZs + an S3 bucket holding a stub VPC state file at
      `<region>/vpc/<vpc_name>/terraform.tfstate` (sibling fixture shape).
- [ ] `tests-localstack/apply_localstack.tftest.hcl`:
  - `run "setup"` — apply the VPC fixture.
  - `run "apply_default"` (`engine = "postgres"`) — apply the full
    single-instance stack. If `CreateDBInstance` 501s, follow the IMPL-0005
    fall-back (comment the apply, keep a `plan_smoke`, record in FINDINGS).
    Pin `engine_version` if PG 18 is newer than the LocalStack image's catalog
    (the serverless pattern).
  - `run "plan_mysql"` (`engine = "mysql"`) — plan-only second-engine coverage.
- [ ] `tests-localstack/FINDINGS.md` — the RDS-instance coverage matrix
      (Community + any Pro run), the Q3 storage-autoscaling drift finding, the
      macOS named-volume caveat (embedded Postgres `initdb` needs a Docker
      named volume, not the `lstk` bind mount).

#### Success Criteria

- `just tf test-localstack rds/instance` passes a full `apply_default` (best
  case) or a `plan_smoke` fall-back with the gap recorded in `FINDINGS.md`.
- `FINDINGS.md` documents the observed tier(s) + the Q3 outcome.
- Wall-clock < 90s.

---

### Phase 10: README, USAGE, CLAUDE.md, and docz closeout

#### Tasks

- [ ] Author `modules/rds/instance/README.md`: prerequisites (VPC module +
      S3 backend), minimal Postgres / minimal MySQL / BYO-KMS / storage-
      autoscaling / IAM-auth examples, post-apply Secrets-Manager + `psql` /
      `mysql` smoke recipe, operational gotchas (`deletion_protection`,
      KMS `prevent_destroy` two-step destroy, engine-major upgrade is
      destructive, the Q3 storage-autoscaling / manual-resize note).
- [ ] Regenerate `USAGE.md`.
- [ ] Update `CLAUDE.md`: add `modules/rds/instance` to the §Repository purpose
      `rds` inventory + a shape line (note it's a valid `rds-instance` proxy
      target); regenerate the README module table (`just readme` if wired).
- [ ] Mark IMPL-0011 `Completed` (frontmatter + body), run `docz update`, move
      DESIGN-0012 to `Implemented`.
- [ ] `just docs lint` clean for the new docs.

#### Success Criteria

- `just tf all rds/instance` green; `README.md` + `USAGE.md` current.
- `CLAUDE.md` inventory + shape updated.
- IMPL-0011 `Completed`; DESIGN-0012 `Implemented`; docz index regenerated.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/rds/instance/versions.tf` | Create | `aws ~> 6.2`, terraform `>= 1.1` |
| `modules/rds/instance/.terraform-docs.yml` | Create | copied from serverless |
| `modules/rds/instance/.tflint.hcl` | Create | copied from serverless |
| `modules/rds/instance/variables.tf` | Create | full input surface + validations |
| `modules/rds/instance/locals.tf` | Create | KMS coalesce, non-Aurora family map, port map |
| `modules/rds/instance/main.tf` | Create | `data.terraform_remote_state.vpc` |
| `modules/rds/instance/kms.tf` | Create | gated `aws_kms_key` + alias (`prevent_destroy`) |
| `modules/rds/instance/network.tf` | Create | subnet group + SG + granular rules |
| `modules/rds/instance/parameter_groups.tf` | Create | single `aws_db_parameter_group` |
| `modules/rds/instance/instance.tf` | Create | `aws_db_instance.this` + preconditions |
| `modules/rds/instance/outputs.tf` | Create | instance contract + 4 proxy outputs |
| `modules/rds/instance/README.md` | Create | operator doc |
| `modules/rds/instance/USAGE.md` | Create | terraform-docs generated |
| `modules/rds/instance/tests/*.tftest.hcl` | Create | plan-only suite (~6 files) |
| `modules/rds/instance/tests-localstack/*` | Create | apply suite + fixture + FINDINGS |
| `CLAUDE.md` | Modify | add `modules/rds/instance` inventory + shape |
| `README.md` | Modify | module table regen |
| `docs/impl/README.md` | Modify | docz regen |
| `docs/design/0012-...md` | Modify | status → Implemented at closeout |

## Testing Plan

- **Plan-only `terraform test` (`tests/`)** — the gate (Phase 8): both engines,
  BYO + managed KMS, SG ingress shapes, storage autoscaling, parameter-family
  resolution, all validation negatives. Remote state stubbed via `override_data`.
- **`tests-localstack/` apply suite** — Community-default, tier-agnostic
  (Phase 9); IMPL-0005 fall-back to `plan_smoke` if `aws_db_instance` 501s.
- **No libtftest Go suite** — per ADR-0013; post-apply runtime invariants
  (`pg_isready` / `mysqladmin ping`, secret rotation, IAM-auth token) are
  RFC-0001 §Phase 3 backlog.

## Dependencies

- [DESIGN-0012](../design/0012-rds-instance-module-single-awsdbinstance.md) —
  the source contract (all OQs resolved).
- **`modules/rds/serverless` (IMPL-0007, shipped)** — the scaffolding this
  module forks; the proxy-composition output names are cross-checked against it.
- **The fleet VPC module** — must exist + be applied + writing state to S3 with
  the `vpc_id` / `private_subnet_ids` shape (an organizational prerequisite).
- `hashicorp/aws ~> 6.2` (fleet pin) — `aws_db_instance` and friends available.
- **Not blocked by** `cluster` / `read-replica` — `instance` is independent in
  the DESIGN-0007 rollout.
- **LocalStack** (Community sufficient) for the Phase 9 apply probe.

## Open Questions

Implementation-level decisions the design left open. All seven were resolved
2026-07-09 (all **a**). Each heading records the chosen option; the
**Resolved** line states the decision, and the alternatives are retained for
the record.

### Q1 — Scaffolding fork source — RESOLVED (a)

**Resolved: a.** Fork `modules/rds/serverless` — the closest RDS/VPC/KMS/SG
sibling; adapt it to `aws_db_instance` and the storage surface.

Which existing module do we copy the file split + `.tflint.hcl` /
`.terraform-docs.yml` from?

- **a (chosen):** Fork **`modules/rds/serverless`** — the closest sibling
  (same RDS/VPC/KMS/SG/parameter-group scaffolding, same validation-split
  doctrine); delete the Aurora cluster/instance + scaling block, swap in
  `aws_db_instance` and the storage surface. Minimizes divergence from the
  battle-tested module.
- **b:** Fork `modules/ecr/org-registry` (the original KMS + attribute-order
  reference) and re-add the RDS bits — more work, less RDS-shaped.
- **c:** Hand-author from the `/terraform` skill conventions — cleanest slate,
  but re-derives patterns already proven in `serverless`.
- **other:** ______

### Q2 — Stubbing VPC remote state and KMS in plan-only tests — RESOLVED (a)

**Resolved: a.** `override_data` on `data.terraform_remote_state.vpc` + a BYO
`kms_key_arn` in the shared `variables{}` (plus one managed-KMS-count run) —
the serverless pattern; no S3 backend.

How do the `tests/` runs supply the VPC outputs and keep `local.kms_key_arn`
plan-known?

- **a (chosen):** `override_data` on `data.terraform_remote_state.vpc`
  (supplying `vpc_id` + `private_subnet_ids`) + a BYO `kms_key_arn` in the
  shared `variables{}` (so the KMS ARN is plan-known where asserted), plus one
  dedicated managed-KMS-count run. Exactly the `serverless` pattern; no S3
  backend, runs in seconds.
- **b:** A wrapper fixture module that provisions a stub VPC state — heavier,
  and unnecessary for plan-only.
- **other:** ______

### Q3 — Storage-autoscaling drift handling — RESOLVED (a)

**Resolved: a.** Rely on the AWS provider's built-in `allocated_storage` diff
suppression when `max_allocated_storage` is set (no `ignore_changes`); verify
with a targeted plan at Phase 6 and record in `FINDINGS.md`, falling back to
the unconditional-ignore posture only if drift actually appears.

DESIGN-0012 says "when `max_allocated_storage` is set, add `lifecycle {
ignore_changes = [allocated_storage] }`" — but `ignore_changes` is a static
list and can't be made conditional on a variable. How do we handle
autoscaling-driven `allocated_storage` growth without perpetual drift?

- **a (chosen):** **Rely on the AWS provider's built-in diff suppression.**
  When `max_allocated_storage` is set, the provider suppresses the
  `allocated_storage` diff once autoscaling has grown the volume (actual >=
  configured), so **no `ignore_changes` is needed** — and deliberate manual
  resizes (bumping `var.allocated_storage`) still apply. Verify with a targeted
  apply/plan at Phase 6 and record in `FINDINGS.md`; fall back to (b) only if
  drift actually appears.
- **b:** Add `ignore_changes = [allocated_storage]` **unconditionally** — kills
  perpetual drift, but silently suppresses deliberate `var.allocated_storage`
  changes (operator resizes never take effect), which is a worse surprise.
- **c:** Omit autoscaling drift handling and document that operators must keep
  `var.allocated_storage` in sync with any autoscaled value — smallest code,
  most operator burden.
- **other:** ______

### Q4 — Exposing storage throughput in v1 — RESOLVED (a)

**Resolved: a.** Expose `var.storage_throughput` as an optional passthrough
(default `null` → AWS baseline), symmetric with `iops` — zero cost when unset,
no follow-up PR needed for large `gp3` volumes.

`storage_throughput` applies to `gp3` above a size/throughput threshold. The
design lists it; do we wire it in v1?

- **a (chosen):** Expose `var.storage_throughput` as an **optional
  passthrough** (default `null` → AWS baseline), symmetric with `iops`. Zero
  cost when unset, and available for large `gp3` volumes that need provisioned
  throughput — no follow-up PR needed later.
- **b:** Defer it — ship `iops` only in v1, add `storage_throughput` when a
  consumer needs it. Smaller surface, but a near-certain fast-follow.
- **other:** ______

### Q5 — Apply-suite LocalStack tier — RESOLVED (a)

**Resolved: a.** A single `tests-localstack/` suite, Community default (no
`tests-localstack-pro/`); probe at first run and apply the IMPL-0005 fall-back
if any API 501s, recording the tier in `FINDINGS.md`.

Where does the apply suite live, and which tier does it target?

- **a (chosen):** A single **`tests-localstack/`** suite, **Community
  default** (`aws_db_instance` is baseline RDS, broadly supported) — no
  `tests-localstack-pro/`. Probe at first run; if any API 501s, apply the
  IMPL-0005 fall-back and record the tier in `FINDINGS.md`.
- **b:** Add a `tests-localstack-pro/` apply like `proxy` — unwarranted here,
  since nothing in the single-instance surface is Pro-only.
- **other:** ______

### Q6 — MySQL coverage layout — RESOLVED (a)

**Resolved: a.** Both engines from the start, in one plan-only suite (the
parameter-family map carries both; the resource graph is engine-agnostic).
`apply_default` is Postgres; MySQL gets plan coverage.

Is MySQL a fast-follow phase (like `proxy` Phase 11) or built alongside
Postgres from the start?

- **a (chosen):** **Both engines from the start**, in one plan-only suite
  — the parameter-family map already carries both, and the resource graph is
  engine-agnostic (only the family + port differ). Matches `serverless` (no
  separate MySQL phase). The `tests-localstack/` apply is Postgres; MySQL gets
  plan-level coverage.
- **b:** A dedicated MySQL fast-follow phase after the Postgres phases are green
  — cleaner commit boundary, but redundant here since there's no MySQL-specific
  resource work.
- **other:** ______

### Q7 — Custom parameter blocks in the DB parameter group — RESOLVED (a)

**Resolved: a.** No custom `parameter` blocks in v1 — operators repoint
`var.parameter_family` for a different family; per-parameter tuning is an
additive follow-up. Matches serverless Phase 5.

Does v1 support per-parameter tuning in `aws_db_parameter_group`?

- **a (chosen):** **No custom `parameter` blocks in v1** — operators
  repoint `var.parameter_family` for a different family (e.g. an engine-minor
  pin). Matches `serverless` Phase 5; per-parameter customization is an additive
  follow-up when a concrete consumer needs it.
- **b:** Expose a `var.parameters` list-of-objects now (name / value / apply
  method) — more flexible, but adds surface + validation before there's a
  consumer.
- **other:** ______

## References

- [DESIGN-0012](../design/0012-rds-instance-module-single-awsdbinstance.md) — the design this IMPL implements (all OQs resolved).
- [DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS module family layout (parent design + rollout order).
- [DESIGN-0010](../design/0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md) — RDS Proxy (the seven-output composition contract this module satisfies as `target_type = "rds-instance"`).
- [IMPL-0007](0007-aurora-serverless-v2-module-implementation.md) — Aurora Serverless v2 implementation (the scaffolding this module forks).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state`.
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants.
- [ADR-0017](../adr/0017-rds-blue-green-deployments-are-opt-in-and-default-off.md) — RDS Blue/Green opt-in, default off (Q7 of the design).
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy.
- [`aws_db_instance` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_instance).
