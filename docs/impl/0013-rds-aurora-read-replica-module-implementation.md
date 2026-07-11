---
id: IMPL-0013
title: "RDS Aurora read-replica module implementation"
status: Draft
author: Donald Gifford
created: 2026-07-09
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0013: RDS Aurora read-replica module implementation

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
  - [Phase 2: Remote-state composition and cluster-output locals](#phase-2-remote-state-composition-and-cluster-output-locals)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Reader cluster instances (for-each over the replicas map)](#phase-3-reader-cluster-instances-for-each-over-the-replicas-map)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Outputs (per-reader identifier and endpoint maps)](#phase-4-outputs-per-reader-identifier-and-endpoint-maps)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Plan-only terraform test suite](#phase-5-plan-only-terraform-test-suite)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: Pro-gated apply suite (S3-object state bridge) and FINDINGS](#phase-6-pro-gated-apply-suite-s3-object-state-bridge-and-findings)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
  - [Phase 7: README, USAGE, CLAUDE.md, and docz closeout](#phase-7-readme-usage-claudemd-and-docz-closeout)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [Q1 — Scaffolding fork source — RESOLVED (a)](#q1--scaffolding-fork-source--resolved-a)
  - [Q2 — Stubbing cluster remote state in plan-only tests — RESOLVED (a)](#q2--stubbing-cluster-remote-state-in-plan-only-tests--resolved-a)
  - [Q3 — Apply-suite cross-state bridge — RESOLVED (a)](#q3--apply-suite-cross-state-bridge--resolved-a)
  - [Q4 — Apply-suite cluster fixture (module vs hand-rolled) — RESOLVED (b)](#q4--apply-suite-cluster-fixture-module-vs-hand-rolled--resolved-b)
  - [Q5 — Reader parameter-group and engine-version wiring — RESOLVED (a)](#q5--reader-parameter-group-and-engine-version-wiring--resolved-a)
  - [Q6 — Merge-ordering dependency on the cluster module — RESOLVED (a)](#q6--merge-ordering-dependency-on-the-cluster-module--resolved-a)
  - [Q7 — Validating the replicas map keys — RESOLVED (a)](#q7--validating-the-replicas-map-keys--resolved-a)
- [References](#references)
<!--toc:end-->

## Objective

Ship `modules/rds/read-replica` — one or more Aurora **reader instances**
(`aws_rds_cluster_instance`) attached to an **existing** cluster provisioned by
`modules/rds/cluster` (IMPL-0012). It owns no cluster, subnet group, security
group, or KMS key — all of those are the cluster's, read via
`data.terraform_remote_state` against the cluster's S3 state key (ADR-0001).
Structurally the closest sibling to the shipped `proxy` module: a **pure
consumer** of another RDS module's remote state, with a tiny pointer input
surface and a `for_each` over a typed `replicas` map. Fourth and **last** in
the DESIGN-0007 rollout — **must merge after `cluster`**, whose output names
are this module's hard dependency.

**Implements:**
[DESIGN-0014](../design/0014-rds-aurora-read-replica-module.md) (all seven open
questions resolved: Q1a, Q2a, Q3a, Q4 a+b hybrid, Q5a, Q6a, Q7a), the
`read-replica` slot of
[DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md).

## Scope

### In Scope

- A new `modules/rds/read-replica/` module: a small file set (no KMS / SG /
  subnet-group files — all cluster-owned), the cluster remote-state read
  (proxy pattern), and `aws_rds_cluster_instance.replica` via `for_each` over
  a typed `replicas` map.
- The **hybrid `replicas` object** (DESIGN-0014 Q4): required `instance_class`
  core + optional tuning attributes with defaults (`availability_zone`,
  `promotion_tier` default 15, `performance_insights_enabled`,
  `monitoring_interval` + `monitoring_role_arn`, `auto_minor_version_upgrade`,
  `publicly_accessible`).
- Engine / version / subnet-group / parameter-group all inherited from the
  cluster's remote state — drift-proof by construction (Q5).
- Plan-only `terraform test` suite (the gate) with `override_data` stubbing the
  cluster state + a **Pro-gated `tests-localstack-pro/` apply suite** bridging
  real cluster state through an S3-object fixture (proxy pattern) + a
  Community-safe `plan_smoke` in `tests-localstack/`.
- Module README, generated `USAGE.md`, `CLAUDE.md` inventory update, docz
  closeout.

### Out of Scope

- **Provisioning or mutating the cluster** — read-only input (DESIGN-0014
  non-goal).
- **Non-Aurora (single-instance) read replicas** (`replicate_source_db`) — a
  future `instance-replica` module (DESIGN-0012 Q5).
- **Cross-region replicas** and **a new pooled reader endpoint** (the cluster's
  `reader_endpoint` already load-balances; this module emits per-reader
  endpoints).
- **Aurora replica auto-scaling** (`aws_appautoscaling_*`) — the `replicas` map
  is explicit for v1 (DESIGN-0014 Q6).
- **Serverless targets** — cluster-only for v1 (DESIGN-0014 Q1; the
  `rds/cluster/` state-key segment is hardcoded).

## Implementation Phases

Each phase builds on the previous one and is committed as its own conventional
commit. A phase is complete when all its tasks are checked off and its success
criteria are met. Gate commands are the `justfile` recipes
(`just tf <action> rds/read-replica`).

Quality gates per the `/terraform` skill + repo conventions:

- After each task: `just tf fmt rds/read-replica`,
  `just tf lint rds/read-replica`, `just tf validate rds/read-replica`.
- After each phase that touched HCL: `just tf test rds/read-replica`
  (from Phase 5).
- No Go code — the `/terraform` conventions apply.

---

### Phase 1: Module scaffolding, version pins, and variable surface

Fork the `proxy` scaffolding (Q1) — the closest structural sibling. Tiny
pointer surface + the `replicas` map. No resources yet.

#### Tasks

- [x] Create `modules/rds/read-replica/`; copy `.terraform-docs.yml` /
      `.tflint.hcl` verbatim from `modules/rds/proxy/`.
- [x] `versions.tf`: `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`.
- [x] `variables.tf` per DESIGN-0014 §Input surface. **Required**: `region`,
      `remote_state_bucket`, `cluster_identifier`, `identifier_prefix`,
      `replicas` (map(object) — empty map = zero readers). **Optional**:
      `apply_immediately` (false), `tags` (`{}`). The DB-derived values
      (engine, subnet group, parameter group, SG, KMS) are **not inputs** —
      read from remote state.
- [x] Author the **hybrid `replicas` object** (Q4): required `instance_class`;
      optional `availability_zone`, `promotion_tier` (default 15),
      `performance_insights_enabled` (default false), `monitoring_interval`
      (default 0), `monitoring_role_arn`, `auto_minor_version_upgrade`
      (default true), `publicly_accessible` (default false). `nullable = false`.
- [x] Single-variable validations: `identifier_prefix` +
      `cluster_identifier` (RDS-identifier regex
      `^[a-z][a-z0-9-]{0,61}[a-z0-9]$`); each `replicas` **key** identifier-safe
      (Q7); each `promotion_tier` in `[0,15]`; each `monitoring_interval` in
      `{0,1,5,10,15,30,60}`.
- [x] Stub `main.tf`, `locals.tf`, `outputs.tf`; `README.md` stub.

#### Success Criteria

- `just tf validate rds/read-replica` succeeds; `just tf fmt` clean.
- `just tf lint rds/read-replica` passes (unused-* warnings clear at Phase 3).
- `just tf docs rds/read-replica` renders the input table (incl. the `replicas`
  object) into `USAGE.md`.

---

### Phase 2: Remote-state composition and cluster-output locals

The proxy pattern: a single `data.terraform_remote_state` read of the cluster's
state, aliased into `locals.tf` at the use site.

#### Tasks

- [x] `main.tf`: `data "terraform_remote_state" "rds_cluster"` — `backend =
      "s3"`, `bucket = var.remote_state_bucket`, `key =
      "${var.region}/rds/cluster/${var.cluster_identifier}/terraform.tfstate"`,
      `region = var.region`, `use_path_style = true`. The `rds/cluster/`
      segment is hardcoded (Q1-design — cluster-only for v1).
- [x] `locals.tf`: alias the consumed cluster outputs at the use site —
      `cluster_identifier`, `engine`, `engine_version_actual`,
      `db_subnet_group_name`, `db_parameter_group_name` (Q5) from
      `data.terraform_remote_state.rds_cluster.outputs.*`. (SG + KMS are
      cluster-owned; readers inherit them automatically — not re-set.)

#### Success Criteria

- `just tf validate rds/read-replica` succeeds; `just tf fmt` clean.
- A `tests/` smoke run with `override_data` on the cluster state resolves all
  aliased locals (asserted concretely once Phase 3 wires the reader).

---

### Phase 3: Reader cluster instances (for-each over the replicas map)

The load-bearing phase: `aws_rds_cluster_instance.replica` via `for_each`, with
per-reader optional settings and the stale-state precondition (Q7-design).

#### Tasks

- [x] `replicas.tf`: `aws_rds_cluster_instance.replica` with `for_each =
      var.replicas`:
  - `cluster_identifier = local.cluster_identifier`,
    `identifier = "${var.identifier_prefix}-replica-${each.key}"`.
  - `instance_class = each.value.instance_class`.
  - `engine = local.engine`, `engine_version = local.engine_version_actual`
    (pinned from remote state — drift-proof, Q5/Q4-impl).
  - `db_subnet_group_name = local.db_subnet_group_name`,
    `db_parameter_group_name = local.db_parameter_group_name` (inherited, Q5-impl).
  - `availability_zone = each.value.availability_zone` (null → Aurora auto),
    `promotion_tier = each.value.promotion_tier` (default 15 — below the
    writer's tier 0).
  - `publicly_accessible = each.value.publicly_accessible`,
    `apply_immediately = var.apply_immediately`.
  - Optional per-reader settings (all defaulted):
    `performance_insights_enabled`, `monitoring_interval` +
    `monitoring_role_arn`, `auto_minor_version_upgrade`.
- [x] `lifecycle.precondition`s on `aws_rds_cluster_instance.replica`:
  - **Stale/wrong cluster state (Q7-design):** `local.cluster_identifier !=
    null`, with a message naming the expected state key.
  - **Per-reader enhanced monitoring (Q4-design):** for any reader with
    `each.value.monitoring_interval > 0`, `each.value.monitoring_role_arn !=
    null`.

#### Success Criteria

- `just tf validate rds/read-replica` succeeds; `just tf lint` passes.
- Plan against a stub cluster state (single-reader map) shows exactly one
  reader named `…-replica-<key>` with engine/version inherited from the cluster.
- The stale-state precondition fails a plan when the stubbed
  `cluster_identifier` is null (asserted in Phase 5).

---

### Phase 4: Outputs (per-reader identifier and endpoint maps)

Per-reader endpoints for targeted routing (the cluster's `reader_endpoint`
remains the load-balanced entry point).

#### Tasks

- [x] `outputs.tf` (each with a `description`):
  - `replica_identifiers` = `{ for k, r in aws_rds_cluster_instance.replica :
    k => r.identifier }`.
  - `replica_endpoints` = `{ for k, r in aws_rds_cluster_instance.replica :
    k => r.endpoint }`.
- [x] Regenerate `USAGE.md`.

#### Success Criteria

- Every output has a description; both are maps keyed as `var.replicas`.
- `USAGE.md` current.

---

### Phase 5: Plan-only terraform test suite

The gate (ADR-0013 / RFC-0001). `data.terraform_remote_state.rds_cluster`
stubbed via `override_data` (Q2) — no S3 backend, runs in seconds.

#### Tasks

- [x] `tests/default.tftest.hcl` — `override_data` supplies the cluster outputs
      (`cluster_identifier`, `engine`, `engine_version_actual`, subnet-group,
      parameter-group). Runs:
  - single-reader map (1 instance, name `…-replica-<key>`, engine inherited);
  - three-reader map (3 instances, distinct keys, per-reader `instance_class` /
    AZ / `promotion_tier` plumb through);
  - empty map `{}` → zero instances.
- [x] `tests/key_stability.tftest.hcl` — removing a middle key doesn't renumber
      others (assert identifiers by key).
- [x] `tests/validation.tftest.hcl` with `expect_failures`: bad
      `identifier_prefix`, bad `cluster_identifier`, out-of-range
      `promotion_tier`, a reader with `monitoring_interval > 0` +
      `monitoring_role_arn = null` (the Q4 precondition), and the **Q7
      stale-state precondition** via `override_data` supplying a null
      `cluster_identifier`.
- [x] All files open with the fake `provider "aws"` block.

#### Success Criteria

- `just tf test rds/read-replica` passes all runs in < 5s.
- Coverage: 1 / 3 / 0 reader maps, key stability, all validation negatives incl.
  both preconditions.
- `just tf all rds/read-replica` green.

---

### Phase 6: Pro-gated apply suite (S3-object state bridge) and FINDINGS

Reader instances are Aurora and need a real cluster to attach to, and the apply
must bridge remote state through a **real S3-object fixture** (the proxy
`tests-localstack-pro/fixtures/db` pattern — `override_data` can't reference a
prior apply's outputs). Aurora + cross-state bridging is the **Pro-tier**
surface, so the apply lives in `tests-localstack-pro/` (off by default, run via
`just tf test-localstack-pro rds/read-replica`; Q3), with a Community-safe
`plan_smoke` in `tests-localstack/`.

#### Tasks

- [ ] `tests-localstack/plan_smoke.tftest.hcl` — always-on, Community-safe
      plan-only smoke (cluster state stubbed via `override_data`; no apply).
- [ ] `tests-localstack-pro/apply_pro.tftest.hcl`: `run "setup"` **instantiates
      the `modules/rds/cluster` module** (`fixtures/cluster`, Q4-b) **and writes
      a stub cluster state file to S3** at the read-replica's key; `run
      "apply_replicas"` attaches readers and asserts count / identifiers /
      per-reader endpoints.
- [ ] The `_tf-test-localstack-pro` justfile recipe already exists (added in
      IMPL-0010) — no justfile change needed; confirm it scans
      `rds/read-replica`.
- [ ] `tests-localstack-pro/fixtures/cluster/` — a
      `module "cluster" { source = "…/cluster" … }` instantiation (the real
      `modules/rds/cluster` module via a relative `source`) that the readers
      attach to (Q4-b).
- [ ] `tests-localstack/FINDINGS.md` — the Pro requirement (Aurora + cross-state
      bridge), the two-tier layout + recipe gate, the `override_data` limitation
      that forces the S3-object bridge, the macOS named-volume caveat.

#### Success Criteria

- With the flag on (Pro): `just tf test-localstack-pro rds/read-replica`
  provisions the fixture cluster + stub state and attaches/asserts the readers.
- With the flag off (default): `just tf test-localstack rds/read-replica` runs
  only `plan_smoke` (offline).
- `FINDINGS.md` documents the Pro requirement + the enable-flag + the macOS
  caveat.

---

### Phase 7: README, USAGE, CLAUDE.md, and docz closeout

#### Tasks

- [ ] Author `modules/rds/read-replica/README.md`: overview + DESIGN-0014 link;
      the composition prerequisite (a `cluster` provisioned by IMPL-0012 with
      state at `${region}/rds/cluster/${id}/terraform.tfstate`); a
      single-reader + a three-reader `replicas` example; the note that a
      cluster destroy/recreate changes `cluster_resource_id` and forces reader
      replacement (Q7-design c); operational gotchas; tests + the Pro-tier note.
- [ ] Regenerate `USAGE.md`.
- [ ] Update `CLAUDE.md`: add `modules/rds/read-replica` to the §Repository
      purpose `rds` inventory + a shape line (pure cluster remote-state
      consumer; Pro-gated apply divergence like `proxy`); regenerate the README
      module table.
- [ ] Mark IMPL-0013 `Completed`, run `docz update`, move DESIGN-0014 to
      `Implemented`.
- [ ] Add the "scaling out" back-pointer from the `cluster` module's README
      (if not already added at IMPL-0012 closeout).
- [ ] `just docs lint` clean for the new docs.

#### Success Criteria

- `just tf all rds/read-replica` green; `README.md` + `USAGE.md` current.
- `CLAUDE.md` inventory + shape updated; README table regenerated.
- IMPL-0013 `Completed`; DESIGN-0014 `Implemented`; docz index regenerated.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/rds/read-replica/versions.tf` | Create | `aws ~> 6.2`, terraform `>= 1.1` |
| `modules/rds/read-replica/.terraform-docs.yml` | Create | copied from proxy |
| `modules/rds/read-replica/.tflint.hcl` | Create | copied from proxy |
| `modules/rds/read-replica/variables.tf` | Create | pointer surface + hybrid `replicas` object + validations |
| `modules/rds/read-replica/main.tf` | Create | `data.terraform_remote_state.rds_cluster` |
| `modules/rds/read-replica/locals.tf` | Create | aliased cluster remote-state outputs |
| `modules/rds/read-replica/replicas.tf` | Create | `aws_rds_cluster_instance.replica` (`for_each`) + preconditions |
| `modules/rds/read-replica/outputs.tf` | Create | `replica_identifiers` + `replica_endpoints` maps |
| `modules/rds/read-replica/README.md` | Create | operator doc |
| `modules/rds/read-replica/USAGE.md` | Create | terraform-docs generated |
| `modules/rds/read-replica/tests/*.tftest.hcl` | Create | plan-only suite (~3 files) |
| `modules/rds/read-replica/tests-localstack/*` | Create | `plan_smoke` + FINDINGS |
| `modules/rds/read-replica/tests-localstack-pro/*` | Create | Pro apply suite + `fixtures/cluster` (instantiates the `cluster` module, Q4-b), off by default |
| `CLAUDE.md` | Modify | add `modules/rds/read-replica` inventory + shape |
| `README.md` | Modify | module table regen |
| `docs/impl/README.md` | Modify | docz regen |
| `docs/design/0014-...md` | Modify | status → Implemented at closeout |

## Testing Plan

- **Plan-only `terraform test` (`tests/`)** — the gate (Phase 5): 1 / 3 / 0
  reader maps, key stability, all validation negatives incl. both preconditions.
  Cluster state stubbed via `override_data`.
- **`tests-localstack-pro/` apply suite** — Pro-gated, off by default (Phase 6);
  bridges real cluster state through an S3-object fixture. Community falls back
  to `plan_smoke` in `tests-localstack/`.
- **No libtftest Go suite** — per ADR-0013; runtime invariants (reader lag,
  failover promotion) are RFC-0001 §Phase 3 backlog.

## Dependencies

- [DESIGN-0014](../design/0014-rds-aurora-read-replica-module.md) — the source
  contract (all OQs resolved).
- **`modules/rds/cluster` (IMPL-0012) — HARD dependency.** This module reads
  the cluster's pinned output names from remote state; it **must merge after**
  IMPL-0012, and the plan-only tests' `override_data` stubs must match the
  cluster's actual output shape. Per **Q4-b**, the Phase 6 apply fixture also
  instantiates the `cluster` module itself (via a relative `source`), so this
  IMPL needs the cluster module **source** present — not just its output names.
  If the cluster module isn't shipped yet, this IMPL is blocked past Phase 1.
- **`modules/rds/proxy` (IMPL-0010, shipped)** — the scaffolding + the
  `tests-localstack-pro/fixtures/db` S3-object-bridge pattern this module's
  apply suite reuses; the `_tf-test-localstack-pro` justfile recipe already
  exists.
- `hashicorp/aws ~> 6.2` (fleet pin) — `aws_rds_cluster_instance` available.
- **LocalStack Pro** — required for the Phase 6 apply suite (Aurora + the
  cross-state bridge). The macOS named-volume caveat applies.

## Open Questions

Implementation-level decisions the design left open. All seven were resolved
2026-07-09 (Q1–Q3, Q5–Q7 = **a**; Q4 = **b**). Each heading records the chosen
option; the **Resolved** line states the decision, and the alternatives are
retained for the record.

### Q1 — Scaffolding fork source — RESOLVED (a)

**Resolved: a.** Fork `modules/rds/proxy` — the closest structural sibling (a
pure remote-state consumer); almost the whole test harness carries over, only
the resource differs.

Which existing module do we copy the file split + configs from?

- **a (chosen):** Fork **`modules/rds/proxy`** — the closest structural
  sibling (a pure remote-state consumer: `main.tf` remote-state read, aliased
  locals, `override_data` plan-only tests, the `tests-localstack-pro/` S3-object
  bridge). Almost the whole test harness carries over; only the resource
  (`aws_rds_cluster_instance` via `for_each`) differs.
- **b:** Fork `modules/rds/serverless` — shares the RDS/Aurora domain but brings
  KMS/SG/subnet-group/parameter-group scaffolding this module doesn't own
  (all cluster-side), so more to delete than to keep.
- **other:** ______

### Q2 — Stubbing cluster remote state in plan-only tests — RESOLVED (a)

**Resolved: a.** `override_data` on `data.terraform_remote_state.rds_cluster`
(the proxy Q2 pattern); a null `cluster_identifier` override exercises the Q7
stale-state precondition.

How do the `tests/` runs supply the cluster outputs?

- **a (chosen):** `override_data` on
  `data.terraform_remote_state.rds_cluster`, supplying the cluster outputs per
  case (the proxy Q2 pattern). No S3 backend, runs in seconds; a null
  `cluster_identifier` override exercises the Q7 stale-state precondition.
- **b:** A wrapper fixture that writes real cluster state to S3 — heavier and
  unnecessary for plan-only (that's the Phase 6 apply suite's job).
- **other:** ______

### Q3 — Apply-suite cross-state bridge — RESOLVED (a)

**Resolved: a.** The S3-object fixture bridge (proxy's `apply_pro` pattern): a
`setup` run writes stub cluster state to S3, then `apply_replicas` reads it for
real via `data.terraform_remote_state.rds_cluster`. Lands in
`tests-localstack-pro/` (Pro-gated, off by default).

`override_data` can't reference a prior apply's outputs, so the apply suite
needs the cluster's state available for a real `terraform_remote_state` read.
How?

- **a (chosen):** The **S3-object fixture bridge**, exactly as `proxy`'s
  `tests-localstack-pro/apply_pro.tftest.hcl` does: a `setup` run applies the
  cluster fixture **and writes a stub cluster state file to S3** at the
  read-replica's key; `apply_replicas` then reads it for real via
  `data.terraform_remote_state.rds_cluster`. This lands in
  `tests-localstack-pro/` (Pro-gated, off by default).
- **b:** Skip the apply entirely and ship only `plan_smoke` — less coverage; the
  reader-attaches-to-cluster path never actually runs.
- **other:** ______

### Q4 — Apply-suite cluster fixture (module vs hand-rolled) — RESOLVED (b)

**Resolved: b.** The `setup` run instantiates the **actual `modules/rds/cluster`
module** (a `module "cluster" { source = "../../cluster" ... }` in
`fixtures/cluster/`) and writes its outputs to S3 as the stub cluster state the
readers then read. This exercises the real cluster ↔ read-replica composition
end-to-end (highest fidelity), and guarantees the remote-state output shape the
readers consume is exactly what the cluster module emits — no hand-maintained
stub to drift. It tightens the coupling to IMPL-0012: the fixture needs the
`cluster` module **source** present (reinforcing the Q6 merge-ordering gate),
though it still applies that module inside LocalStack, not a live deployment.

What does the `setup` run stand up for the readers to attach to?

- **a (recommended, not chosen):** A **hand-rolled minimal Aurora cluster
  fixture** (`fixtures/cluster`) — a bare `aws_rds_cluster` + one writer +
  subnet group + SG, mirroring the `proxy` `fixtures/db` approach. Decoupled
  from the full `cluster` module surface, so the read-replica apply suite
  doesn't break when the cluster module's internals change, and it's faster to
  apply.
- **b (chosen):** Instantiate the **actual `modules/rds/cluster` module** in the
  fixture — exercises the real composition end-to-end (highest fidelity) and
  keeps the reader-consumed output shape exactly in sync with what the cluster
  emits, at the cost of coupling this module's apply suite to the cluster
  module's input surface + lifecycle.
- **other:** ______

### Q5 — Reader parameter-group and engine-version wiring — RESOLVED (a)

**Resolved: a.** Set both `engine_version` and `db_parameter_group_name`
explicitly from the cluster's remote state (`local.engine_version_actual`,
`local.db_parameter_group_name`) — drift-proof and visible in the reader's plan
(the DESIGN-0014 Q5 intent), even though Aurora would inherit them implicitly.

The cluster instance inherits some settings implicitly. Which do we set
explicitly from remote state?

- **a (chosen):** **Set both `engine_version` and `db_parameter_group_name`
  explicitly** from the cluster's remote state (`local.engine_version_actual`,
  `local.db_parameter_group_name`). Explicit = drift-proof and visible in the
  reader's plan (the DESIGN-0014 Q5 intent), even though Aurora would inherit
  them implicitly.
- **b:** Omit both and let Aurora inherit them from the cluster implicitly —
  less code, but the version + parameter group aren't visible in the reader's
  plan and rely on AWS's implicit inheritance.
- **c:** Set `engine_version` explicitly but omit `db_parameter_group_name`
  (readers rarely diverge on the instance parameter group) — a middle ground.
- **other:** ______

### Q6 — Merge-ordering dependency on the cluster module — RESOLVED (a)

**Resolved: a.** Gate this IMPL on IMPL-0012 completion — author it against
DESIGN-0013's pinned output names, but do not merge until `cluster` has shipped
and its `outputs.tf` names are final; the plan-only `override_data` stubs must
mirror the cluster's real output shape. The Q4-b fixture instantiates the
`cluster` module itself, which sharpens this gate (it needs the cluster module
source), but the fixture still applies that module inside LocalStack, so it
doesn't block on a live cluster deployment.

This module hard-depends on `cluster` (IMPL-0012) being merged with pinned
outputs. How do we sequence the work?

- **a (chosen):** **Gate this IMPL on IMPL-0012 completion.** Author it
  against DESIGN-0013's pinned output names, but do not merge until `cluster`
  has shipped and its `outputs.tf` names are final; the plan-only
  `override_data` stubs must mirror the cluster's real output shape. The Phase 6
  fixture instantiates the `cluster` module itself (Q4-b), so it needs the
  cluster module source present but still doesn't block on a live cluster
  deployment.
- **b:** Build both modules in one combined IMPL / PR — guarantees the output
  contract matches, but makes a large PR and couples two modules' review.
- **other:** ______

### Q7 — Validating the replicas map keys — RESOLVED (a)

**Resolved: a.** A variable validation on `replicas` asserting every key is
identifier-safe (`alltrue([for k in keys(var.replicas) : can(regex(...))])`,
with a length bound so the composed identifier stays ≤ 63 chars) — a clear
plan-time error naming the offending key.

Each `replicas` key is interpolated into `${identifier_prefix}-replica-${key}`,
so a bad key produces an invalid RDS identifier. How do we guard it?

- **a (chosen):** A **variable validation on `replicas`** asserting every
  key is identifier-safe —
  `alltrue([for k in keys(var.replicas) : can(regex("^[a-z0-9-]+$", k))])` (with
  a length bound so the composed identifier stays ≤ 63 chars) — a clear
  plan-time error naming the offending key.
- **b:** No key validation — let AWS reject a bad composed identifier at apply.
  Smaller surface, worse ergonomics (apply-time failure, cryptic message).
- **other:** ______

## References

- [DESIGN-0014](../design/0014-rds-aurora-read-replica-module.md) — the design this IMPL implements (all OQs resolved).
- [DESIGN-0013](../design/0013-rds-aurora-provisioned-cluster-module.md) — Aurora provisioned cluster (the source-of-truth state this module consumes; IMPL-0012 must merge first).
- [DESIGN-0007](../design/0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS module family layout (parent design; Q1 `for_each` resolution).
- [DESIGN-0010](../design/0010-rds-proxy-module-for-the-rds-and-aurora-data-tier.md) — RDS Proxy (the reference remote-state-composition + S3-fixture test pattern this module mirrors).
- [IMPL-0010](0010-rds-proxy-module-implementation.md) — RDS Proxy implementation (the `tests-localstack-pro/fixtures/db` S3-object bridge + the `_tf-test-localstack-pro` recipe this module reuses).
- [IMPL-0012](0012-rds-aurora-provisioned-cluster-module-implementation.md) — Aurora provisioned cluster implementation (the hard upstream dependency).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state`.
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy.
- [`aws_rds_cluster_instance` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_cluster_instance).
