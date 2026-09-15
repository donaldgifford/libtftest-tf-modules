---
id: IMPL-0025
title: "S3 mirror bucket purpose module"
status: Draft
author: Donald Gifford
created: 2026-09-15
---

<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL-0025: S3 mirror bucket purpose module

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-09-15

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Module scaffold and policy composition](#phase-1-module-scaffold-and-policy-composition)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Plan suite (the gate)](#phase-2-plan-suite-the-gate)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Apply, sandbox proof, and closure](#phase-3-apply-sandbox-proof-and-closure)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. What is the PR and release cadence?](#1-what-is-the-pr-and-release-cadence)
  - [2. Where does the sandbox positive-leg client run?](#2-where-does-the-sandbox-positive-leg-client-run)
  - [3. What if LocalStack mangles the star-principal policy?](#3-what-if-localstack-mangles-the-star-principal-policy)
- [References](#references)
<!--toc:end-->

## Objective

Build `modules/s3/mirror-bucket` — the sluice provider-network-mirror
serving bucket — as a thin wrapper over `modules/s3/internal/core`
with the four composed policy statements, pinned SSE-S3 + versioning,
explicit-target logging, noncurrent-to-IA lifecycle, and the
`mirror_url` output, plus the family-pattern plan suite, a Community
apply, and the fleet's first sandbox policy-evaluation run.

**Implements:** DESIGN-0028 (all eight OQs resolved 2026-09-15 — 1a
[one list drives allow + `DenyOutsideVpce`], 2a [mirror sids join the
core reserved list], 3a [family-standard naming], 4a
[`account_id` + `region` only], 5a [enable + days, COMPLIANCE
pinned], 6a [`enable_policy_mutation_guard` default true], 7a
[explicit cross-account publisher variable], 8a [shell runbook under
`tests-sandbox/`]), from gh-121 and sluice DESIGN-0002 (workstream
2).

## Scope

### In Scope

- `modules/s3/mirror-bucket` (NEW): root composition (`locals`
  building the four statements, count-gated delete-deny), all
  variables per the resolved OQs, pinned posture, all outputs
  incl. `mirror_url`.
- `modules/s3/internal/core`: the OQ-2a reserved-sid extension
  (three sids join the validation list in `variables.tf`) — the
  only core edit, validation-only.
- Plan suite (`tests/`): baseline variant, statement-by-statement
  policy suite, rejection runs with per-rule verification,
  `mirror_url` / lifecycle / logging runs.
- Community apply (`tests-localstack/`) + FINDINGS.md, run live.
- Sandbox evaluation runbook (`tests-sandbox/`) + FINDINGS.md,
  run live against a sandbox account.
- Closure: module README, `USAGE.md`, CLAUDE.md family note,
  `just changed` verification, docz, one `minor` release.

### Out of Scope

From the design's Non-Goals:

- IAM resources of any kind (no publisher role; sluice
  `create_publisher_role` / `publisher_repo_subjects` /
  `publisher_role_arn` have no counterpart here).
- Mirror *content* (sluice workstream 1, the mirror CLI).
- CloudFront / off-VPC serving; cross-region replication.
- Object Lock beyond enable + days (no mode/year surface), legal
  holds, lock on existing buckets.
- `cloudfront-origin-bucket`, `presigned-transfer-bucket` —
  still deferred.
- Changes to any existing purpose module (the core edit is
  validation-only and a no-op for conforming callers).
- The VPCE positive-leg sandbox evaluation (anonymous GET via
  the endpoint succeeds) — **gh-122**, re-armed when
  VPC-attached platform runners exist.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all
its tasks are checked off and its success criteria are met.

---

### Phase 1: Module scaffold and policy composition

The module, its variables, the root `locals` statement composition,
core wiring, outputs, and the build-time star-principal probe (P0).
No tests yet — Phase 2 pins what Phase 1 renders.

#### Tasks

- [x] 1.1 Scaffold `modules/s3/mirror-bucket` from `bucket`
  (structural template, NOT `evidence-bucket`): `main.tf`
  (locals + core block), `variables.tf`, `outputs.tf`,
  `versions.tf` (aws `~> 6.2` declared at root per the
  wrapper-module gotcha, tflint-ignored as unused),
  `.tflint.hcl`, `.terraform-docs.yml`, `README.md` skeleton.
  Family-standard naming (`name` + `name_override` + shard
  hatch, OQ 3a) and two globals only (`account_id`, `region`,
  OQ 4a).
- [x] 1.2 Root `locals` composing the four statements for
  `internal_policy_statements`:
  `AllowMirrorReadFromVPCE` (Allow, `principals = { "*" = ["*"] }`,
  `GetObject`, `resource_suffixes = ["/*"]`, `StringEquals
  aws:SourceVpce = var.vpc_endpoint_ids`),
  `DenyObjectDeletion` (**count-gated**: no `conditions` when
  `break_glass_principal_arns` is empty, else `StringNotEquals
  aws:PrincipalArn`), `DenyPolicyMutation` (gated on
  `enable_policy_mutation_guard`, `StringNotEquals
  aws:PrincipalArn = var.policy_admin_principal_arns`, resources
  `[""]`), `AllowCrossAccountPublisherWrite` (rendered only when
  `cross_account_publisher_principal_arns` is non-empty:
  `PutObject` + `GetObject` + `ListBucket`, no deletes).
  `allowed_vpc_endpoint_ids = var.vpc_endpoint_ids` (OQ 1a).
- [x] 1.3 Variables with fleet-doctrine validations (separate
  block per rule, IMPL-0022): `vpc_endpoint_ids` (required,
  non-empty, `vpce-` id format), `policy_admin_principal_arns`
  (required, non-empty — an empty admin list strands the stack),
  exact-ARN regex + wildcard + duplicate rejection on all three
  principal lists, `cross_account_publisher_principal_arns`
  default `[]`, `break_glass_principal_arns` default `[]`,
  `enable_object_lock` default `false`,
  `object_lock_retention_days` default `null`,
  `noncurrent_version_ia_days` default `null`,
  `access_log_bucket` default `null`, `access_log_prefix`
  default `null`, `enable_policy_mutation_guard` default `true`
  (OQ 6a), `additional_policy_statements` with the extended
  reserved-sid mirror (task 1.4), `tags`.
- [x] 1.4 Core edit (OQ 2a): ~~the three mirror sids
  (`AllowMirrorReadFromVPCE`, `DenyObjectDeletion`,
  `DenyPolicyMutation`) join the reserved-sid validation in
  `core/variables.tf`. Validation-only — no resource, type, or
  default change.~~ **STRUCK at build — no core edit exists.**
  Mechanism finding: the mirror's own composed statements travel
  through `internal_policy_statements`, so a core-side rejection
  of those sids would fail the mirror itself — OQ 2a is
  unimplementable as specified. The guard lives at the mirror
  root (task 1.3's 7-sid validation: three baseline + four
  mirror-composed, the publisher sid included), where the merge
  happens. Consequence: **zero `internal/**` diff, no family
  fan-out** — the change set is the new leaf only. Main.tf
  carries the placement rationale; DESIGN-0028 OQ 2 carries a
  build note.
- [x] 1.5 Pin the posture in `main.tf` (no variables):
  `versioning_enabled = true`, `encryption = { mode = "s3" }`,
  `object_lock = { enabled, mode = "COMPLIANCE", days }`
  (OQ 5a), fixed-id IA lifecycle rule from
  `noncurrent_version_ia_days` (`null` = no rule, never
  expiration), `logging` resolved from `access_log_bucket` /
  `access_log_prefix` with no remote-state block.
- [x] 1.6 Outputs: `bucket_id`, `bucket_arn` (core re-exports),
  `mirror_url` (`"https://<bucket-name>.s3.<region>.amazonaws.com/"`
  from the core's `bucket_name` + `var.region`), plus the family
  test windows (`security_baseline`, `bucket_policy_json`,
  `lifecycle_rule_ids`, `logging_target`, `logging_prefix`).
- [x] 1.7 Probe P0 (design § Detailed Design): plan-render
  `principals = { "*" = ["*"] }` through the injection channel
  and confirm `aws_iam_policy_document` emits `Principal: "*"`.
  If red, the fallback is a minimal core extension (explicit
  star-principal support in the injected statement schema) in
  this same phase — the statement shape is unchanged either way.
  **GREEN 2026-09-15** — `tests/policy.tftest.hcl` run
  `probe_p0_star_principal` asserts `Principal == "*"` at plan;
  no fallback needed.
- [x] 1.8 `just tf validate s3/mirror-bucket`, `lint`, `fmt`
  green on the scaffold. (`just changed` cannot see the leaf
  until committed — untracked files are invisible to the
  branch diff; verified post-commit.)

#### Success Criteria

- `validate` + `lint` + `fmt` green; a manual plan renders all
  four statements with the intended JSON (eyeball check only —
  Phase 2 pins it).
- Probe P0 resolved green (no fallback landed).
- No `internal/**` diff (task 1.4 struck) — the change set is
  the new leaf only; `just changed` post-commit shows it in the
  plan + community tiers.

---

### Phase 2: Plan suite (the gate)

The design's Testing Strategy, item by item. All suites use the
real-provider-fake-creds pattern of the sibling purpose modules
(`provider "aws"` with test creds + skips; shared var-file
supplies `account_id = 000000000000`, `region = us-east-1`).

#### Tasks

- [ ] 2.1 `tests/security_baseline.tftest.hcl` — the documented
  **third variant**: SSE-S3 (`sse_algorithm == "AES256"`,
  `bucket_key_enabled == false`, `kms_key_arn == null`) AND
  versioning `Enabled`, otherwise the full F2 posture. Header
  comment names both divergences (access-logs = AES256 variant,
  evidence = versioning variant, mirror = both); excluded from
  the static-check byte-identical diff loop (events-bucket-only
  allowlist — no static-check edit needed).
- [ ] 2.2 `tests/policy.tftest.hcl` — statement-by-statement
  from `jsondecode(output.bucket_policy_json)`: allow sid with
  `Principal "*"`, sole action `GetObject`, objects-only
  resource (`<arn>/*` and NOT `<arn>`), `aws:SourceVpce` values
  == `vpc_endpoint_ids`; `DenyOutsideVpce` present (OQ 1a
  wiring); baseline denies present; `DenyObjectDeletion`
  unconditional (no `Condition` key) on empty break-glass +
  `StringNotEquals aws:PrincipalArn` when set; `DenyPolicyMutation`
  conditional on the admin list + absent when
  `enable_policy_mutation_guard = false`; publisher allow absent
  by default, rendered with the three scoped actions when set;
  additive merge run (operator statement coexists, baseline +
  mirror statements intact).
- [ ] 2.3 `tests/validation.tftest.hcl` — rejection runs: empty
  `vpc_endpoint_ids`, malformed vpce id, empty
  `policy_admin_principal_arns`, wildcard/malformed/duplicate
  principal ARNs (each list), `kms_key_arn` with SSE-S3 (core
  precondition, free), reserved-sid collisions against all six
  sids (three baseline + three mirror), retention-days-set
  with `enable_object_lock = false` (core coherence guard,
  free). **Per-rule verification** (message-probe or mutation,
  the IMPL-0020 recipe): several validations stack on the same
  variables, so each run must be proven to fire its own rule.
- [ ] 2.4 `tests/default.tftest.hcl` — `mirror_url` exact
  equality incl. trailing slash; IA rule id present with
  configured days / absent when `null` (via
  `lifecycle_rule_ids`); explicit logging target + null-prefix
  default (`<composed-name>/`); `null` target = no logging
  (`logging_target == null`, zero `aws_s3_bucket_logging`
  resources); composed-name + `name_override` runs.
- [ ] 2.5 `just tf test s3/mirror-bucket` fully green;
  `just static` green (fmt/validate/tflint/docs + conftest;
  `USAGE.md` regenerated, no stale docs).

#### Success Criteria

- Plan suite green end-to-end; every `expect_failures` run
  verified per-rule (no run passes off a neighbouring rule).
- The design's acceptance bar, plan half: all four statements +
  baseline denies pinned, `mirror_url` asserted with trailing
  slash.
- `just static` green with the new leaf included.

---

### Phase 3: Apply, sandbox proof, and closure

Live tiers plus the release. The Community apply follows the
`s3/bucket` fixture shape minus the sink module (explicit target
= the fixture owns a plain target bucket; no remote-state read
exists to prove).

#### Tasks

- [ ] 3.1 `tests-localstack/apply_localstack.tftest.hcl`
  (token-free 4.4, `SERVICES=s3,sts`, `s3_use_path_style`):
  fixture creates a plain target bucket; runs assert the
  logging target/prefix round-trip, the F2 + pinned posture
  (`security_baseline` incl. AES256 + `Enabled`), the four sids
  present in the applied policy, and `mirror_url` shape. Lock
  runs (if any) keep retention days = 1 and write **no
  objects** (COMPLIANCE teardown discipline, IMPL-0021 probe B).
- [ ] 3.2 Run live (`just tf test-localstack s3/mirror-bucket`),
  record environment + results in `tests-localstack/FINDINGS.md`.
  Per OQ 3's resolution, adjust to the assertable depth if
  LocalStack mangles the star-principal statement — never a
  vacuously-passing assertion.
- [ ] 3.3 `tests-sandbox/` shell runbook (OQ 8a): apply the
  module in the sandbox account, put a canary object as admin,
  then prove the **negative legs**: direct anonymous GET fails,
  delete as non-break-glass fails, `put-bucket-policy` as
  non-admin fails. (The VPCE positive leg is out of scope —
  gh-122.) Canary cleanup via a sandbox-only
  `break_glass_principal_arns = [<operator>]` (never the
  production default `[]`), then destroy. Record every result
  in `tests-sandbox/FINDINGS.md`.
- [ ] 3.4 READMEs: module README (serving posture, break-glass
  runbook — reviewed PR adds principal / applies / deletes /
  reverts — brownfield note, COMPLIANCE warning when lock is
  enabled), `USAGE.md` via terraform-docs.
- [ ] 3.5 CLAUDE.md s3-family section: the mirror row (pinned
  SSE-S3 + versioning variant, explicit-target logging, no
  globals beyond account/region, sandbox-run precedent).
- [ ] 3.6 `docz update` (revert unrelated ToC churn — the
  docz-version anchor drift; keep only the IMPL-0025 row),
  `just readme` module-table row, DESIGN-0028 → Implemented.
- [ ] 3.7 One PR per OQ 1's resolution carrying all three
  phases as separate commit groups; `### RELEASE NOTES`
  carries the mirror-bucket introduction; label `minor`.

#### Success Criteria

- The design's acceptance bar, live half: Community apply
  green; sandbox run proves denied direct reads / deletes /
  mutations, recorded in FINDINGS.md. (The VPCE-positive-leg
  proof is gh-122, not this IMPL.)
- `just static` + full s3 family plan fan-out green at merge;
  sluice workstream 2 unblocked (`mirror_url` consumable by the
  Atlantis `.terraformrc` cutover).

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/s3/mirror-bucket/**` | Create | root, plan suite, Community apply + FINDINGS.md, sandbox runbook + FINDINGS.md |
| `CLAUDE.md` | Modify | s3 family section: mirror row |
| `docs/design/0028-*.md` | Modify | status → Implemented at closure |
| `README.md` (root module table) | Modify | `mirror-bucket` row via `just readme` |

## Testing Plan

The design's Testing Strategy section is the authority; the phases
above carry it task-by-task. Fleet mechanics that apply here:

- `mock_provider` is structurally impossible for any module
  touching `ephemeral` types only — not the case here; the
  sibling-purpose-module real-provider-fake-creds plan pattern
  applies (no ephemeral resources in this module).
- Every `expect_failures` run gets per-rule verification
  (message-probe or mutation) — explicit in task 2.3, since
  several validations stack on `vpc_endpoint_ids` and the
  principal lists.
- The `internal/**` reserved-sid edit fans out to every s3 leaf
  via `scripts/changed-modules.sh` — run the full family, not
  just the new module (Phase 1 success criteria).
- Community apply: token-free 4.4 (`SERVICES=s3,sts`,
  `s3_use_path_style`) — no token is ever wired into it.
- F6 probe discipline for both live tiers: assert what
  round-trips / evaluates; record enforcement depth in
  FINDINGS.md; no vacuous assertions.
- The static-check diff loop needs no edit (events-bucket-only
  allowlist); the mirror baseline suite is the third documented
  variant.

## Dependencies

- None on other queued work — parallel with everything in
  flight.
- The sluice rollout (live-repo side, program phase 5) depends
  on **this** landing: the Atlantis `.terraformrc` cutover
  consumes `mirror_url`, and the mirror stack must exist before
  the CLI's publisher has a write target.
- DESIGN-0019 / IMPL-0018 family architecture — implemented;
  the core and its injection channel are the substrate.
- DESIGN-0022 / IMPL-0021 — the Object Lock core capability,
  variant-suite precedent, probe discipline, and teardown
  rules reused here.

## Open Questions

> **All resolved 2026-09-15: 1a, 2c, 3a.** OQ 2 resolved
> against the recommendation and then moved out entirely: the VPCE
> positive-leg evaluation lives in **gh-122**, outside this IMPL's
> scope (task 3.3 and the Phase 3 success criteria carry no
> positive-leg content).

### 1. What is the PR and release cadence?

**Resolved: a.** One PR, three phases as commit groups, one
`minor` release.

The change set spans a core edit (family fan-out) plus a new
leaf. Follows IMPL-0021 OQ 1's precedent.

- **a. (Recommended)** **One PR, all three phases as separate
  commit groups, one `minor` release.** The core edit is
  validation-only with no consumer except the new module, so a
  split buys no isolation — each PR would pay the identical
  full-family fan-out, and an intermediate tag (guard edit
  without its module) is meaningless. One tag gives the sluice
  rollout a single version to pin.
- b. Two PRs: core guard edit first (patch), then the module
  (minor) — smaller reviews, at the cost of a second full
  fan-out and a tag nothing consumes.
- Other: (your call)

### 2. Where does the sandbox positive-leg client run?

**Resolved: c — then moved out of this IMPL entirely.**
Tracked in **gh-122**; no positive-leg content remains below.

The negative legs (direct GET fails, delete/mutation denied)
run from anywhere. The positive leg — anonymous GET **via the
VPCE succeeds** — needs a client whose traffic to S3 routes
through the sandbox VPC's gateway endpoint.

- **a. (Recommended)** **Ephemeral, via the runbook, in the
  sandbox VPC.** The runbook starts a micro instance (or uses
  SSM on an existing one), ensures a gateway VPCE for S3 is
  routed, curls both paths from inside, then terminates the
  instance (and removes the endpoint/route association if it
  created them). Hermetic proof, no standing infra, no
  dependency on sandbox pre-state.
- b. Reuse an existing sandbox instance + endpoint — cheaper
  per run, but the proof depends on pre-state the runbook
  neither owns nor documents, and rots when the sandbox is
  rebuilt.
- c. Defer the positive leg to VPC-attached platform runners
  (the sluice roadmap's cross-cutting dependency, workstreams
  3/5) — ship with negative-leg + plan evidence only. Delays
  the design's headline acceptance proof on another program's
  timeline.
- Other: (your call)

### 3. What if LocalStack mangles the star-principal policy?

**Resolved: a.** Probe during Phase 3, record, assert the
assertable depth — Community stays the only apply tier.

No family suite has stored a `Principal "*"` bucket policy on
LocalStack; 4.4 may round-trip it, normalize it, or reject it.
Mirrors IMPL-0021 OQ 2's shape.

- **a. (Recommended)** **Probe during Phase 3, record in
  FINDINGS.md, assert the assertable depth — Community stays
  the only apply tier either way.** If the emulator normalizes
  the statement, the suite asserts what's actually stored (or
  drops to plan-tier coverage for that statement) rather than
  carrying a vacuously-passing assertion. Enforcement semantics
  are AWS's contract and are proven by the sandbox run, not the
  emulator.
- b. Add a `tests-localstack-pro` fidelity probe for the s3
  family — deeper recorded evidence, but a new Pro dependency
  in a family that has none, for a question the sandbox run
  answers authoritatively anyway.
- Other: (your call)

## References

- **DESIGN-0028** — the parent design (all eight OQs resolved
  2026-09-15 to `a`; probe P0; Testing Strategy; Phases).
- **gh-121** — `feat(s3): new mirror-bucket purpose module per
  sluice DESIGN-0002` (commissioning issue).
- **Sluice DESIGN-0002 + roadmap** — upstream spec; workstream 2
  runs parallel with the CLI; program phase 5 consumes
  `mirror_url`.
- DESIGN-0019 / IMPL-0018 / INV-0009 — family architecture,
  additive injection, reserved-sid pattern, wrapper gotchas.
- DESIGN-0022 / IMPL-0021 / INV-0011 — Object Lock capability,
  variant suites (this adds the third), probe + teardown
  discipline, one-PR precedent (OQ 1a there).
- IMPL-0015 — two-globals footprint; uniform injection
  (undeclared inputs ignored).
- IMPL-0020 — per-rule `expect_failures` verification,
  coherence-guard reuse.
- IMPL-0022 — one-validation-per-rule doctrine.
- ADR-0020 — `s3` state shape (no new rows).
