---
id: IMPL-0012
title: "RDS Aurora provisioned cluster module implementation"
status: Draft
author: Donald Gifford
created: 2026-07-09
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0012: RDS Aurora provisioned cluster module implementation

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
  - [Phase 2: Data sources and locals (Aurora parameter-family map)](#phase-2-data-sources-and-locals-aurora-parameter-family-map)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: KMS key (managed-or-BYO, prevent-destroy)](#phase-3-kms-key-managed-or-byo-prevent-destroy)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Subnet group and security group](#phase-4-subnet-group-and-security-group)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Parameter groups (cluster and instance)](#phase-5-parameter-groups-cluster-and-instance)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: The Aurora provisioned cluster resource](#phase-6-the-aurora-provisioned-cluster-resource)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
  - [Phase 7: The writer cluster instance](#phase-7-the-writer-cluster-instance)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
  - [Phase 8: Outputs (source-of-truth contract plus proxy composition)](#phase-8-outputs-source-of-truth-contract-plus-proxy-composition)
    - [Tasks](#tasks-7)
    - [Success Criteria](#success-criteria-7)
  - [Phase 9: Plan-only terraform test suite](#phase-9-plan-only-terraform-test-suite)
    - [Tasks](#tasks-8)
    - [Success Criteria](#success-criteria-8)
  - [Phase 10: Pro-gated apply suite and FINDINGS](#phase-10-pro-gated-apply-suite-and-findings)
    - [Tasks](#tasks-9)
    - [Success Criteria](#success-criteria-9)
  - [Phase 11: README, USAGE, CLAUDE.md, and docz closeout](#phase-11-readme-usage-claudemd-and-docz-closeout)
    - [Tasks](#tasks-10)
    - [Success Criteria](#success-criteria-10)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [Q1 — Fork mechanics — RESOLVED (a)](#q1--fork-mechanics--resolved-a)
  - [Q2 — Aurora parameter-family majors to seed — RESOLVED (a)](#q2--aurora-parameter-family-majors-to-seed--resolved-a)
  - [Q3 — Backtrack engine-guard placement — RESOLVED (a)](#q3--backtrack-engine-guard-placement--resolved-a)
  - [Q4 — Aurora storage-type validation set — RESOLVED (a)](#q4--aurora-storage-type-validation-set--resolved-a)
  - [Q5 — Apply-suite LocalStack tier — RESOLVED (b)](#q5--apply-suite-localstack-tier--resolved-b)
  - [Q6 — MySQL coverage layout — RESOLVED (a)](#q6--mysql-coverage-layout--resolved-a)
  - [Q7 — Writer instance identifier suffix — RESOLVED (a)](#q7--writer-instance-identifier-suffix--resolved-a)
- [References](#references)
<!--toc:end-->

## Objective

Ship `modules/rds/cluster` — an Aurora **provisioned** cluster
(`aws_rds_cluster` with `engine_mode = "provisioned"` + a single
`aws_rds_cluster_instance` writer) for `aurora-postgresql` / `aurora-mysql`
production workloads. Framed for the IMPL as **`cluster` = `serverless` with
two edits**: drop the `serverlessv2_scaling_configuration` block + the
`min_acu` / `max_acu` inputs, and take a concrete `var.instance_class` instead
of the `db.serverless` sentinel. This module is the **source-of-truth state
file** for the cluster ↔ read-replica composition (ADR-0001) — its outputs are
the contract `read-replica` (IMPL-0013) reads — and a valid RDS Proxy target
(`target_type = "aurora-cluster"`). Third module in the DESIGN-0007 rollout;
**must merge before `read-replica`.**

**Implements:**
[DESIGN-0013](../design/0013-rds-aurora-provisioned-cluster-module.md) (all
eight open questions resolved, option `a`), the `cluster` slot of
[DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md).

## Scope

### In Scope

- A new `modules/rds/cluster/` module forking the `serverless` scaffolding:
  VPC remote state, managed-or-BYO KMS, subnet group + security group with
  granular rules, both parameter groups (cluster + instance), AWS-managed
  master password, the validation-split doctrine.
- The Aurora **provisioned** cluster: `aws_rds_cluster` (no serverless scaling
  block) + one `aws_rds_cluster_instance.writer` with a real `instance_class`.
- Both engines: `aurora-postgresql` + `aurora-mysql`, resolved through the
  Aurora parameter-family map (default majors seeded to match the shipped
  `serverless` module post-PR-#32 — Q2).
- The Aurora-specific optional surface: `storage_type` (I/O-Optimized opt-in,
  Q3-design), `backtrack_window` (aurora-mysql only, Q4-design),
  `enabled_cloudwatch_logs_exports` (Q6-design).
- The full source-of-truth output contract (`read-replica` consumer set) +
  the seven proxy-composition outputs + `cluster_instance_identifier`.
- Plan-only `terraform test` suite (the gate) + a Community-safe
  `tests-localstack/` `plan_smoke` + a Pro-gated `tests-localstack-pro/` apply
  suite (off by default per Q5; document the observed tier in `FINDINGS.md`).
- Module README, generated `USAGE.md`, `CLAUDE.md` inventory update, docz
  closeout.

### Out of Scope

- **Read replicas** — the `read-replica` module's job (DESIGN-0014 / IMPL-0013).
  This module provisions exactly one writer (DESIGN-0013 Q1).
- **Aurora Serverless v2** (the shipped `serverless` module) and mixed
  provisioned + `db.serverless` topologies (DESIGN-0013 Q8).
- **Multi-Master / multi-writer**, **cross-region / global clusters**
  (DESIGN-0013 Q5), **cluster-level custom endpoints** (DESIGN-0013 Q7).
- **Blue/Green deployments** — opt-in, default off, deferred per
  [ADR-0017](../adr/0017-rds-blue-green-deployments-are-opt-in-and-default-off.md).
- Schema migrations / app users, backup restore drills — DESIGN-0013 Non-Goals.

## Implementation Phases

Each phase builds on the previous one and is committed as its own conventional
commit. A phase is complete when all its tasks are checked off and its success
criteria are met. Gate commands are the `justfile` recipes
(`just tf <action> rds/cluster`).

Quality gates per the `/terraform` skill + repo conventions:

- After each task: `just tf fmt rds/cluster`, `just tf lint rds/cluster`,
  `just tf validate rds/cluster`.
- After each phase that touched HCL: `just tf test rds/cluster` (from Phase 9).
- No Go code — the `/terraform` conventions apply.

---

### Phase 1: Module scaffolding, version pins, and variable surface

Fork the `serverless` file split; delete the serverless-only inputs; add the
Aurora provisioned surface. No resources yet.

#### Tasks

- [x] Create `modules/rds/cluster/` by copying `modules/rds/serverless/`
      wholesale (Q1), then editing: remove `min_acu` / `max_acu`; copy
      `.terraform-docs.yml` / `.tflint.hcl` as-is.
- [x] `versions.tf`: `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`.
- [x] `variables.tf` per DESIGN-0013 §Input surface. **Required**: `region`,
      `remote_state_bucket`, `vpc_name`, `identifier_prefix`, `engine`,
      `instance_class` (Q2-design — no default). **Optional**: `engine_version`
      (null), `storage_type` (null → Aurora Standard, Q3-design),
      `backtrack_window` (0, aurora-mysql only, Q4-design),
      `enabled_cloudwatch_logs_exports` (`[]`, Q6-design), `kms_key_arn` (null),
      `allowed_consumer_sg_ids` (`[]`), `iam_database_authentication_enabled`
      (false), `manage_master_user_password` (true), `master_username`
      (`"admin"`), `database_name` (null), `backup_retention_period` (7),
      `preferred_backup_window` (`"02:00-03:00"`), `preferred_maintenance_window`
      (`"sun:04:00-sun:05:00"`), `deletion_protection` (true),
      `publicly_accessible` (false), `apply_immediately` (false),
      `auto_minor_version_upgrade` (true), `parameter_family` (null →
      resolved), `final_snapshot_identifier` (null), `skip_final_snapshot`
      (false), `performance_insights_enabled` (false),
      `enhanced_monitoring_interval` (0), `enhanced_monitoring_role_arn` (null),
      `promotion_tier` (0 — the writer is tier 0), `tags` (`{}`).
- [x] Each variable: `description` + `type` + `default` (optional only) +
      `nullable` AFTER `validation` (custom tflint rule).
- [x] Single-variable validations: `engine` (`^aurora-(postgresql|mysql)$`);
      `engine_version` if non-null (`^(\d+\.\d+|\d+)$`); `identifier_prefix`
      (`^[a-z][a-z0-9-]{0,61}[a-z0-9]$`); `allowed_consumer_sg_ids` (each
      `^sg-[a-f0-9]+$`); `backup_retention_period` in `[1,35]`;
      `enhanced_monitoring_interval` in `{0,1,5,10,15,30,60}`; `promotion_tier`
      in `[0,15]`; `storage_type` null or in `["aurora","aurora-iopt1"]` (Q4);
      `backtrack_window >= 0`.
- [x] Stub `main.tf`, `locals.tf`, `outputs.tf`; `README.md` stub.

#### Success Criteria

- `just tf validate rds/cluster` succeeds; `just tf fmt rds/cluster` clean.
- `just tf lint rds/cluster` passes the custom rules (unused-* warnings clear
  at Phase 6/7).
- `just tf docs rds/cluster` renders the input table into `USAGE.md`.

---

### Phase 2: Data sources and locals (Aurora parameter-family map)

Wire the VPC remote-state read and the Aurora family / port maps — identical
mechanism to `serverless`.

#### Tasks

- [x] `main.tf`: `data.terraform_remote_state.vpc` (`backend = "s3"`,
      `use_path_style = true`, key
      `${var.region}/vpc/${var.vpc_name}/terraform.tfstate`; consumes `vpc_id`
      + `private_subnet_ids`).
- [x] `locals.tf`:
  - `kms_key_arn = coalesce(var.kms_key_arn, try(aws_kms_key.this[0].arn, null))`.
  - `parameter_family_map` for the Aurora engines, seeded to match the shipped
    `serverless` module post-PR-#32 (Q2): `aurora-postgresql:18/17/16` +
    `aurora-mysql:8.0` at minimum.
  - `default_major_map = { "aurora-postgresql"="18", "aurora-mysql"="8.0" }`
    (Q2 — one version posture across the Aurora modules).
  - `engine_major` / `resolved_parameter_family` — same expressions as
    `serverless`.
  - `engine_default_port_map = { "aurora-postgresql"=5432, "aurora-mysql"=3306 }`;
    `engine_default_port`.
  - `kms_alias_name = "alias/${var.identifier_prefix}-rds-cluster"`.

#### Success Criteria

- `just tf validate rds/cluster` succeeds; `just tf fmt rds/cluster` clean.
- A `tests/` smoke run with stub VPC outputs resolves all data sources +
  computed locals.

---

### Phase 3: KMS key (managed-or-BYO, prevent-destroy)

Verbatim from `serverless`, alias renamed to `-rds-cluster`.

#### Tasks

- [x] `kms.tf`: `aws_kms_key.this` (`count = var.kms_key_arn == null ? 1 : 0`,
      rotation, 30-day window, `prevent_destroy`, description names the cluster)
      + `aws_kms_alias.this` (same gate, `name = local.kms_alias_name`).
- [x] Verify `local.kms_key_arn` resolves in both modes.

#### Success Criteria

- `just tf validate rds/cluster` succeeds.
- Managed mode → 1 key + 1 alias; BYO → 0 KMS resources + BYO ARN referenced.

---

### Phase 4: Subnet group and security group

Verbatim from `serverless`; name suffix `-rds-cluster`.

#### Tasks

- [ ] `network.tf`: `aws_db_subnet_group.this` (over `private_subnet_ids`);
      `aws_security_group.this` (in `vpc_id`); one
      `aws_vpc_security_group_ingress_rule.consumer` per
      `var.allowed_consumer_sg_ids` on `local.engine_default_port`; one
      all-outbound `aws_vpc_security_group_egress_rule.all`.

#### Success Criteria

- `just tf validate rds/cluster` succeeds; `just tf lint rds/cluster` passes.
- 2 consumers → 2 ingress rules; empty → 0; `aurora-mysql` → port 3306.

---

### Phase 5: Parameter groups (cluster and instance)

Aurora needs both an `aws_rds_cluster_parameter_group` and an
`aws_db_parameter_group`, both resolved against `local.resolved_parameter_family`
— verbatim from `serverless`.

#### Tasks

- [ ] `parameter_groups.tf`: `aws_rds_cluster_parameter_group.this`
      (`name_prefix = "${var.identifier_prefix}-cluster-"`,
      `create_before_destroy`) + `aws_db_parameter_group.this`
      (`name_prefix = "${var.identifier_prefix}-instance-"`,
      `create_before_destroy`), both `family = local.resolved_parameter_family`.
- [ ] No custom `parameter` blocks in v1 (operators repoint
      `var.parameter_family`).

#### Success Criteria

- `just tf validate rds/cluster` succeeds.
- Both groups resolve `family = local.resolved_parameter_family`.
- An unresolvable engine + version + null `parameter_family` surfaces the
  Phase 6 precondition error.

---

### Phase 6: The Aurora provisioned cluster resource

The core edit vs `serverless`: `aws_rds_cluster` with **no**
`serverlessv2_scaling_configuration` block, plus the Aurora-specific optional
surface (`storage_type`, `backtrack_window`, `enabled_cloudwatch_logs_exports`).

#### Tasks

- [ ] `cluster.tf`: `aws_rds_cluster.this` (alphabetical attribute order):
  - `cluster_identifier = var.identifier_prefix`, `database_name`, `engine`,
    `engine_mode = "provisioned"`, `engine_version` (null OK).
  - `db_cluster_parameter_group_name`, `db_subnet_group_name`,
    `vpc_security_group_ids = [aws_security_group.this.id]`.
  - `storage_encrypted = true`, `kms_key_id = local.kms_key_arn`,
    `master_user_secret_kms_key_id = local.kms_key_arn`.
  - `manage_master_user_password`, `master_username`,
    `iam_database_authentication_enabled`.
  - `backup_retention_period`, `preferred_backup_window`,
    `preferred_maintenance_window`, `deletion_protection`,
    `skip_final_snapshot`, `final_snapshot_identifier`, `apply_immediately`.
  - `storage_type` (Q3-design), `enabled_cloudwatch_logs_exports` (Q6-design),
    `backtrack_window` (Q4-design).
  - **No** `serverlessv2_scaling_configuration`, **no** `min_acu` / `max_acu`.
- [ ] `lifecycle.precondition`s on `aws_rds_cluster.this`:
      `local.resolved_parameter_family != null`; `var.skip_final_snapshot ||
      var.final_snapshot_identifier != null`; **the Backtrack guard (Q3):**
      `var.backtrack_window == 0 || var.engine == "aurora-mysql"`.

#### Success Criteria

- `just tf validate rds/cluster` succeeds; `just tf lint rds/cluster` passes.
- Plan asserts: `engine_mode = "provisioned"`, **no** serverless scaling block,
  `storage_encrypted = true`, `deletion_protection = true`,
  `manage_master_user_password = true`, `master_username = "admin"`.
- The Backtrack guard fails a plan with `backtrack_window > 0` +
  `engine = "aurora-postgresql"` (asserted in Phase 9).

---

### Phase 7: The writer cluster instance

Exactly one `aws_rds_cluster_instance.writer` with a **real** `instance_class`
(the second edit vs `serverless`).

#### Tasks

- [ ] `instance.tf`: `aws_rds_cluster_instance.writer`:
  - `cluster_identifier = aws_rds_cluster.this.id`,
    `identifier = "${var.identifier_prefix}-1"` (Q7 — `-1` suffix leaves room
    for `read-replica`'s `-replica-<key>` naming).
  - `instance_class = var.instance_class` (a real class — DESIGN-0013 Q2).
  - `engine = aws_rds_cluster.this.engine`,
    `engine_version = aws_rds_cluster.this.engine_version` (from the cluster —
    single source of truth, no drift).
  - `db_subnet_group_name`, `db_parameter_group_name`.
  - `promotion_tier = var.promotion_tier` (default 0 — the writer),
    `publicly_accessible`, `apply_immediately`, `auto_minor_version_upgrade`.
  - `performance_insights_enabled` + `performance_insights_kms_key_id`
    (conditional on the module key); `monitoring_interval` +
    `monitoring_role_arn`.
  - `lifecycle.precondition`: `var.enhanced_monitoring_interval == 0 ||
    var.enhanced_monitoring_role_arn != null`.

#### Success Criteria

- `just tf validate rds/cluster` succeeds.
- Plan asserts `instance_class = var.instance_class` (a real class, NOT
  `db.serverless`); `engine` / `engine_version` flow from the cluster.

---

### Phase 8: Outputs (source-of-truth contract plus proxy composition)

The output surface serves two consumers — `read-replica` and `proxy` — and
must be a superset of both. Once published, renaming an output breaks
consumers.

#### Tasks

- [ ] `outputs.tf` (each with a `description`): `cluster_identifier`,
      `cluster_resource_id`, `cluster_endpoint`, `reader_endpoint`, `port`,
      `engine`, `engine_version_actual`, `db_subnet_group_name`,
      `security_group_id`, `kms_key_arn`, `master_user_secret_arn`,
      `db_cluster_parameter_group_name`, `db_parameter_group_name`,
      `cluster_instance_identifier`.
- [ ] The proxy-composition set (same null-safe expressions as `serverless`):
      `db_subnet_ids`, `vpc_id`, `master_user_secret_kms_key_arn`,
      `iam_database_authentication_enabled`.
- [ ] Cross-check the `read-replica` consumer set (`cluster_identifier`,
      `cluster_resource_id`, `engine`, `engine_version_actual`,
      `db_subnet_group_name`, `db_parameter_group_name`) is all present — these
      are IMPL-0013's hard dependency.
- [ ] Regenerate `USAGE.md`.

#### Success Criteria

- Every output has a description; the proxy set matches `serverless`'s names.
- The `read-replica` consumer set is present (blocks IMPL-0013 otherwise).
- `USAGE.md` current.

---

### Phase 9: Plan-only terraform test suite

The gate (ADR-0013 / RFC-0001). VPC remote state stubbed via `override_data`;
BYO KMS in the shared `variables{}`.

#### Tasks

- [ ] `tests/default.tftest.hcl` — one run per engine (`aurora-postgresql` +
      `aurora-mysql`): engine, `engine_mode = "provisioned"`, **no** serverless
      scaling block (`length(serverlessv2_scaling_configuration) == 0`),
      `instance_class` is the real class, `storage_encrypted`,
      `deletion_protection`, `manage_master_user_password`, parameter-family
      resolution, and the four proxy-composition outputs.
- [ ] `tests/kms.tftest.hcl` — managed-KMS count + BYO-KMS.
- [ ] `tests/parameter_family_resolution.tftest.hcl` — engine + version →
      family; explicit override wins.
- [ ] `tests/sg_ingress.tftest.hcl` — 2 / 0 / mysql-port ingress shapes.
- [ ] `tests/validation.tftest.hcl` with `expect_failures`: bad `engine`
      (`postgres`), bad `engine_version`, bad `backup_retention_period`,
      snapshot-required precondition, bad `identifier_prefix`,
      monitoring-role-required precondition, **Backtrack-on-postgres**
      precondition (`backtrack_window > 0` + `aurora-postgresql`), bad
      `storage_type`.
- [ ] All files open with the fake `provider "aws"` block.

#### Success Criteria

- `just tf test rds/cluster` passes all runs in < 5s.
- Coverage: both engines, BYO + managed KMS, ingress shapes, all validation
  negatives incl. the Backtrack guard.
- `just tf all rds/cluster` green.

---

### Phase 10: Pro-gated apply suite and FINDINGS

Opt-in apply per RFC-0001. Aurora provisioned clusters reliably need LocalStack
Pro's native RDS provider, so per **Q5 (resolved b)** the apply is **Pro-gated:
off by default, in `tests-localstack-pro/`** (run via
`just tf test-localstack-pro rds/cluster`, the `proxy` layout), with a
Community-safe `plan_smoke` in `tests-localstack/`. The `_tf-test-localstack-pro`
justfile recipe already exists (IMPL-0010) — no justfile change needed.

#### Tasks

- [ ] `tests-localstack/plan_smoke.tftest.hcl` — always-on, Community-safe
      plan-only smoke (VPC stubbed via `override_data`; no cluster apply).
- [ ] `tests-localstack-pro/fixtures/setup/main.tf` — VPC + 3 private subnets +
      S3 bucket with a stub VPC state file (sibling fixture shape).
- [ ] `tests-localstack-pro/apply_pro.tftest.hcl`: `run "setup"`;
      `run "apply_default"` (`aurora-postgresql`) provisioning the full
      provisioned cluster + writer (pin `engine_version` if PG 18 is newer than
      the LocalStack image); `run "plan_mysql"` (`aurora-mysql`) plan-only.
- [ ] Confirm the `_tf-test-localstack-pro` recipe scans `rds/cluster`.
- [ ] `tests-localstack/FINDINGS.md` — coverage matrix, the Pro requirement +
      the two-tier layout + recipe gate, the macOS named-volume caveat
      (embedded Postgres). Cross-reference the `serverless` + `proxy` FINDINGS.

#### Success Criteria

- With the flag on (Pro): `just tf test-localstack-pro rds/cluster` provisions
  and asserts the full provisioned cluster + writer.
- With the flag off (default): `just tf test-localstack rds/cluster` runs only
  `plan_smoke` (offline, Community-green).
- `FINDINGS.md` documents the Pro requirement + the enable-flag + the macOS
  caveat.
- Wall-clock < 90s (Pro apply).

---

### Phase 11: README, USAGE, CLAUDE.md, and docz closeout

#### Tasks

- [ ] Author `modules/rds/cluster/README.md`: prerequisites, minimal Postgres /
      MySQL / BYO-KMS / I/O-Optimized (`storage_type`) examples, post-apply
      smoke recipe, operational gotchas (`deletion_protection`, KMS
      `prevent_destroy`, engine-major upgrade), **a "scaling out" pointer to
      `read-replica` (IMPL-0013)** with the composition state key.
- [ ] Regenerate `USAGE.md`.
- [ ] Update `CLAUDE.md`: add `modules/rds/cluster` to the §Repository purpose
      `rds` inventory + a shape line (source-of-truth for read-replica; valid
      `aurora-cluster` proxy target); regenerate the README module table.
- [ ] Mark IMPL-0012 `Completed`, run `docz update`, move DESIGN-0013 to
      `Implemented`.
- [ ] `just docs lint` clean for the new docs.

#### Success Criteria

- `just tf all rds/cluster` green; `README.md` + `USAGE.md` current.
- `CLAUDE.md` inventory + shape updated; README table regenerated.
- IMPL-0012 `Completed`; DESIGN-0013 `Implemented`; docz index regenerated.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/rds/cluster/versions.tf` | Create | `aws ~> 6.2`, terraform `>= 1.1` |
| `modules/rds/cluster/.terraform-docs.yml` | Create | copied from serverless |
| `modules/rds/cluster/.tflint.hcl` | Create | copied from serverless |
| `modules/rds/cluster/variables.tf` | Create | input surface (no min/max acu; + instance_class, storage_type, backtrack_window, logs exports) |
| `modules/rds/cluster/locals.tf` | Create | KMS coalesce, Aurora family map, port map |
| `modules/rds/cluster/main.tf` | Create | `data.terraform_remote_state.vpc` |
| `modules/rds/cluster/kms.tf` | Create | gated `aws_kms_key` + alias |
| `modules/rds/cluster/network.tf` | Create | subnet group + SG + granular rules |
| `modules/rds/cluster/parameter_groups.tf` | Create | cluster + instance parameter groups |
| `modules/rds/cluster/cluster.tf` | Create | `aws_rds_cluster` (provisioned, no scaling block) + preconditions |
| `modules/rds/cluster/instance.tf` | Create | `aws_rds_cluster_instance.writer` |
| `modules/rds/cluster/outputs.tf` | Create | read-replica contract + 4 proxy outputs |
| `modules/rds/cluster/README.md` | Create | operator doc + read-replica pointer |
| `modules/rds/cluster/USAGE.md` | Create | terraform-docs generated |
| `modules/rds/cluster/tests/*.tftest.hcl` | Create | plan-only suite (~5 files) |
| `modules/rds/cluster/tests-localstack/*` | Create | Community `plan_smoke` + FINDINGS |
| `modules/rds/cluster/tests-localstack-pro/*` | Create | Pro apply suite + fixture (off by default) |
| `CLAUDE.md` | Modify | add `modules/rds/cluster` inventory + shape |
| `README.md` | Modify | module table regen |
| `docs/impl/README.md` | Modify | docz regen |
| `docs/design/0013-...md` | Modify | status → Implemented at closeout |

## Testing Plan

- **Plan-only `terraform test` (`tests/`)** — the gate (Phase 9): both engines,
  BYO + managed KMS, SG ingress shapes, parameter-family resolution, all
  validation negatives incl. the Backtrack guard. Remote state stubbed via
  `override_data`.
- **`tests-localstack-pro/` apply suite** — Pro-gated, off by default (Phase
  10, Q5-b); Community runs only the `tests-localstack/` `plan_smoke`.
- **No libtftest Go suite** — per ADR-0013; runtime invariants are RFC-0001
  §Phase 3 backlog.

## Dependencies

- [DESIGN-0013](../design/0013-rds-aurora-provisioned-cluster-module.md) — the
  source contract (all OQs resolved, `a`).
- **`modules/rds/serverless` (IMPL-0007, shipped)** — the scaffolding this
  module forks; the Aurora family-map majors + proxy-output names are matched
  against it (post-PR-#32 version posture).
- **The fleet VPC module** — must exist + be applied + writing state to S3.
- `hashicorp/aws ~> 6.2` (fleet pin) — `aws_rds_cluster` +
  `aws_rds_cluster_instance` available.
- **Blocks `read-replica` (IMPL-0013)** — this module must merge first and pin
  its output names; IMPL-0013's remote-state read is a hard dependency on them.
- **LocalStack Pro** — required for the Phase 10 apply suite (Aurora's native
  RDS provider); Community runs only the `tests-localstack/` `plan_smoke` (Q5-b).

## Open Questions

Implementation-level decisions the design left open. All seven were resolved
2026-07-09 (Q1–Q4, Q6, Q7 = **a**; Q5 = **b**). Each heading records the chosen
option; the **Resolved** line states the decision, and the alternatives are
retained for the record.

### Q1 — Fork mechanics — RESOLVED (a)

**Resolved: a.** Copy `modules/rds/serverless/` wholesale, then apply the two
edits (drop the scaling block + `min_acu`/`max_acu`; add `instance_class` + the
Aurora optional surface) and rename `-rds-serverless` → `-rds-cluster`. Keeps a
reviewable diff against the battle-tested module.

How do we produce the `cluster` module from `serverless`?

- **a (chosen):** **Copy `modules/rds/serverless/` wholesale, then apply
  the two edits** (delete `serverlessv2_scaling_configuration` + `min_acu` /
  `max_acu`; add `instance_class` + the Aurora optional surface) and rename the
  `-rds-serverless` suffixes to `-rds-cluster`. Minimizes divergence — the
  battle-tested KMS/SG/subnet-group/parameter-group/precondition code carries
  over unchanged, and a `diff` against `serverless` stays reviewable.
- **b:** Hand-author each file from the design — cleaner slate, but re-derives
  proven code and loses the reviewable-diff property.
- **other:** ______

### Q2 — Aurora parameter-family majors to seed — RESOLVED (a)

**Resolved: a.** Seed to match the shipped `serverless` module post-PR-#32 —
`aurora-postgresql = "18"`, `aurora-mysql = "8.0"` (rows for
`aurora-postgresql:18/17/16` + `aurora-mysql:8.0`) — so the Aurora family shares
one version posture.

Which default majors does `local.default_major_map` seed?

- **a (chosen):** **Match the shipped `serverless` module post-PR-#32** —
  `aurora-postgresql = "18"`, `aurora-mysql = "8.0"` — so the whole Aurora
  family shares one version posture and the family-map lookups are consistent.
  Seed `aurora-postgresql:18/17/16` + `aurora-mysql:8.0` rows.
- **b:** Seed only the majors this module's tests exercise and let Renovate add
  the rest — smaller map, but drifts from `serverless`.
- **c:** Re-probe `aws rds describe-db-engine-versions` at IMPL time and seed
  whatever is newest-GA then — most current, but risks diverging from
  `serverless` again (another lockstep bump).
- **other:** ______

### Q3 — Backtrack engine-guard placement — RESOLVED (a)

**Resolved: a.** A `lifecycle.precondition` on `aws_rds_cluster.this` —
`var.backtrack_window == 0 || var.engine == "aurora-mysql"` — consistent with
the validation-split doctrine; fails the plan legibly for Backtrack on postgres.

`backtrack_window` is Aurora-MySQL-only; the guard is a cross-variable check
(`engine == "aurora-mysql"`), which Terraform `>= 1.1` can't express as a
variable validation. Where does it live?

- **a (chosen):** A **`lifecycle.precondition` on `aws_rds_cluster.this`**
  — `var.backtrack_window == 0 || var.engine == "aurora-mysql"` — consistent
  with every other cross-variable check in the family (the validation-split
  doctrine). Fails the plan legibly for `backtrack_window > 0` on postgres.
- **b:** Silently ignore `backtrack_window` for non-mysql engines (pass it
  through and let AWS reject it) — smaller code, but a confusing apply-time
  error instead of a clear plan-time one.
- **other:** ______

### Q4 — Aurora storage-type validation set — RESOLVED (a)

**Resolved: a.** The variable validation allows `null` or one of
`["aurora","aurora-iopt1"]`, with a clear `error_message` — rejects typos at
plan time.

`var.storage_type` defaults to `null` (Aurora Standard) and opts into
`aurora-iopt1`. What does the variable validation allow?

- **a (chosen):** Allow **`null` or one of `["aurora","aurora-iopt1"]`**
  (`"aurora"` is the explicit Standard value; `null` also means Standard). A
  clear `error_message` naming the two valid strings. Rejects typos at plan
  time.
- **b:** No validation — pass `var.storage_type` straight through and let AWS
  reject bad values at apply. Smaller surface, worse ergonomics.
- **other:** ______

### Q5 — Apply-suite LocalStack tier — RESOLVED (b)

**Resolved: b.** Put the Aurora apply in `tests-localstack-pro/` (off by
default, run via `just tf test-localstack-pro rds/cluster`) and leave a
Community-safe `plan_smoke` in `tests-localstack/` — the `proxy` layout. Aurora
provisioned clusters need LocalStack Pro's native RDS provider in practice, so
gating the apply behind the Pro recipe keeps the default
`just tf test-localstack rds/cluster` green on Community and makes the Pro
requirement explicit. Phase 10 reflects this two-tier split.

Aurora needs LocalStack Pro's native RDS provider in practice, yet `serverless`
keeps its (Pro-verified) apply in `tests-localstack/`, not
`tests-localstack-pro/`. Where does `cluster`'s apply live?

- **a (recommended, not chosen):** **`tests-localstack/`, mirroring
  `serverless`** — tier-agnostic by construction; the recipe runs the same
  suite on whichever tier is present, and `FINDINGS.md` records the tier it was
  verified on. Reserve `tests-localstack-pro/` for genuinely Pro-*only* surfaces
  (proxy, read-replica's cross-state bridge) that must never run under the
  default recipe.
- **b (chosen):** Put the apply in `tests-localstack-pro/` and leave a Community
  `plan_smoke` in `tests-localstack/` (the `proxy` layout) — more explicit
  about the Pro requirement, and keeps the default Community recipe green for a
  surface that reliably needs Pro's native RDS provider.
- **other:** ______

### Q6 — MySQL coverage layout — RESOLVED (a)

**Resolved: a.** Both engines from the start, in one plan-only suite (the
resource graph is engine-agnostic; family + port differ only). Matches
`serverless`; `apply_default` is Postgres, MySQL gets plan coverage.

Fast-follow phase or both engines from the start?

- **a (chosen):** **Both engines from the start**, in one plan-only suite
  — the resource graph is engine-agnostic (family + port differ only). Matches
  `serverless`; `apply_default` is Postgres, MySQL gets plan coverage.
- **b:** A dedicated MySQL fast-follow phase (the `proxy` layout) — cleaner
  commit boundary, redundant here (no MySQL-specific resource work).
- **other:** ______

### Q7 — Writer instance identifier suffix — RESOLVED (a)

**Resolved: a.** `identifier = "${var.identifier_prefix}-1"` — the `-1` suffix
reserves a clean namespace for `read-replica`'s `${prefix}-replica-<key>`
readers and reads as "instance 1 (the writer)".

How is the single writer instance named?

- **a (chosen):** `identifier = "${var.identifier_prefix}-1"` — the `-1`
  suffix reserves a clean namespace for `read-replica`'s
  `${prefix}-replica-<key>` readers and reads as "instance 1 (the writer)".
- **b:** `identifier = var.identifier_prefix` (no suffix) — simplest, but
  collides conceptually with the cluster identifier and leaves no room for a
  numbered instance convention.
- **other:** ______

## References

- [DESIGN-0013](../design/0013-rds-aurora-provisioned-cluster-module.md) — the design this IMPL implements (all OQs resolved, `a`).
- [DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS module family layout (parent design + rollout order).
- [DESIGN-0014](../design/0014-rds-aurora-read-replica-module.md) — Aurora read-replica (the primary consumer of this module's remote-state contract; IMPL-0013 must merge after this).
- [DESIGN-0010](../design/0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md) — RDS Proxy (this cluster is a valid `target_type = "aurora-cluster"`).
- [IMPL-0007](0007-aurora-serverless-v2-module-implementation.md) — Aurora Serverless v2 implementation (the scaffolding this module forks).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state` (drives cluster ↔ read-replica).
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants.
- [ADR-0017](../adr/0017-rds-blue-green-deployments-are-opt-in-and-default-off.md) — RDS Blue/Green opt-in, default off.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy.
- [`aws_rds_cluster` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster).
- [`aws_rds_cluster_instance` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance).
