---
id: IMPL-0021
title: "S3 evidence bucket and lifecycle tiering exposure"
status: In Progress
author: Donald Gifford
created: 2026-09-04
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0021: S3 evidence bucket and lifecycle tiering exposure

**Status:** In Progress
**Author:** Donald Gifford
**Date:** 2026-09-04

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Core capability and type extension](#phase-1-core-capability-and-type-extension)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Bucket and events-bucket lifecycle exposure](#phase-2-bucket-and-events-bucket-lifecycle-exposure)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Evidence bucket module](#phase-3-evidence-bucket-module)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Apply probes and closure](#phase-4-apply-probes-and-closure)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. What is the PR and release cadence?](#1-what-is-the-pr-and-release-cadence)
  - [2. What happens if probe B finds no retention enforcement?](#2-what-happens-if-probe-b-finds-no-retention-enforcement)
- [References](#references)
<!--toc:end-->

## Objective

Implement DESIGN-0022's two S3 additions riding one internal-core
change set: the Object Lock capability entering through
`modules/s3/internal/core` (default = hard no-op for every existing
bucket) with the NEW `modules/s3/evidence-bucket` purpose module
exposing it — COMPLIANCE-mode default retention, the platform's
"admins cannot shorten" evidence requirement — and the lifecycle
tiering extension: storage-class transitions in the core type, the
full typed `lifecycle_rules` surface on `s3/bucket` and
`s3/events-bucket`, and the F5 coverage-gap closures.

**Implements:** DESIGN-0022 (all four OQs resolved 2026-08-27 — 1a
[retention duration required, no default], 2a [evidence bucket gets
the full lifecycle surface], 3a [events-bucket parity, same PR], 4a
[policy hardening deferred]), from INV-0011 (F2/F4/F5, OQs
6a/7a/8a).

**Sequencing:** the hub buildout is unblocked (`v0.21.0`) and Loki
is the planned fast-follow. Object Lock is **create-time** — the
Loki archive bucket must be *born* through `evidence-bucket` or the
platform knowingly accepts a later new-bucket-plus-copy cutover — so
this IMPL is the next S3 work in line and precedes the Loki stack
landing (the design's 2026-09-01 sequencing note).

## Scope

### In Scope

- `modules/s3/internal/core`: the `object_lock` input (three
  validations including the post-IMPL-0020-review **coherence
  guard**), the versioning-coupling precondition, the bucket/config
  wiring with the default-no-op guarantee; the lifecycle type
  extension (transitions + noncurrent transitions, storage-class
  validation) and the F5 coverage-gap closures.
- `modules/s3/bucket` + `modules/s3/events-bucket`: the typed
  `lifecycle_rules` surface, the reserved-id root mirror, the
  `lifecycle_rule_ids` re-export (OQ 3a parity — divergence stays
  notification.tf-only).
- `modules/s3/evidence-bucket` (NEW): pinned versioning + lock,
  required retention (OQ 1a), the full reference-consumer surface
  including lifecycle (OQ 2a), the variant baseline suite, the
  evidence-only `object_lock` output.
- Community apply probes A/B + FINDINGS.md.
- Closure: READMEs, CLAUDE.md family section, INV-0011 delivery
  note, `just readme`, docz.

### Out of Scope

From the design's Non-Goals, plus the deferred OQ:

- Object Lock knobs on `s3/bucket` or `events-bucket` (DESIGN-0019
  Non-Goals, reconfirmed INV-0011 OQ 6a).
- Legal holds (per-object, API-time — not bucket infrastructure).
- The AWS-support `token` path for enabling lock on existing
  buckets — brownfield = new evidence bucket + copy, README-noted.
- The remaining purpose modules (`cloudfront-origin-bucket`,
  `presigned-transfer-bucket`) — still deferred per IMPL-0018.
- Bucket-side replication/backup for evidence.
- Policy hardening beyond the F2 baseline denies (OQ 4a — deferred;
  COMPLIANCE mode's guarantee does not depend on bucket policy).

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all
its tasks are checked off and its success criteria are met.

---

### Phase 1: Core capability and type extension

Both additions enter the core here — `aws_s3_bucket` lives only in
the core, and any `internal/**` diff re-tests every s3 leaf, which
is why the whole change set rides one PR series (OQ 1).

#### Tasks

- [x] 1.1 `object_lock` variable in
      `modules/s3/internal/core/variables.tf` — the DESIGN-0022
      spec verbatim: `{enabled, mode, days, years}`, default `{}`,
      `nullable = false`, three validations — mode enum
      (GOVERNANCE | COMPLIANCE), days-xor-years, and the
      **retention-set-but-disabled coherence guard** (the
      post-IMPL-0020-review addition: `{ days = 400 }` without
      `enabled = true` must fail at plan, not silently configure
      nothing).
- [x] 1.2 `bucket.tf` wiring: `object_lock_enabled =
      var.object_lock.enabled` on `aws_s3_bucket.this` (explicit
      false == today's absent argument — the zero-diff guarantee);
      the count-gated `aws_s3_bucket_object_lock_configuration`
      (`enabled && (days != null || years != null)`; lock-on with
      both null is legal — per-object retention only); the
      versioning precondition (`!var.object_lock.enabled ||
      var.versioning_enabled`) with both variables named in the
      message.
- [x] 1.3 Lifecycle type extension: `extra_lifecycle_rules` entries
      gain optional `transitions` + `noncurrent_version_transitions`
      lists (default `[]` — additive, existing callers unchanged);
      matching `dynamic "transition"` /
      `dynamic "noncurrent_version_transition"` blocks in the core's
      `dynamic "rule"`; `storage_class` validation against the six
      transition targets. Per-rule day-ordering stays with the S3
      API (the design's call — no cross-field arithmetic).
- [x] 1.4 Core plan additions in `internal/core/tests/`: the
      **default-run no-op pin** (`object_lock_enabled == false` +
      zero config resources — the existing-bucket guarantee); the
      enabled run (config resource + mode/days); the
      lock-enabled-no-retention run (config count 0);
      `expect_failures` runs for the versioning precondition,
      days-xor-years, and the coherence guard; transition +
      noncurrent-transition rendering; the F5 closures
      (`noncurrent_version_expiration_days`, `enabled = false`,
      `prefix`).
- [x] 1.5 Per-rule verification of every new `expect_failures` run
      (message-probe or mutation, per the CLAUDE.md recipe) — three
      validations and a precondition now stack on this surface, and
      a passing run proves only that the object errored, not which
      rule fired.
- [x] 1.6 Full family fan-out: `just changed` shows every s3 leaf;
      run all family plan suites green.
- [x] 1.7 `just tf all` on the core; conventional commit.

#### Success Criteria

- The default core run pins the no-op — existing buckets replan
  zero-diff against the new core.
- Every new fail-closed rule proven to fail on its **own** rule.
- The family fan-out (core + all four leaf modules) green; `just
  static` green.

---

### Phase 2: Bucket and events-bucket lifecycle exposure

The INV-0011 OQ 8a surface, landed on both forks in one pass so the
"bucket plus notification.tf" fork contract stays honest (OQ 3a).

#### Tasks

- [x] 2.1 `s3/bucket`: `lifecycle_rules` variable typed identically
      to the extended core shape, passed straight through to
      `extra_lifecycle_rules`; the reserved-id validation
      (`abort-incomplete-multipart-upload`) **mirrored at the root**
      (`expect_failures` cannot target a child module's validation —
      the family's established mirroring rule).
- [x] 2.2 `lifecycle_rule_ids` output re-export on `s3/bucket`.
- [x] 2.3 `s3/events-bucket`: the identical variable + passthrough +
      re-export — divergence between the forks stays
      notification.tf-only.
- [x] 2.4 Plan additions in both modules: passthrough asserted via
      `lifecycle_rule_ids` ordering (baseline MPU-abort rule first),
      a transitions-rendering run, reserved-id rejection — plus its
      per-rule verification.
- [x] 2.5 Diff-guard check: the `bucket`/`events-bucket`
      byte-identical `security_baseline.tftest.hcl` pair still
      passes untouched (the baseline suite does not cover
      lifecycle).
- [x] 2.6 Gates (`just tf all` both modules); conventional commit.

#### Success Criteria

- The two forks carry an identical lifecycle surface; the
  diff-guard pair remains byte-identical.
- Reserved-id rejected at the root of both modules, proven per-rule.

---

### Phase 3: Evidence bucket module

The purpose module — structurally a `bucket` fork with the evidence
posture pinned and the retention surface as its one new variable.

#### Tasks

- [x] 3.1 Scaffold `modules/s3/evidence-bucket` as a `bucket` fork:
      **pinned, no variables** — `versioning_enabled = true` and
      `object_lock.enabled = true` into the core; the `retention`
      object (`mode` optional, default `"COMPLIANCE"`; `days` /
      `years` with **no default — exactly one required**, OQ 1a)
      mapped onto the core's `object_lock`. The
      exactly-one-duration validation lives at this root (the core
      only rejects both-set). Honor the wrapper-module
      `required_providers` gotcha (root declares aws even with no
      direct aws resource, tflint-ignored).
- [x] 3.2 The full reference-consumer surface carried over from
      `bucket`: composed naming + shard prefix, the `access_logging`
      tri-state (count-gated reserved-key read),
      `additional_policy_statements` + the mirrored reserved-sid
      guard, SSE-KMS default + CMK override, the six Terragrunt
      globals, `force_destroy` (default false — README notes it
      cannot override lock retention), and the full
      `lifecycle_rules` surface (OQ 2a — evidence data is exactly
      the long-retention data that needs Glacier tiering).
- [x] 3.3 Outputs: the NEW evidence-only `object_lock` output —
      `{ mode, days, years }` **attribute-derived** from the config
      resource (the family doctrine); the standard
      `security_baseline` re-export (shared shape untouched — lock
      facts ride the separate output so nothing ripples into the
      other family suites); `lifecycle_rule_ids`.
- [x] 3.4 The variant `security_baseline.tftest.hcl`: asserts
      `versioning_status == "Enabled"`, otherwise the full F2
      posture; header comment naming exactly which assertions
      diverge and why; excluded from the byte-identical diff loop —
      the second documented variant beside `access-logs-bucket`'s
      AES256 variant (OQ 7a).
- [x] 3.5 Plan suite per the design's Testing Strategy: retention
      wiring through to the config resource (COMPLIANCE default,
      GOVERNANCE override, days and years variants); the
      required-duration and days-xor-years rejections via
      `expect_failures` + per-rule verification; the tri-state
      logging paths; policy passthrough + reserved-sid guard; the
      `object_lock` output contract; lifecycle passthrough.
- [x] 3.6 `just changed` verification: the new leaf enters the plan
      and community matrix arrays automatically (test-directory
      discovery — zero pipeline edits).
- [x] 3.7 Gates; conventional commit.

#### Success Criteria

- The variant baseline suite is green and documented; the diff-guard
  loop passes with the two variants excluded.
- The plan suite covers the Testing Strategy list, every
  fail-closed rule proven individually.
- The module appears in the `just changed` matrix with no CI edits.

---

### Phase 4: Apply probes and closure

The F6 probe discipline, then documentation and release.

#### Tasks

- [ ] 4.1 Community apply suite (`tests-localstack/`, token-free
      `localstack/localstack:4.4`, `SERVICES=s3,sts`): **probe A** —
      does 4.4 accept `object_lock_enabled` at create +
      `PutObjectLockConfiguration`? **Probe B** — does 4.4
      *enforce* retention (deny a version delete before expiry)?
      Unprobed territory (F4). The apply keeps retention
      `days = 1` and writes **no objects**, so teardown never
      fights COMPLIANCE mode.
- [ ] 4.2 Run live; FINDINGS.md records both probe outcomes; the
      baked suite asserts only what round-trips (the family rule —
      config surface, never enforcement depth; see OQ 2).
- [ ] 4.3 READMEs: the prominent COMPLIANCE warning (locked
      versions undeletable by anyone until expiry; a fat-fingered
      long retention is unfixable; a bucket holding locked versions
      cannot be deleted), the retention/expiration interplay
      section (deferred expiration, lock-compatible transitions),
      the brownfield new-bucket-plus-copy note, lifecycle docs on
      `bucket`/`events-bucket`.
- [ ] 4.4 CLAUDE.md s3 family section; INV-0011 delivery note.
- [ ] 4.5 `docz update` + the mangle-set restore; `just docs lint`.
- [ ] 4.6 `just readme` — the module table gains the
      `evidence-bucket` row. Its drift gate is the **separate**
      `readme-check` CI job that `just static` does not cover
      (IMPL-0020 shipped with this stale until caught by hand).
- [ ] 4.7 One PR carrying all four phases as separate commit groups
      (OQ 1a); `### RELEASE NOTES` carries the evidence-bucket
      introduction and the lifecycle exposure; label `minor` — one
      release, one tag for the Loki stack to pin.

#### Success Criteria

The design's: `just static` + the full s3 family plan fan-out
green; the diff-guard loop passes with the two documented variants
excluded; the live Community apply green; FINDINGS.md carries both
probe outcomes.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/s3/internal/core/variables.tf` | Modify | `object_lock` input + 3 validations; lifecycle type extension + storage-class validation |
| `modules/s3/internal/core/bucket.tf` | Modify | `object_lock_enabled`, count-gated config resource, versioning precondition, transition dynamic blocks |
| `modules/s3/internal/core/tests/` | Modify | no-op pin, lock runs, coherence/xor/precondition rejections, transition renders, F5 closures |
| `modules/s3/bucket/{variables,main,outputs}.tf` | Modify | `lifecycle_rules` + reserved-id mirror + `lifecycle_rule_ids` |
| `modules/s3/bucket/tests/` | Modify | passthrough, transitions, reserved-id rejection |
| `modules/s3/events-bucket/{variables,main,outputs}.tf` | Modify | identical parity (OQ 3a) |
| `modules/s3/events-bucket/tests/` | Modify | identical parity runs |
| `modules/s3/evidence-bucket/**` | Create | the purpose module: root, variant baseline suite, plan suite, Community apply + FINDINGS.md |
| `CLAUDE.md` | Modify | s3 family section |
| `docs/investigation/` (INV-0011) | Modify | delivery note |

## Testing Plan

The design's Testing Strategy section is the authority; the tasks
above carry it item-by-item. Fleet mechanics that apply here:

- All plan suites use the family's `mock_provider` pattern.
- Every `expect_failures` run gets per-rule verification
  (message-probe or mutation) — the CLAUDE.md recipe, carried as
  explicit tasks 1.5 / 2.4 / 3.5.
- Any `internal/**` diff fans out to every s3 leaf via
  `scripts/changed-modules.sh` — run the full family, not just the
  touched module.
- Community apply: token-free 4.4 (`SERVICES=s3,sts`,
  `s3_use_path_style`) — the family's established tier; no token is
  ever wired into it.

## Dependencies

- None on the other queued IMPLs (IMPL-0022 / IMPL-0023) — parallel
  work.
- The Loki stack (live-repo side) depends on **this** landing
  first: the archive bucket must be born locked.
- DESIGN-0019 / IMPL-0018 family architecture — implemented; the
  core, `bucket`, `events-bucket`, and `access-logs-bucket` all
  exist and are the substrate this modifies.

## Open Questions

> **All resolved 2026-09-04: 1a, 2a.** One PR carries all four
> phases as separate commit groups with one `minor` release
> (task 4.7 updated to the resolved cadence), and probe B's outcome
> lands in FINDINGS.md either way — Community stays the s3 family's
> only apply tier. No other task edits follow: the phases were
> written to the recommended shapes.

### 1. What is the PR and release cadence?

**Resolved: a.** One PR, all four phases as separate commit groups,
one `minor` release.

The design says the change set "should ride one PR series" because
`scripts/changed-modules.sh` re-tests every s3 leaf on any
`internal/**` diff. The IMPL-level question is whether that series
is one PR or two.

- **a. (Recommended)** **One PR, all four phases as separate commit
  groups, one `minor` release.** Every phase touches or depends on
  the same core change (Phases 2 and 3 both consume the Phase 1
  type; Phase 4 documents all of it), so a split buys no isolation
  — each PR would pay the identical full-family fan-out, and the
  intermediate release (core + exposure without the evidence
  module) has no consumer. One tag also gives the Loki stack a
  single version to pin for both the evidence bucket and the
  lifecycle surface.
- b. Two PRs: Phases 1–2 (core + exposure, one minor), then
  Phases 3–4 (the new module + applies, a second minor) — smaller
  reviews, at the cost of a second full fan-out, two releases, and
  an intermediate tag nothing consumes.
- Other: (your call)

### 2. What happens if probe B finds no retention enforcement?

**Resolved: a.** Record the outcome in FINDINGS.md; Community stays
the family's only apply tier either way.

Probe A (config surface) is expected to pass. Probe B — whether
LocalStack 4.4 actually **denies** a version delete before
retention expiry — is unprobed territory (INV-0011 F4), and the
answer decides nothing about the baked suite (the family rule:
assert what round-trips) but could tempt a deeper tier.

- **a. (Recommended)** **Record the outcome in FINDINGS.md and keep
  Community as the family's only apply tier either way.**
  Enforcement is AWS's contract, not the emulator's — the module's
  correctness claim is "the config surface is wired right," which
  probe A + the plan suite prove. The s3 family has no Pro tier
  today, and minting one for a single enforcement probe adds a
  token-gated dependency for evidence that live AWS provides by
  definition. Matches the F6 probe-1 precedent (log delivery:
  NEGATIVE, recorded, config-surface assertions kept).
- b. If probe B is negative on 4.4, add a `tests-localstack-pro`
  enforcement probe for the s3 family — deeper recorded evidence,
  but a new Pro dependency in a family that has none, and Pro's own
  S3 Object Lock enforcement parity is equally unverified until
  probed.
- Other: (your call)

## References

- **DESIGN-0022** — the parent design (all OQs resolved; the
  2026-09-01 amendments: the coherence validation, the sequencing
  note, the `just readme` task, the verification-discipline
  requirement).
- **INV-0011** — F2 (provider probe under `~> 6.2`), F4 (Object
  Lock through the core; COMPLIANCE semantics; the versioning
  coupling), F5 (type extension + coverage gaps), OQs 6a/7a/8a.
- **DESIGN-0019 / IMPL-0018 / INV-0009** — the family architecture,
  the purpose-module ruling, the diff-guard + variant precedent,
  the F6 probe discipline, the wrapper-module `required_providers`
  gotcha.
- **IMPL-0020** — the lessons this IMPL carries: the coherence
  validation shape (a permissive default plus a partially-specified
  input), per-rule `expect_failures` verification, the
  `readme-check` gap.
- `modules/s3/access-logs-bucket` — the variant-suite precedent.
- **ADR-0020** — the `s3` state shape (no new rows; the evidence
  bucket is a normal named stack).
