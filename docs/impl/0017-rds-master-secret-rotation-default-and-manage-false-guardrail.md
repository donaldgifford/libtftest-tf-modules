---
id: IMPL-0017
title: "RDS master secret rotation default and manage-false guardrail"
status: In Progress
author: Donald Gifford
created: 2026-07-29
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0017: RDS master secret rotation default and manage-false guardrail

**Status:** In Progress
**Author:** Donald Gifford
**Date:** 2026-07-29

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Design summary (from INV-0008)](#design-summary-from-inv-0008)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: F5 adoption probe on LocalStack Pro](#phase-1-f5-adoption-probe-on-localstack-pro)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
    - [Result](#result)
  - [Phase 2: rds/instance — rotation surface + guardrail](#phase-2-rdsinstance--rotation-surface--guardrail)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: rds/serverless + rds/cluster — same surface](#phase-3-rdsserverless--rdscluster--same-surface)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Plan-test coverage](#phase-4-plan-test-coverage)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Apply-tier verification](#phase-5-apply-tier-verification)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: Documentation + release](#phase-6-documentation--release)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. What happens when `manage_master_user_password = false` while `master_secret_rotation_days` is set?](#1-what-happens-when-manage_master_user_password--false-while-master_secret_rotation_days-is-set)
  - [2. What is the fallback if LocalStack Pro cannot exercise managed-secret rotation adoption?](#2-what-is-the-fallback-if-localstack-pro-cannot-exercise-managed-secret-rotation-adoption)
  - [3. What are the validation bounds for `master_secret_rotation_days`?](#3-what-are-the-validation-bounds-for-master_secret_rotation_days)
- [References](#references)
<!--toc:end-->

## Objective

Implement INV-0008's two resolved recommendations across the three
secret-owning RDS modules (`rds/instance`, `rds/serverless`, `rds/cluster`):

1. **Module-owned 90-day rotation default** for the AWS-managed master user
   secret: a new `master_secret_rotation_days` variable (number, default
   `90`, `null` = leave AWS's schedule alone) driving an
   `aws_secretsmanager_secret_rotation` resource that adopts the managed
   secret — replacing AWS's noisy 7-day default cadence with a quarterly one,
   declaratively.
2. **Plan-time guardrail on the `manage_master_user_password = false` escape
   hatch**: a lifecycle precondition —
   `var.manage_master_user_password || var.iam_database_authentication_enabled`
   — so the no-auth-path configuration fails at plan with an actionable
   message instead of at the RDS API (fresh create) or in a downstream proxy
   plan.

**Implements:** INV-0008 (OQs resolved **1a / 2a / 3a** on 2026-07-29).
Consumer-side precedent: the `rds/proxy` fail-closed precondition
(`proxy.tf:47-48`). Gated by INV-0008 **F5** (the adoption probe — Phase 1
here).

## Scope

### In Scope

- `rds/instance`, `rds/serverless`, `rds/cluster`: the
  `master_secret_rotation_days` variable, a `secret_rotation.tf` per module,
  and the new precondition on the DB resource.
- The F5 probe on LocalStack Pro and its outcome recorded back into INV-0008
  (flipping it to Concluded).
- Plan-test coverage per module (rotation surface + guardrail) and apply-tier
  assertions where LocalStack parity allows.
- USAGE.md / README / CLAUDE.md documentation updates.

### Out of Scope

- **`rds/proxy` and `rds/read-replica`** — no secret ownership; the proxy's
  existing precondition already covers its side. No changes.
- **A `password` / `password_wo` input** — INV-0008's conclusion stands:
  `manage = false` remains a migration escape hatch, never a BYO-password
  mode. Write-only-argument support is a separate decision if a real case
  ever lands.
- **Changing the rotation window function** (`ScheduleExpression` cron
  windows, `duration` tuning) — the days-based surface (OQ 1a) is deliberate;
  a schedule-expression variable is a future additive change if needed.
- **EFS/EKS credentialing** — nothing outside the RDS data tier.

## Design summary (from INV-0008)

| Q | Resolution | Effect on this IMPL |
|---|------------|---------------------|
| 1 | **1a** | `master_secret_rotation_days` — `number`, default `90`, `nullable = true`; `null` emits no rotation resource. Days map to `rotation_rules { automatically_after_days }`. |
| 2 | **2a** | Precondition on the DB resource: `manage \|\| iam_auth`, error message naming the two valid paths + the migration caveat. |
| 3 | **3a** | All three modules in one PR — no split-fleet cadence. |

Grounding facts (verified in-repo, 2026-07-29):

- The managed secret ARN is reachable as
  `aws_db_instance.this.master_user_secret[0].secret_arn` (instance) /
  `aws_rds_cluster.this.master_user_secret[0].secret_arn`
  (serverless + cluster) — the existing `master_user_secret_arn` outputs
  already wrap exactly these in `try(..., null)`.
- `iam_database_authentication_enabled` exists under that exact name in all
  three modules' `variables.tf`.
- House precondition style: `lifecycle { precondition { … } }` blocks on the
  DB resource with actionable error messages (`rds/instance/instance.tf`
  carries five today; this adds the sixth).
- The rotation resource shape: `aws_secretsmanager_secret_rotation` with
  `secret_id`, `rotation_rules { automatically_after_days = … }`, and **no**
  `rotation_lambda_arn` (managed rotation).
- Each module's plan suite already has `validation.tftest.hcl` (precondition
  coverage home) and `default.tftest.hcl`; the rotation surface gets its own
  `secret_rotation.tftest.hcl`.

## Implementation Phases

### Phase 1: F5 adoption probe on LocalStack Pro

Answer INV-0008 F5 before any module changes: can
`aws_secretsmanager_secret_rotation` adopt the RDS-managed master secret
declaratively, and does LocalStack Pro exercise it?

#### Tasks

- [x] Throwaway config (out-of-tree, like the provider-6.57.0 repro): minimal
  `aws_db_instance` with `manage_master_user_password = true` +
  `aws_secretsmanager_secret_rotation` with
  `secret_id = aws_db_instance.this.master_user_secret[0].secret_arn`,
  `rotation_rules { automatically_after_days = 90 }`, no lambda.
- [x] Apply against LocalStack Pro `2026.7.0` (named volume, per the
  `rds/*` FINDINGS caveats). Record: create/adopt result, whether a second
  `plan` is clean (no perpetual diff), destroy ordering (the rotation
  resource must not wedge the destroy).
- [x] If LocalStack parity is missing for `RotateSecret`-on-managed-secret,
  record the exact failure and proceed per OQ 2 resolution.
- [x] Write the outcome into INV-0008 **F5** and flip INV-0008 →
  **Concluded** (answer recorded either way).

#### Success Criteria

- F5 has a definitive, reproducible answer (works / parity gap, with
  evidence), INV-0008 is Concluded, and the Phase 2–5 approach is confirmed
  or adjusted per OQ 2 before any module file changes.

#### Result

**Complete — parity gap, precisely bounded (2026-07-29).** The probe (provider
`6.57.0`, LocalStack Pro `2026.7.0`) created the instance + managed secret
fine, but the rotation resource failed: `RotateSecret` →
`InvalidRequestException: No Lambda rotation function ARN is associated with
this secret`. `describe-secret` shows LocalStack mints the secret with
`OwningService: rds` but **no managed-rotation registration**
(`RotationEnabled: null`) — the schedule-only `RotateSecret` real AWS
supports has nothing to attach to. Destroy of the partial state clean;
second-plan stability untestable on LocalStack (resource never creates),
covered by the API contract + optional real-AWS spot check (OQ 2a).
INV-0008 → Concluded. Phase 5 adjusted: apply suites opt out via
`master_secret_rotation_days = null` + FINDINGS.md gap notes; plan suites
own the rotation-surface coverage.

### Phase 2: rds/instance — rotation surface + guardrail

#### Tasks

- [x] `variables.tf`: `master_secret_rotation_days` — `number`, default
  `90`, `nullable = true`, validation `7 <= days <= 365` (OQ 3b),
  description covering the `null` opt-out and the manage-false interplay
  (OQ 1a: rotation resource silently omitted when `manage = false`).
- [x] New `secret_rotation.tf`: the `aws_secretsmanager_secret_rotation`
  resource, `count`-gated per OQ 1 resolution, `secret_id` from
  `master_user_secret[0].secret_arn`.
- [x] `instance.tf`: sixth precondition —
  `var.manage_master_user_password || var.iam_database_authentication_enabled`
  — with an error message naming the two valid paths (keep the managed
  secret / enable IAM auth) and the migration escape-hatch caveat.
- [x] `terraform-docs` regeneration (USAGE.md) via the static gate.
- [x] `just static` green (fmt + validate + tflint + docs, repo-wide).

#### Success Criteria

- `rds/instance` plans cleanly with defaults (rotation resource present at
  90 days), with `master_secret_rotation_days = null` (resource absent), and
  fails at plan — not apply — for `manage = false` without IAM auth.

#### Result

**Complete (2026-07-29).** `master_secret_rotation_days` (number, default
`90`, `nullable`, `[7, 365]` validation), `secret_rotation.tf`
(`aws_secretsmanager_secret_rotation.master`, `count`-gated on
`manage && days != null`, `rotate_immediately = false`), and the sixth
precondition (`manage || iam_auth`, naming both valid paths + the
migration caveat) landed on `rds/instance`. `manage_master_user_password`'s
description now documents the guardrail. One house-style catch: the
`terraform_variable_attribute_order` tflint rule wants `nullable` **after**
the `validation` block (the `identifier_prefix` pattern) despite its
message wording. Existing plan suite still green (26/26); static gate
green. Plan-test coverage of the new surface lands in Phase 4.

### Phase 3: rds/serverless + rds/cluster — same surface

#### Tasks

- [x] Port the Phase-2 change verbatim to `rds/serverless` (secret ARN from
  `aws_rds_cluster.this`), preconditions onto `aws_rds_cluster.this`'s
  lifecycle block.
- [x] Same for `rds/cluster`.
- [x] Confirm no surface is needed on `rds/proxy` (its precondition already
  covers the consumer side) or `rds/read-replica` (no secret) — grep-verify
  nothing else references `manage_master_user_password`.
- [x] USAGE.md regeneration for both; `just static` green.

#### Success Criteria

- All three modules expose the identical variable + precondition surface
  (identical names, defaults, error-message shape); static gate green.

#### Result

**Complete (2026-07-29).** Ported verbatim: identical
`master_secret_rotation_days` variable (90 / null / `[7, 365]`), identical
`secret_rotation.tf` differing only in `secret_id`
(`aws_rds_cluster.this.master_user_secret[0].secret_arn`), and the
`manage || iam_auth` precondition appended to each cluster's lifecycle
block ("cluster" wording; both now carry four preconditions — header
comments updated). Grep confirmed the only other
`manage_master_user_password` references are `rds/proxy`'s existing
fail-closed precondition (consumer side already covered) and a
`manage = true` Pro fixture — `rds/read-replica` has none. Plan suites
green (serverless 21/21, cluster 19/19); static gate green.

### Phase 4: Plan-test coverage

#### Tasks

- [ ] Per module, new `tests/secret_rotation.tftest.hcl`: default → rotation
  resource present with `automatically_after_days = 90`; explicit
  `master_secret_rotation_days = 30` → `30`; `null` → resource absent
  (count 0); `manage_master_user_password = false` (+ IAM auth true) →
  resource absent.
- [ ] Per module, extend `tests/validation.tftest.hcl`: `manage = false` +
  `iam_database_authentication_enabled = false` → `expect_failures` on the
  DB resource precondition (following the suite's existing
  precondition-failure pattern); `manage = false` + IAM auth `true` → plan
  passes; OQ-3 bounds violations → variable-validation failures.
- [ ] `just tf test rds/instance|rds/serverless|rds/cluster` green; record
  the new run counts.

#### Success Criteria

- All three plan suites green locally and in the CI plan tier (the
  changed-module matrix picks up all three automatically — no CI edits).

### Phase 5: Apply-tier verification

Contingent on the Phase-1 parity result (OQ 2).

#### Tasks

- [ ] If parity holds: add a rotation assertion to the existing apply runs —
  `rds/instance` + `rds/cluster` in `tests-localstack-pro/`, `rds/serverless`
  in `tests-localstack/` — asserting the rotation resource applied and
  `rotation_rules[0].automatically_after_days == 90`.
- [ ] Run the three apply suites locally against LocalStack Pro `2026.7.0`
  (named volume; `just tf test-localstack-pro rds/instance`, `… rds/cluster`,
  `just tf test-localstack rds/serverless`).
- [ ] Update each suite's `FINDINGS.md` with the rotation outcome (pass, or
  the documented parity gap per OQ 2a's fallback).

#### Success Criteria

- Apply suites pass with the rotation assertions (or the parity gap is
  documented in FINDINGS.md and the assertions are plan-covered instead) —
  no silent coverage loss either way.

### Phase 6: Documentation + release

#### Tasks

- [ ] CLAUDE.md: update the three modules' bullets (rotation default +
  guardrail, one sentence each).
- [ ] `docz update` (restore `docs/impl/0009` TOC if mangled); IMPL-0017 →
  Completed with per-phase Results.
- [ ] PR across the three modules labeled **minor** (additive variable +
  precondition; no breaking change — existing plans with defaults gain the
  rotation resource, which is the intended behavior change and is called out
  in the PR body).
- [ ] Post-merge: note in the PR/CLAUDE.md that live deployments pick up the
  90-day schedule on their next apply (the rotation resource adopts the
  existing managed secret in place — no secret replacement, no credential
  change).

#### Success Criteria

- CI green on the PR (static + plan tiers; apply tiers per toggle state);
  docs regenerated; IMPL-0017 Completed; INV-0008 Concluded.

## File Changes

| File | Change |
|------|--------|
| `modules/rds/{instance,serverless,cluster}/variables.tf` | + `master_secret_rotation_days` (number, default 90, nullable, validated) |
| `modules/rds/{instance,serverless,cluster}/secret_rotation.tf` | **New** — count-gated `aws_secretsmanager_secret_rotation` adopting the managed secret |
| `modules/rds/instance/instance.tf` | + sixth precondition (`manage \|\| iam_auth`) |
| `modules/rds/{serverless,cluster}/cluster.tf` | + same precondition on `aws_rds_cluster.this` |
| `modules/rds/{instance,serverless,cluster}/tests/secret_rotation.tftest.hcl` | **New** — rotation-surface plan runs |
| `modules/rds/{instance,serverless,cluster}/tests/validation.tftest.hcl` | + guardrail + bounds runs |
| `modules/rds/{instance,cluster}/tests-localstack-pro/apply_pro.tftest.hcl`, `modules/rds/serverless/tests-localstack/apply_localstack.tftest.hcl` | + rotation assertion (Phase 5, parity-contingent) |
| `modules/rds/{instance,serverless,cluster}/USAGE.md` | Regenerated |
| `docs/investigation/0008-*.md` | F5 outcome + status → Concluded |
| `CLAUDE.md` | Module bullets updated |

No CI changes: the three modules enter the changed-module matrices
automatically, and the static gate covers fmt/validate/lint/docs.

## Testing Plan

- **Plan tier (the gate):** the Phase-4 runs — rotation resource
  presence/absence/value across the default, explicit, `null`, and
  `manage = false` configurations; precondition failure and pass paths;
  bounds validation. All with the existing `mock_provider` + nine-key vpc
  `override_data` stubs.
- **Apply tier (Pro, local):** Phase-5 assertions against LocalStack Pro
  2026.7.0 — rotation resource applied with the 90-day rule on a real
  managed secret (parity-contingent per OQ 2).
- **Idempotency:** the Phase-1 probe explicitly checks the second-plan-clean
  property (no perpetual diff from the adopted rotation), which is the
  highest-risk unknown.

## Dependencies

- INV-0008 **F5** probe result (Phase 1 gates Phases 2–5's final shape).
- A working LocalStack Pro container (`2026.7.0`, named volume) — available
  locally; the CI apply tiers stay behind `CI_RUN_LOCALSTACK_APPLY` and are
  not required for this IMPL's merge (plan tier gates).
- No dependency on the CI pipeline work (ADR-0019) beyond what is already on
  `main`.

## Open Questions

> **Resolved 2026-07-29: 1a, 2a, 3b.** The rotation resource is silently
> omitted when `manage_master_user_password = false` (count guard, no
> two-keyed escape hatch); a LocalStack parity gap does not block — plan
> tests gate and the gap lands in FINDINGS.md; and the validation bounds are
> the **opinionated `7–365`** (3b — no faster than AWS's own 7-day default,
> no slower than yearly; a deliberate policy constraint, chosen over the raw
> 1–1000 API bounds).

### 1. What happens when `manage_master_user_password = false` while `master_secret_rotation_days` is set?

**Resolved: a.**

With the default at `90`, every `manage = false` migration would carry a
non-null rotation value unless the operator also nulls it — so the two
variables' interplay needs a deliberate rule.

- **a. (Recommended) Silently omit the rotation resource** (`count =
  var.manage_master_user_password && var.master_secret_rotation_days != null
  ? 1 : 0`). There is no managed secret to rotate, so there is nothing to
  configure; forcing operators to *also* set `master_secret_rotation_days =
  null` during a migration would make the escape hatch two-keyed for no
  safety gain. The variable description documents the interplay.
- b. Precondition requiring `master_secret_rotation_days == null` when
  `manage = false` — maximally explicit, but hostile to the default: every
  migration must touch two variables, and the error teaches nothing the
  count guard doesn't already encode.
- Other: (your call)

### 2. What is the fallback if LocalStack Pro cannot exercise managed-secret rotation adoption?

**Resolved: a.**

- **a. (Recommended) Implement anyway; plan tests gate; document the parity
  gap.** The rotation resource's plan shape is fully assertable without an
  apply; the gap is recorded in each suite's `FINDINGS.md` per the RFC-0001
  gap-discovery convention (the same posture the fleet already takes for
  other Pro parity holes), with an optional one-time real-AWS spot check
  before the first production rollout.
- b. Verify against real AWS before merging — highest confidence, but
  introduces a real-cloud dependency into a module PR for a resource whose
  API contract is documented and stable.
- c. Block the IMPL until LocalStack ships parity — safest-looking, worst
  trade: an unbounded external wait for a schedule-tuning feature.
- Other: (your call)

### 3. What are the validation bounds for `master_secret_rotation_days`?

**Resolved: b — `7–365`.** Policy is deliberately encoded in the constraint
as well as the default: the fleet does not rotate faster than AWS's own
7-day default nor slower than yearly. A cadence outside that band is a
policy conversation (edit the module), not a variable override.

- a. `1–1000` — mirror the Secrets Manager API bounds for
  `AutomaticallyAfterDays` and keep *policy* in the default (90), not the
  constraint. Operators who deliberately want weekly (7) or annual-ish (365)
  cadences stay unblocked; the API remains the arbiter of validity.
- b. `7–365` — opinionated guardrails ("no faster than AWS's own default,
  no slower than yearly"), but it encodes policy two places (default *and*
  bounds) and blocks legitimate edge cases (e.g., a 3-day compliance
  cadence) for no correctness reason.
- Other: (your call)

## References

- INV-0008 — the investigation this implements (F1–F5; OQs 1a/2a/3a)
- DESIGN-0010 / RFC-0002 — proxy composition against the managed master
  secret (why the guardrail names IAM auth as the alternate path)
- DESIGN-0012 / IMPL-0011 — `rds/instance` (escape-hatch variable wording)
- `modules/rds/proxy/proxy.tf:47-48` — the consumer-side fail-closed
  precondition this mirrors at the source
- ADR-0018 / ADR-0019 — test-tier taxonomy + pipeline the coverage slots into
- AWS docs — *Managing master user passwords with Secrets Manager*;
  `RotateSecret` (`AutomaticallyAfterDays` bounds)
