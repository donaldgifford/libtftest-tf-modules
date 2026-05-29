---
id: IMPL-0008
title: "EFS filesystem module implementation"
status: Draft
author: Donald Gifford
created: 2026-05-28
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0008: EFS filesystem module implementation

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-28

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Module scaffolding + variable surface](#phase-1-module-scaffolding--variable-surface)
  - [Phase 2: Data sources + locals](#phase-2-data-sources--locals)
  - [Phase 3: KMS key (gated BYO with prevent_destroy)](#phase-3-kms-key-gated-byo-with-prevent_destroy)
  - [Phase 4: Security group + ingress/egress rules](#phase-4-security-group--ingressegress-rules)
  - [Phase 5: EFS filesystem + mount targets](#phase-5-efs-filesystem--mount-targets)
  - [Phase 6: Access points (`for_each` over `var.access_points`)](#phase-6-access-points-for_each-over-varaccess_points)
  - [Phase 7: Backup policy (gated)](#phase-7-backup-policy-gated)
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

Ship `modules/efs/filesystem` — the AWS-API companion to the EKS
addons module's already-installed `aws-efs-csi-driver` (IMPL-0003).
Provisions an `aws_efs_file_system` with module-managed KMS
encryption, one `aws_efs_mount_target` per VPC private subnet, a
security group granting NFS (TCP 2049) ingress from the EKS node SG
via cluster remote state, an optional declarative
`aws_efs_access_point` map, and an optional backup policy.

**Implements:** [DESIGN-0008](../design/0008-efs-module-layout-for-efs-csi-on-eks.md)

## Scope

### In Scope

- `modules/efs/filesystem/` — single sub-module under a new
  `modules/efs/` parent. (The `filesystem/` sub-directory leaves
  room for future siblings like `modules/efs/replica/` if cross-
  region replication ever lands.)
- AWS resources: KMS key (gated BYO), filesystem, mount targets
  (for_each over `private_subnet_ids`), security group + granular
  SG rules, optional access points (for_each over typed map),
  optional backup policy.
- Cross-module composition via **two** remote-state reads
  (VPC + EKS cluster) per DESIGN-0008 Q1 resolution.
- `terraform test` plan-only suite covering BYO KMS, mount-target
  count, access-point map resolution, lifecycle policy, validation
  negatives.
- `tests-localstack/` apply suite with VPC + EKS state-stub fixture
  (DESIGN-0008 Q11 resolution — both ship at v1).
- README documenting prereqs, instantiation patterns, the
  static-provisioning PV manifest snippet for consumers.

### Out of Scope

- PV / PVC / StorageClass Kubernetes manifests (delivered out-of-
  band per ADR-0011).
- EFS CSI driver installation, driver IAM role, and Pod Identity
  Association — already in `modules/eks/addons` when
  `var.efs_csi_enabled = true`.
- Cross-region replication (`aws_efs_replication_configuration`).
- Cross-account filesystem sharing
  (`aws_efs_file_system_policy` with explicit principals).
- AWS Backup vault provisioning — module just toggles the backup
  policy; the default vault is AWS-managed.
- Future EFS-related modules (replica, access-point-only, etc.).

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all
its tasks are checked off, its success criteria are met, and a
conventional commit has landed.

Quality gates per the donald-loop directive:

- After each task: `just tf fmt efs/filesystem`, `just tf lint
  efs/filesystem`, `just tf validate efs/filesystem`.
- After each phase: `terraform test` plan-only suite must pass for
  any phase that touched HCL with a corresponding test.
- Conventional commit per numbered task.

---

### Phase 1: Module scaffolding + variable surface

Establish the file layout (`main.tf`, `variables.tf`, `versions.tf`,
`locals.tf`, `outputs.tf`, `.tflint.hcl`, `.terraform-docs.yml`,
`README.md` stub) and the full input contract. No resources yet —
just the surface area + validations.

#### Tasks

- [x] Create `modules/efs/` directory; create `modules/efs/filesystem/`
      sub-directory; copy scaffolding files verbatim from
      `modules/rds/serverless/` (`.terraform-docs.yml`,
      `.tflint.hcl`) per the per-module conventions in CLAUDE.md.
- [x] Author `versions.tf` pinning `hashicorp/aws ~> 6.2`,
      Terraform `>= 1.1`.
- [x] Author `variables.tf` with the full DESIGN-0008 input
      contract:
  - Required: `region`, `remote_state_bucket`, `vpc_name`,
    `cluster_name`, `identifier_prefix`.
  - Optional: `kms_key_arn` (default null), `performance_mode`
    (default `"generalPurpose"` per Q2), `throughput_mode` (default
    `"elastic"` per Q3), `provisioned_throughput_in_mibps` (default
    null), `lifecycle_policy` (object with IA-30d + Archive-90d
    defaults per Q4 — see Open Question Q2 for exact shape),
    `additional_allowed_consumer_sg_ids` (default `[]`),
    `backup_policy_enabled` (default false per Q7),
    `access_points` (default `{}` per Q6 — see Open Question Q3
    for inner shape), `tags` (default `{}`).
- [x] Each variable carries `description`, `type`, `default`
      (optional only), `validation` block where shape-constrained,
      and `nullable = false` AFTER `validation` per the custom
      tflint `variable_attribute_order` rule (sibling pattern in
      `modules/rds/serverless/variables.tf`).
- [x] Validation blocks for:
  - `identifier_prefix`: regex shape
    (`^[a-z][a-z0-9-]{0,61}[a-z0-9]$` — same as RDS serverless)
    AND length ≤ 64 (EFS `creation_token` max).
  - `performance_mode`: regex `^(generalPurpose|maxIO)$`.
  - `throughput_mode`: regex `^(bursting|elastic|provisioned)$`.
  - `provisioned_throughput_in_mibps`: null OR
    `>= 1 && <= 4096` (EFS provisioned throughput bounds).
  - `additional_allowed_consumer_sg_ids`: each entry matches
    `^sg-[a-f0-9]+$`.
  - `access_points`: per Open Question Q3 / Q4 (POSIX UID/GID
    bounds).
- [x] Stub `main.tf`, `locals.tf`, `outputs.tf` with header
      comments (resources land in Phase 2+).
- [x] Create `modules/efs/filesystem/README.md` stub (one-line
      pointer to `USAGE.md`).

#### Success Criteria

- `just tf validate efs/filesystem` succeeds.
- `just tf fmt efs/filesystem` reports no diffs.
- Custom tflint rules pass (zero
  `terraform_tautological_naming` / `variable_attribute_order`
  violations); stock `terraform_unused_declarations` warnings on
  vars wired in later phases are expected.
- `terraform-docs .` renders all inputs into `USAGE.md`.

---

### Phase 2: Data sources + locals

Wire `data.terraform_remote_state.vpc` + `data.terraform_remote_state.eks`
per DESIGN-0008 Q1 resolution; populate `locals.tf` with the KMS
coalesce + the NFS port literal.

#### Tasks

- [x] Add `data.terraform_remote_state.vpc` with `backend = "s3"`,
      `use_path_style = true`, key
      `${var.region}/vpc/${var.vpc_name}/terraform.tfstate`.
      Consumed outputs: `private_subnet_ids`, `vpc_id` (see Open
      Question Q1).
- [x] Add `data.terraform_remote_state.eks` with `backend = "s3"`,
      `use_path_style = true`, key
      `${var.region}/eks/${var.cluster_name}/terraform.tfstate`.
      Consumed output: `node_security_group_id`.
- [x] Populate `locals.tf`:
  - `kms_key_arn = coalesce(var.kms_key_arn, try(aws_kms_key.this[0].arn, null))`
    — same coalesce-with-`try()` pattern as
    `modules/rds/serverless/locals.tf`. Keeps Phase 2 plan-valid
    before Phase 3's KMS resource lands.
  - `kms_alias_name = "alias/${var.identifier_prefix}-efs"`.
  - `nfs_port = 2049` (literal — single port; no engine-port map
    needed unlike RDS).
- [x] Reference data-source + local values at the use site (no
      aliasing locals for plain passthroughs per ADR-0001 /
      CLAUDE.md).

#### Success Criteria

- `just tf validate efs/filesystem` succeeds.
- `just tf fmt efs/filesystem` clean.

---

### Phase 3: KMS key (gated BYO with prevent_destroy)

Mirror the rds-serverless / org-registry / cluster module pattern
per DESIGN-0008 Q5 + IMPL Open Question Q6 resolution.

#### Tasks

- [x] Create `modules/efs/filesystem/kms.tf`:
  - `aws_kms_key.this` with `count = var.kms_key_arn == null ? 1 : 0`,
    `description = "KMS key for EFS filesystem ${var.identifier_prefix} encryption at rest"`,
    `enable_key_rotation = true`,
    `deletion_window_in_days = 30`,
    `tags = var.tags`,
    `lifecycle { prevent_destroy = true }`.
  - `aws_kms_alias.this` with same count gate;
    `name = local.kms_alias_name`,
    `target_key_id = aws_kms_key.this[0].key_id`.
- [x] Verify `local.kms_key_arn` resolves correctly in BOTH modes
      (BYO short-circuits; module-managed resolves to managed key's
      ARN at plan).

#### Success Criteria

- `just tf validate efs/filesystem` succeeds.
- Test fixture (Phase 9): `var.kms_key_arn = null` creates 1 KMS
  key + 1 alias; non-null creates 0.

---

### Phase 4: Security group + ingress/egress rules

DB-tier SG with NFS ingress from the EKS node SG (via cluster
remote state) and optional additional consumer SGs.

#### Tasks

- [x] Create `modules/efs/filesystem/network.tf`:
  - `aws_security_group.this`:
    - `name = "${var.identifier_prefix}-efs"`.
    - `description = "EFS filesystem ${var.identifier_prefix} security group"`.
    - `vpc_id = data.terraform_remote_state.vpc.outputs.vpc_id`.
    - `tags = var.tags`.
  - `aws_vpc_security_group_ingress_rule.from_nodes`:
    - `security_group_id = aws_security_group.this.id`.
    - `referenced_security_group_id = data.terraform_remote_state.eks.outputs.node_security_group_id`.
    - `from_port = local.nfs_port`, `to_port = local.nfs_port`,
      `ip_protocol = "tcp"`.
    - `description = "NFS ingress from EKS node SG"`.
    - `tags = var.tags`.
  - `aws_vpc_security_group_ingress_rule.from_extra` — `for_each`
    over `toset(var.additional_allowed_consumer_sg_ids)`;
    `referenced_security_group_id = each.value`,
    `from_port` / `to_port` / `ip_protocol` = same NFS triplet;
    `description = "NFS ingress from additional consumer SG ${each.value}"`,
    `tags = var.tags`.
  - `aws_vpc_security_group_egress_rule.all`:
    - `security_group_id = aws_security_group.this.id`,
      `cidr_ipv4 = "0.0.0.0/0"`,
      `ip_protocol = "-1"`,
      `description = "All-outbound egress for AWS API endpoints"`,
      `tags = var.tags`.
- [x] Granular SG rule resources (not inline ingress/egress on the
      SG itself) per the EKS-cluster / rds-serverless pattern.

#### Success Criteria

- `just tf validate efs/filesystem` succeeds.
- Test fixture (Phase 9): two-entry
  `additional_allowed_consumer_sg_ids` list produces exactly 2
  extra `from_extra` rules + 1 `from_nodes` rule + 1 egress rule.

---

### Phase 5: EFS filesystem + mount targets

The core resources: the filesystem itself + one mount target per
VPC private subnet (per DESIGN-0008 Q9 resolution — all subnets,
max availability).

#### Tasks

- [x] Create `modules/efs/filesystem/filesystem.tf`:
  - `aws_efs_file_system.this`:
    - `creation_token = var.identifier_prefix` (per DESIGN-0008 Q10).
    - `encrypted = true`.
    - `kms_key_id = local.kms_key_arn`.
    - `performance_mode = var.performance_mode`.
    - `throughput_mode = var.throughput_mode`.
    - `provisioned_throughput_in_mibps = var.provisioned_throughput_in_mibps`.
    - `tags = var.tags`.
    - Dynamic `lifecycle_policy` blocks resolved from
      `var.lifecycle_policy` — one block per non-null transition
      attribute (see Open Question Q2 for the dynamic block
      shape).
    - `lifecycle.precondition` enforcing
      `var.throughput_mode == "provisioned" iff var.provisioned_throughput_in_mibps != null`
      (cross-variable invariant — terraform 1.1
      `variable.validation` can't reference other vars).
  - Alphabetical attribute ordering per the custom
    `resource_parameter_order` tflint rule (scalar args first, then
    dynamic / lifecycle blocks).
- [x] Create `modules/efs/filesystem/mount_targets.tf`:
  - `aws_efs_mount_target.this`:
    - `for_each = toset(data.terraform_remote_state.vpc.outputs.private_subnet_ids)`.
    - `file_system_id = aws_efs_file_system.this.id`.
    - `subnet_id = each.value`.
    - `security_groups = [aws_security_group.this.id]` per IMPL
      Open Question Q7 resolution.

#### Success Criteria

- `just tf validate efs/filesystem` succeeds.
- Test fixture (Phase 9): 3-entry stub `private_subnet_ids`
  produces exactly 3 mount target resources.
- Precondition negative: `throughput_mode = "bursting"` +
  `provisioned_throughput_in_mibps = 100` rejected at plan.

---

### Phase 6: Access points (`for_each` over `var.access_points`)

Declarative per-PV access points per DESIGN-0008 Q6 resolution.
Empty map (default) produces zero resources.

#### Tasks

- [x] Create `modules/efs/filesystem/access_points.tf`:
  - `aws_efs_access_point.this`:
    - `for_each = var.access_points`.
    - `file_system_id = aws_efs_file_system.this.id`.
    - `posix_user { uid = each.value.posix_user.uid; gid = each.value.posix_user.gid; secondary_gids = each.value.posix_user.secondary_gids; }`
      (secondary_gids per IMPL Open Question Q3 resolution).
    - `root_directory { path = each.value.root_directory.path;
      dynamic "creation_info" { ... } }` — dynamic `creation_info`
      block emits when `each.value.root_directory.creation_info != null`.
    - `tags = merge(var.tags, { Name = each.key })`.

#### Success Criteria

- `just tf validate efs/filesystem` succeeds.
- Test fixture (Phase 9): empty map → 0 access points; 2-entry
  map → 2 access points with the expected `posix_user.uid` per
  key.

---

### Phase 7: Backup policy (gated)

`aws_efs_backup_policy` toggled by `var.backup_policy_enabled`
(default false per DESIGN-0008 Q7).

#### Tasks

- [x] Create `modules/efs/filesystem/backup.tf`:
  - `aws_efs_backup_policy.this`:
    - `count = var.backup_policy_enabled ? 1 : 0`.
    - `file_system_id = aws_efs_file_system.this.id`.
    - `backup_policy { status = "ENABLED" }`.

#### Success Criteria

- `just tf validate efs/filesystem` succeeds.
- Test fixture (Phase 9): default → 0 backup policies; opt-in →
  1 backup policy with `status = "ENABLED"`.

---

### Phase 8: Outputs (consumer contract)

Stable surface; renaming or removing an output breaks downstream
remote-state consumers and PV manifest references.

#### Tasks

- [x] Author `modules/efs/filesystem/outputs.tf`:
  - `filesystem_id` — plugs into `volumeHandle` in PV manifests
    (the `<filesystem_id>::<access_point_id>` shape).
  - `filesystem_arn` — for IAM policies scoped to this filesystem.
  - `dns_name` — `<fs-id>.efs.<region>.amazonaws.com`; consumed by
    non-CSI mounts (EC2, batch jobs).
  - `mount_target_ids` — map keyed by subnet ID.
  - `mount_target_dns_names` — map keyed by subnet ID.
  - `security_group_id` — the EFS SG.
  - `kms_key_arn` — BYO or module-managed transparently via
    `local.kms_key_arn`.
  - `access_point_ids` — map keyed by `var.access_points` map key.
  - `access_point_arns` — same shape.
- [x] Re-run `terraform-docs .` to render outputs into `USAGE.md`.

#### Success Criteria

- `just tf validate efs/filesystem` succeeds.
- Every output has a `description`.
- `USAGE.md` regenerated cleanly.

---

### Phase 9: terraform test plan-only suite

Per ADR-0013 + RFC-0001, the plan-only suite is the baseline. No
LocalStack required; runs in ~1.5s.

#### Tasks

- [ ] Create `modules/efs/filesystem/tests/` directory.
- [ ] Author `tests/default.tftest.hcl`:
  - BYO KMS so `local.kms_key_arn` is plan-known.
  - Asserts: filesystem encrypted, `kms_key_id` flows BYO ARN,
    `performance_mode = "generalPurpose"`, `throughput_mode = "elastic"`,
    one mount target per stub subnet, one SG, one
    `from_nodes` ingress, one egress, zero access points by
    default, zero backup policies by default.
  - `override_data` stubs:
    - `data.terraform_remote_state.vpc` (3 private subnets, 1
      vpc_id).
    - `data.terraform_remote_state.eks` (node_security_group_id).
- [ ] Author `tests/byo_kms.tftest.hcl` — focused BYO shape (zero
      managed KMS resources, BYO ARN flowthrough).
- [ ] Author `tests/managed_kms.tftest.hcl` — `var.kms_key_arn =
      null` produces 1 KMS key + 1 alias.
- [ ] Author `tests/access_points.tftest.hcl`:
  - Empty map → 0 access points.
  - 2-entry map → 2 access points; `posix_user.uid` flows per key;
    `Name` tag = map key.
- [ ] Author `tests/lifecycle_policy.tftest.hcl`:
  - Default → both IA + Archive transition blocks present.
  - `var.lifecycle_policy = null` → zero lifecycle policy blocks.
  - Override `transition_to_ia = "AFTER_60_DAYS"` → only the IA
    block changes.
- [ ] Author `tests/sg_ingress.tftest.hcl`:
  - 2-entry `additional_allowed_consumer_sg_ids` → 2 extra
    ingress rules.
  - Empty list → 0 extra ingress rules (the `from_nodes` rule
    remains).
- [ ] Author `tests/mount_target_count.tftest.hcl`:
  - 3-subnet stub → 3 mount targets.
  - 1-subnet stub → 1 mount target (the cluster-on-single-AZ
    case).
- [ ] Author `tests/backup_policy.tftest.hcl`:
  - Default → 0 backup policies.
  - Opt-in → 1 backup policy, `status = "ENABLED"`.
- [ ] Author `tests/validation.tftest.hcl` with `expect_failures`
      on:
  - `var.identifier_prefix = "InvalidUpperCase"`.
  - `var.identifier_prefix` 65+ chars (over EFS creation_token
    max).
  - `var.performance_mode = "maxThroughput"` (typo).
  - `var.throughput_mode = "invalid"`.
  - `var.provisioned_throughput_in_mibps = 0`.
  - `var.provisioned_throughput_in_mibps = 5000` (> 4096).
  - `var.additional_allowed_consumer_sg_ids = ["NotAnSgId"]`.
  - Cross-var precondition: `throughput_mode = "elastic"` +
    `provisioned_throughput_in_mibps = 100` (filesystem
    lifecycle.precondition fires).
- [ ] All test files supply `override_data` for BOTH remote-state
      data sources so terraform test doesn't try real S3 reads
      before var/precondition validation fires (the IMPL-0007
      Phase 9 lesson).
- [ ] BYO KMS used in any test that asserts on
      `local.kms_key_arn`-dependent attributes (IMPL-0006 lesson).

#### Success Criteria

- `just tf test efs/filesystem` passes all runs.
- Total wall-clock time < 5 seconds.

---

### Phase 10: tests-localstack gap-discovery suite

Per DESIGN-0008 Q11 resolution — ship apply suite with the v1
IMPL. Defaults to LocalStack Community; verifies Pro at
implementation time.

#### Tasks

- [ ] Create `modules/efs/filesystem/tests-localstack/` directory.
- [ ] Create `tests-localstack/fixtures/setup/main.tf` (per IMPL
      Open Question Q8 — recommended path doesn't provision a
      real EKS cluster, just stubs the node SG):
  - VPC + 3 private subnets across 3 AZs.
  - An `aws_security_group.node_stub` resource — its ID is stubbed
    into the EKS state file as `node_security_group_id`.
  - S3 bucket holding TWO stub state files:
    - `<region>/vpc/<vpc_name>/terraform.tfstate` (vpc_id +
      private_subnet_ids outputs).
    - `<region>/eks/<cluster_name>/terraform.tfstate`
      (node_security_group_id output).
  - Sibling pattern: `modules/eks/managed-node-group/tests-localstack/fixtures/setup/main.tf`
    (simplified per Q8 — no real EKS cluster).
- [ ] Probe LocalStack EFS coverage at implementation time:
  - `aws_efs_file_system` (create + KMS encryption).
  - `aws_efs_mount_target` (creation in private subnets — known
    LocalStack edge).
  - `aws_efs_access_point`.
  - `aws_efs_backup_policy` (depends on LocalStack AWS Backup
    support — likely Pro-only).
- [ ] Author `tests-localstack/apply_localstack.tftest.hcl`:
  - `run "setup"` — apply the fixture.
  - `run "apply_default"` — apply the module with default vars +
    one access point in the map (validates the access-point
    surface end-to-end).
  - `run "apply_backup_enabled"` — apply with
    `var.backup_policy_enabled = true` (likely the highest-risk
    surface; gracefully document via IMPL-0005 Phase 9 fallback
    if it 501s).
- [ ] Author `tests-localstack/FINDINGS.md`:
  - Finding #1: EFS coverage matrix (Community + Pro).
  - Finding #2: Backup policy / AWS Backup integration — likely
    Pro-gated; document the tier-specific behavior.
  - Out-of-scope libtftest backlog: actual NFS mount through CSI
    driver, access-point UID enforcement on file ops,
    encryption-in-transit handshake.

#### Success Criteria

- `just tf test-localstack efs/filesystem` either passes
  `apply_default` end-to-end OR falls back to `plan_smoke` with
  a documented FINDINGS.md gap.
- Total wall-clock time < 90 seconds.

---

### Phase 11: README, USAGE, audits, CLAUDE.md update

Final polish.

#### Tasks

- [ ] Expand `modules/efs/filesystem/README.md` with:
  - Prerequisites (VPC stack, EKS cluster stack, S3 backend,
    LocalStack tier note).
  - Instantiation patterns: minimal example, BYO KMS, multi-
    access-point example, backup-policy-enabled example,
    additional-consumer-SGs example.
  - Static-provisioning PV manifest snippet for consumers (the
    `<filesystem_id>::<access_point_id>` `volumeHandle` shape +
    `encryptInTransit: "true"` volumeAttribute).
  - Operational gotchas: KMS `prevent_destroy` two-step destroy;
    lifecycle policy IA-transition latency caveat; AWS Backup
    vault prerequisite when `backup_policy_enabled = true`;
    mount target `tags` API gap (per IMPL Open Question Q9);
    `creation_token` collision on destroy + re-apply (per IMPL
    Open Question Q10).
- [ ] Regenerate `USAGE.md` via `terraform-docs .`.
- [ ] Add an "EFS filesystem module shape" section to `CLAUDE.md`
      following the rds-serverless precedent (~150-line block).
- [ ] Update `CLAUDE.md` repository-purpose section to list the
      new `modules/efs/` family.
- [ ] Update IMPL-0008 status from `Draft` → `Completed`; tick
      all tasks in this file.
- [ ] `just docs lint` passes (modulo the pre-existing MD024 /
      MD051 noise inherent to the docz IMPL template — same
      pattern as IMPL-0005..0007).
- [ ] Final audit pass: `just tf all efs/filesystem`
      (validate + lint + fmt + test) passes cleanly.

#### Success Criteria

- `just docs lint` passes (modulo template noise).
- `just tf all efs/filesystem` passes.
- `README.md` + `USAGE.md` both rendered.
- `CLAUDE.md` has the new module-shape section + repository-
  purpose bump.
- IMPL-0008 status flipped to Completed; all tasks ticked.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/efs/filesystem/versions.tf` | Create | Provider + Terraform version pins |
| `modules/efs/filesystem/variables.tf` | Create | Full input contract |
| `modules/efs/filesystem/locals.tf` | Create | KMS ARN coalesce, alias name, NFS port literal |
| `modules/efs/filesystem/main.tf` | Create | Two `data.terraform_remote_state` blocks |
| `modules/efs/filesystem/kms.tf` | Create | Gated `aws_kms_key` + alias with `prevent_destroy` |
| `modules/efs/filesystem/network.tf` | Create | SG + granular ingress (from_nodes + from_extra) + egress rules |
| `modules/efs/filesystem/filesystem.tf` | Create | `aws_efs_file_system` + lifecycle precondition |
| `modules/efs/filesystem/mount_targets.tf` | Create | `aws_efs_mount_target` for_each over subnets |
| `modules/efs/filesystem/access_points.tf` | Create | `aws_efs_access_point` for_each over map |
| `modules/efs/filesystem/backup.tf` | Create | Gated `aws_efs_backup_policy` |
| `modules/efs/filesystem/outputs.tf` | Create | Consumer-contract outputs |
| `modules/efs/filesystem/.tflint.hcl` | Create | Copy from sibling |
| `modules/efs/filesystem/.terraform-docs.yml` | Create | Copy from sibling |
| `modules/efs/filesystem/README.md` | Create | Stub + (Phase 11) full README |
| `modules/efs/filesystem/USAGE.md` | Create | Generated by terraform-docs |
| `modules/efs/filesystem/tests/*.tftest.hcl` | Create | 8 test files, ~18 runs |
| `modules/efs/filesystem/tests-localstack/apply_localstack.tftest.hcl` | Create | Apply suite (or plan_smoke fallback) |
| `modules/efs/filesystem/tests-localstack/fixtures/setup/main.tf` | Create | VPC + node SG stub + S3 stub state fixture |
| `modules/efs/filesystem/tests-localstack/FINDINGS.md` | Create | Gap-discovery writeup |
| `CLAUDE.md` | Modify | Add "EFS filesystem module shape" section + repository-purpose bump |
| `docs/impl/0008-efs-filesystem-module-implementation.md` | Modify | Tick tasks per phase; flip status to Completed |

## Testing Plan

- **Plan-only `terraform test` suite** (`tests/`) — covers both
  BYO + managed KMS, mount-target count via subnet stubs, access-
  point map resolution, lifecycle policy shape (default + null
  + override), SG ingress list shapes, backup policy gate, all
  validation negatives (identifier shape, length, performance_mode,
  throughput_mode, provisioned_throughput bounds, SG ID shape,
  cross-var precondition).
- **`tests-localstack/` apply suite** — VPC + node-SG fixture
  builds the prerequisites a real EFS apply needs; the module's
  data sources resolve against the stub state files. EFS API
  coverage probed at implementation time; IMPL-0005 Phase 9
  fall-back ready for any 501s.
- **No libtftest Go suite** — same posture as IMPL-0007: EKS
  cluster module is the sole side-by-side reference. Post-apply
  runtime invariants (NFS mount through CSI driver, access-point
  UID enforcement on file ops, encryption-in-transit handshake)
  are libtftest / sneakystack backlog per RFC-0001 §Phase 3.

## Dependencies

- **DESIGN-0008** must be merged before this IMPL ships.
- **VPC stack** applied + writing state to S3 with `vpc_id` +
  `private_subnet_ids` outputs (organizational prerequisite).
- **EKS cluster stack** applied + writing state with
  `node_security_group_id` output (organizational prerequisite —
  the existing cluster module already emits this).
- **EKS addons module** with `var.efs_csi_enabled = true` is the
  cluster-side prerequisite for any consumer of this module — but
  not a Terraform-level dependency (the cluster operator can land
  the addon and the filesystem independently).
- **LocalStack 2026.5.0 image** for the Phase 10 verification
  step (Community is the default tier per DESIGN-0008 Q11).
- **No new tooling pins** in `mise.toml`.
- **No provider bumps** required — `hashicorp/aws ~> 6.2`
  supports every resource referenced.

## Open Questions

All eleven questions resolved 2026-05-29 and folded into the
relevant Phase sections above.

### Q1 — VPC remote-state output field name for subnets — RESOLVED (a)

**Resolved:** `private_subnet_ids` — reuses the EKS-cluster remote-
state contract per IMPL-0007 Q1 precedent. No upstream VPC module
change required. Phase 2 task reflects the field name. Operators
can later add a dedicated `var.mount_target_subnet_ids` override
as an additive variable surface change when they need separate
DB-tier subnets.

### Q2 — `aws_efs_file_system.lifecycle_policy` block shape — RESOLVED (a)

**Resolved:** `var.lifecycle_policy = object({ transition_to_ia =
optional(string, "AFTER_30_DAYS"), transition_to_archive =
optional(string, "AFTER_90_DAYS"),
transition_to_primary_storage_class = optional(string, null) })`
with `default = {}` (relies on `optional()` defaults). Phase 5
emits one `dynamic "lifecycle_policy"` block per non-null
sub-attribute. Setting `var.lifecycle_policy = null` disables all
three transitions; passing a partial object overrides individual
transitions.

### Q3 — `var.access_points` value object shape — RESOLVED (a)

**Resolved:** Full EFS API surface — `map(object({ posix_user =
object({ uid = number, gid = number, secondary_gids =
optional(list(number), []) }), root_directory = object({ path =
string, creation_info = optional(object({ owner_uid = number,
owner_gid = number, permissions = string })) }) }))`. Phase 6
access-point resource emits `secondary_gids` always (defaults to
`[]`) and a dynamic `creation_info` block when non-null. Matches
the `modules/rds/read-replica` typed-object-map precedent.

### Q4 — Validate access-point POSIX UID/GID bounds — RESOLVED (a)

**Resolved:** Variable validation enforces `uid >= 0 && uid <=
65535` and `gid >= 0 && gid <= 65535` for each map entry; same
bounds on `secondary_gids` entries. Catches typos at plan;
doesn't forbid root — legitimate workloads occasionally need
`uid = 0` and we leave that decision to the consumer.

### Q5 — EFS `file_system_policy` — RESOLVED (a)

**Resolved:** No filesystem resource policy emitted in v1. Defer
to a follow-up IMPL when a concrete consumer requires it (e.g., a
compliance posture mandating deny-non-TLS). Documented as
explicitly out-of-scope in this IMPL's Scope §Out of Scope.

### Q6 — Module-managed KMS `prevent_destroy` — RESOLVED (a)

**Resolved:** Same pattern as the fleet — `prevent_destroy = true`
on `aws_kms_key.this[0]` + README documents the two-step destroy
procedure (empty filesystem → mount targets removed → remove the
`lifecycle { prevent_destroy = true }` block → destroy).
Consistency with `modules/eks/cluster`, `modules/ecr/org-registry`,
and `modules/rds/serverless`.

### Q7 — Mount target SG list — RESOLVED (a)

**Resolved:** Single module-managed SG only. The escape hatch is
`var.additional_allowed_consumer_sg_ids` which adds ingress *rules*
to the module's SG — not additional SGs to the mount target
itself. Phase 5's `aws_efs_mount_target.this` uses
`security_groups = [aws_security_group.this.id]` literally.

### Q8 — `tests-localstack` fixture — RESOLVED (a)

**Resolved:** Don't provision a real `aws_eks_cluster`. The
fixture creates a standalone `aws_security_group.node_stub` and
stubs its ID into the EKS state file's `node_security_group_id`
output. Simpler + faster fixture; avoids LocalStack EKS API edge
cases (the module only needs the SG ID, not the cluster control
plane). Phase 10 fixture spec reflects this.

### Q9 — Mount target `tags` API gap — RESOLVED (a)

**Resolved:** Document in README §Operational gotchas alongside
the other AWS-API quirks (KMS prevent_destroy two-step, IA-
transition latency, etc.). Phase 11 README task lists the
mount-target tags gap explicitly.

### Q10 — `creation_token` collisions on destroy + re-apply — RESOLVED (a)

**Resolved:** Document the wait-on-destroy behavior in README
§Operational gotchas; do nothing at the Terraform layer. Preserves
DESIGN-0008 Q10's `creation_token = var.identifier_prefix`
determinism. Real-world impact is rare (destroy + immediate
re-apply is an uncommon workflow); the operator gets a clear AWS
`TokenAlreadyExists` error message when it does occur.

### Q11 — `terraform test` validation file shape — RESOLVED (a)

**Resolved:** Single `validation.tftest.hcl` file with all
expect_failures runs. Matches IMPL-0007's validation.tftest.hcl
shape (9 runs in one file). Phase 9 task list reflects this.

## References

- [DESIGN-0008](../design/0008-efs-module-layout-for-efs-csi-on-eks.md) — EFS module layout (the design this IMPL implements).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state`.
- [ADR-0003](../adr/0003-eks-pod-identity-agent-installed-by-addons-module.md) — Pod Identity Agent + EFS CSI driver installation lives in the addons module.
- [ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md) — K8s manifests delivered out-of-band.
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy.
- [IMPL-0003](0003-eks-addons-module-implementation.md) — EKS addons module (home of the EFS CSI driver addon + IAM + PIA).
- [IMPL-0005](0005-ecr-pull-through-cache-module-implementation.md) — Sibling IMPL for the LocalStack 501 fallback pattern + FINDINGS.md shape.
- [IMPL-0007](0007-aurora-serverless-v2-module-implementation.md) — Sibling IMPL for VPC remote-state composition + KMS pattern + BYO-KMS-in-tests + override_data lesson.
- [Amazon EFS CSI driver documentation](https://github.com/kubernetes-sigs/aws-efs-csi-driver).
- [`aws_efs_file_system` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system).
- [`aws_efs_mount_target` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_mount_target).
- [`aws_efs_access_point` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_access_point).
- [EFS lifecycle policy documentation](https://docs.aws.amazon.com/efs/latest/ug/lifecycle-management-efs.html).
