---
id: DESIGN-0022
title: "S3 evidence bucket and lifecycle tiering exposure"
status: Draft
author: Donald Gifford
created: 2026-08-27
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0022: S3 evidence bucket and lifecycle tiering exposure

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-08-27

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Change map](#change-map)
  - [Core change 1: the object lock capability](#core-change-1-the-object-lock-capability)
  - [Core change 2: the lifecycle type extension](#core-change-2-the-lifecycle-type-extension)
  - [The evidence bucket purpose module](#the-evidence-bucket-purpose-module)
  - [Bucket surface: lifecycle exposure](#bucket-surface-lifecycle-exposure)
  - [Baseline suite treatment](#baseline-suite-treatment)
  - [Retention and expiration interplay](#retention-and-expiration-interplay)
  - [Remote-state posture](#remote-state-posture)
  - [CI mechanics](#ci-mechanics)
- [Testing Strategy](#testing-strategy)
- [Phases](#phases)
  - [Phase 1: Core capability and type extension](#phase-1-core-capability-and-type-extension)
  - [Phase 2: Bucket lifecycle exposure](#phase-2-bucket-lifecycle-exposure)
  - [Phase 3: Evidence bucket module](#phase-3-evidence-bucket-module)
  - [Phase 4: Apply probes and closure](#phase-4-apply-probes-and-closure)
- [Open Questions](#open-questions)
  - [1. Is the default retention duration required or defaulted?](#1-is-the-default-retention-duration-required-or-defaulted)
  - [2. Does the evidence bucket expose lifecycle rules?](#2-does-the-evidence-bucket-expose-lifecycle-rules)
  - [3. Does events-bucket gain the same lifecycle exposure?](#3-does-events-bucket-gain-the-same-lifecycle-exposure)
  - [4. Does the evidence bucket bake extra policy hardening?](#4-does-the-evidence-bucket-bake-extra-policy-hardening)
- [References](#references)
<!--toc:end-->

## Overview

One family DESIGN, two S3 additions riding one internal-core change
set (INV-0011 OQ 2a):

1. **`modules/s3/evidence-bucket`** — a new purpose module for
   evidence-grade retention: S3 Object Lock with **COMPLIANCE**-mode
   default retention, so Loki/audit data cannot have its retention
   shortened by any principal — environment admins, hub admins, or
   root (the platform's "harness-removal" requirement; the
   requirement text lives in the platform's RFC-0001, external to
   this repo). The core grows the capability; the purpose module
   exposes it — the DESIGN-0019 "new needs = new purpose modules"
   ruling, upheld by INV-0011 OQ 6a.
2. **Lifecycle tiering exposure** — the core's `extra_lifecycle_rules`
   type gains storage-class **transitions** (it is expiration-only
   today), and `s3/bucket` exposes the full typed list at its surface
   (INV-0011 OQ 8a). This serves the platform's stated stores: S3
   backs Thanos and Loki, ClickHouse uses S3 for tiering/backups, and
   "retention and lifecycle policies are set per store."

## Goals and Non-Goals

### Goals

- Object Lock enters through the internal core (`aws_s3_bucket` lives
  only there), default **off** — a strict no-op for every existing
  bucket, since `object_lock_enabled` is create-time and toggling
  **replaces the bucket** (INV-0011 F2/F4).
- A versioning coupling guard: Object Lock requires versioning
  Enabled; the core gains the precondition (F4).
- The evidence bucket pins versioning on + lock on, COMPLIANCE default
  retention (GOVERNANCE selectable for lower-stakes tiers), and is
  otherwise the full F2 baseline — composed naming, PAB,
  BucketOwnerEnforced, SSE-KMS default, access-logging tri-state.
- Transitions land in the core type additively (existing callers
  unchanged), with the existing coverage gaps closed while in the
  file (F5: `noncurrent_version_expiration_days`, `enabled = false`,
  and `prefix` have zero test coverage today).
- `s3/bucket` re-exports `lifecycle_rule_ids` — the only lifecycle
  assertion window purpose suites have (the access-logs precedent).

### Non-Goals

- **Object Lock knobs on `s3/bucket` or `events-bucket`.** Ruled out
  by DESIGN-0019 Non-Goals and re-confirmed by INV-0011 OQ 6a against
  the platform rollup's contrary wording (the rollup amendment is a
  platform-side task).
- **Legal holds.** Per-object, API-time operations — not bucket
  infrastructure. Out of scope entirely.
- **Enabling Object Lock on existing buckets.** The AWS-support
  `token` path exists in the provider but is not exposed: brownfield
  = new evidence bucket + copy, documented in the README.
- **The remaining purpose modules** (`cloudfront-origin-bucket`,
  `presigned-transfer-bucket`) stay deferred per IMPL-0018.
- **Bucket-side replication/backup for evidence** — a future concern;
  Object Lock retention is the v1 guarantee.

## Background

INV-0011 concluded (F2, F4, F5 + OQs 6/7/8, all resolved):

- Provider surfaces verified under the pin (6.58.0, `~> 6.2`):
  `aws_s3_bucket.object_lock_enabled` (create-time, ForceNew),
  `aws_s3_bucket_object_lock_configuration` with
  `rule.default_retention` = `mode` (GOVERNANCE | COMPLIANCE) +
  `days` xor `years`, and the `transition` /
  `noncurrent_version_transition` lifecycle sub-blocks alongside the
  expiration blocks the core already renders (F2).
- COMPLIANCE mode = no principal, including root, can shorten
  retention or delete a locked version until expiry — exactly the
  requirement. GOVERNANCE is bypassable via
  `s3:BypassGovernanceRetention` (F4).
- The core's `versioning_enabled` false-branch renders `"Suspended"`;
  nothing couples lock to versioning today (F4).
- The shared `security_baseline.tftest.hcl` pins
  `versioning_status == "Suspended"`, so the evidence bucket cannot
  be byte-identical to the canonical suite — INV-0011 OQ 7a resolves
  it as a **documented variant** (the access-logs F3-variant
  precedent) with a **new evidence-module-only `object_lock`
  output**, keeping the shared `security_baseline` object shape
  untouched so nothing ripples into the other family suites.
- The platform context (INV-0011 F1): "Object storage (S3) backs
  Thanos and Loki; block storage serves only hot paths. Retention and
  lifecycle policies are set per store." The evidence requirement
  covers Loki/audit retention; the tiering exposure covers the
  Thanos/Loki/ClickHouse stores. The platform RFC-0001
  evidence-retention text remains outstanding and should be distilled
  into this design's context when shared (INV-0011 OQ 1 progress
  note) — the requirement rows stand as operator-given until then.

Prior art: DESIGN-0019 / IMPL-0018 (the family architecture, the
purpose-module ruling, the F6 probe discipline, the wrapper-module
gotchas), `access-logs-bucket` (the variant-suite precedent and the
`log_retention_days` → fixed-id core rule mapping).

## Detailed Design

### Change map

```text
modules/s3/internal/core/      MODIFY   object_lock input + config resource;
                                        lifecycle type extension; preconditions
modules/s3/bucket/             MODIFY   lifecycle_rules exposure + rule-ids re-export
modules/s3/evidence-bucket/    CREATE   the purpose module
modules/s3/events-bucket/      OQ 3     lifecycle exposure parity (or untouched)
modules/s3/access-logs-bucket/ NONE     untouched (its retention mapping already works)
```

Both additions touch the core, which is why they ride one DESIGN and
should ride one PR series: `scripts/changed-modules.sh` re-tests every
s3 leaf on any `internal/**` diff, so separate PRs would each pay the
full family fan-out.

### Core change 1: the object lock capability

A purpose-module-only input (never exposed on `bucket`/
`events-bucket`), default = hard no-op:

```hcl
variable "object_lock" {
  description = "Purpose-module-only Object Lock wiring. enabled is CREATE-TIME: toggling it on an existing bucket REPLACES the bucket. Requires versioning_enabled = true. days xor years sets the default retention; both null = lock enabled with per-object-only retention."
  type = object({
    enabled = optional(bool, false)
    mode    = optional(string, "COMPLIANCE")
    days    = optional(number)
    years   = optional(number)
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.object_lock.mode)
    error_message = "object_lock.mode must be GOVERNANCE or COMPLIANCE."
  }

  validation {
    condition     = !(var.object_lock.days != null && var.object_lock.years != null)
    error_message = "object_lock.days and object_lock.years are mutually exclusive (the S3 API takes exactly one)."
  }
}
```

Wiring in `bucket.tf`:

- `aws_s3_bucket.this` gains
  `object_lock_enabled = var.object_lock.enabled` — explicit false is
  identical to today's absent argument, so **existing buckets see a
  zero diff** (the F4 no-op requirement; the plan suite pins this
  with a default-run assertion).
- A count-gated `aws_s3_bucket_object_lock_configuration` when
  `enabled && (days != null || years != null)`; lock-enabled with
  both null is legal (per-object retention only — S3 allows it; the
  evidence module decides whether to require a default, OQ 1).
- A precondition on the versioning resource:
  `!var.object_lock.enabled || var.versioning_enabled` — Object Lock
  requires versioning Enabled and forbids suspending it (F4). The
  error message names both variables.

### Core change 2: the lifecycle type extension

`extra_lifecycle_rules` entries gain two additive optional attributes
(existing callers unchanged — the new fields default empty):

```hcl
type = list(object({
  id                                 = string
  enabled                            = optional(bool, true)
  prefix                             = optional(string)
  expiration_days                    = optional(number)
  noncurrent_version_expiration_days = optional(number)
  transitions = optional(list(object({
    days          = number
    storage_class = string
  })), [])
  noncurrent_version_transitions = optional(list(object({
    noncurrent_days = number
    storage_class   = string
  })), [])
}))
```

The core's `dynamic "rule"` grows matching `dynamic "transition"` /
`dynamic "noncurrent_version_transition"` blocks. `storage_class`
gets a validation against the S3 transition targets
(`STANDARD_IA`, `ONEZONE_IA`, `INTELLIGENT_TIERING`, `GLACIER_IR`,
`GLACIER`, `DEEP_ARCHIVE`). Per-rule ordering (transition days must
precede expiration days when both are set) is left to the S3 API —
plan-time cross-field arithmetic on optional lists is not worth the
precondition complexity, and the API error is clear.

While in the file, the F5 coverage gaps close: new core plan runs for
`noncurrent_version_expiration_days`, `enabled = false` (Disabled
status), and `prefix` filtering — plus the new transition renders.

### The evidence bucket purpose module

`modules/s3/evidence-bucket` — structurally a `bucket` fork (the
family convention), with the evidence posture pinned:

- **Pinned, no variable:** `versioning_enabled = true` (not exposed —
  suspending is forbidden on a locked bucket anyway),
  `object_lock.enabled = true`.
- **Retention surface:** `retention` object → the core's
  `object_lock` — `mode` optional, default `"COMPLIANCE"` (INV-0011
  OQ 6a: the "admins cannot shorten" requirement; GOVERNANCE stays
  selectable for lower-stakes tiers), duration per OQ 1. The README
  carries a prominent COMPLIANCE warning: locked versions are
  undeletable by anyone until expiry — a fat-fingered long retention
  is unfixable, and a bucket holding locked versions cannot be
  deleted at all.
- **Everything else is the reference-consumer surface:** composed
  naming + shard prefix, the `access_logging` tri-state (default =
  the flat reserved sink lookup, count-gated read),
  `additional_policy_statements` with the mirrored reserved-sid
  guard, SSE-KMS default with CMK override, the six Terragrunt
  globals. `force_destroy` stays exposed (default false) for
  empty-bucket test teardown, with the README noting it cannot
  override lock retention (S3 semantics, not module policy).
- **New output `object_lock`** (evidence-module-only, OQ 7a):
  `{ mode, days, years }` derived from the
  `aws_s3_bucket_object_lock_configuration` resource attributes (the
  family's attribute-derived doctrine), plus the standard
  `security_baseline` re-export and `lifecycle_rule_ids` if OQ 2
  lands lifecycle exposure here.

### Bucket surface: lifecycle exposure

`s3/bucket` gains `lifecycle_rules` (INV-0011 OQ 8a's name), typed
identically to the extended core type, passed straight through to the
core's `extra_lifecycle_rules`, plus the `lifecycle_rule_ids` output
re-export. Rule-id hygiene: the baseline MPU-abort rule id
(`abort-incomplete-multipart-upload`) is reserved — a root-side
validation rejects it in caller rules (mirrored at the root because
`expect_failures` cannot target a child module's validation — the
family's established mirroring rule).

`access-logs-bucket` is untouched: its `log_retention_days` mapping
already rides the core type and gains nothing from transitions (log
sinks expire, they do not tier).

### Baseline suite treatment

Per INV-0011 OQ 7a:

- The evidence bucket's `security_baseline.tftest.hcl` is a
  **documented variant** — asserts `versioning_status == "Enabled"`
  and otherwise the full F2 posture — and is excluded from the
  byte-identical diff loop. The `bucket`/`events-bucket` pair remains
  the diff-guard; `access-logs-bucket` (AES256 variant) and
  `evidence-bucket` (versioning variant) are the two documented
  variants, each carrying a header comment naming exactly which
  assertions diverge and why.
- The shared `security_baseline` output shape is **untouched** — lock
  facts ride the separate `object_lock` output, so no other family
  suite changes.

### Retention and expiration interplay

Documented in both the core variable and the evidence README (F4):

- Default retention applies to **new object versions** at write time;
  changing it later affects future versions only.
- Lifecycle **expiration** of a locked version is deferred by S3
  until its retention passes — an expiration rule shorter than the
  retention window silently waits (this is S3 behavior, not an
  error). Noncurrent-version expiration + Object Lock is the
  standard evidence pattern: versions become noncurrent, wait out
  retention, then expire.
- Storage-class **transitions** are unaffected by lock status —
  tiering locked evidence to Glacier is legal and expected (the cost
  story for long retention).

### Remote-state posture

The evidence bucket is a normal named stack — no reserved flat key
(that is unique to the access-logs sink singleton). Consumers that
need the bucket name/ARN read its state at the standard
`<account_name>/<region>/s3/<name>/terraform.tfstate` shape. No new
ADR-0020 rows: the `s3` shape exists.

### CI mechanics

- Any `internal/**` diff re-tests every s3 leaf
  (`scripts/changed-modules.sh` fan-out — by design; this change set
  triggers it, which is the point of one PR series).
- The new leaf enters the plan matrix + Community tier automatically
  (test-directory discovery); Phase 3 verifies with `just changed`.
- The evidence module needs the wrapper-module gotcha honored: root
  `required_providers` must declare aws even where no direct aws
  resource lives in root (tflint-ignored) — the Phase 2 lesson from
  `access-logs-bucket`.

## Testing Strategy

All plan suites use the family's `mock_provider` pattern.

**Core plan additions (`internal/core/tests/`):**

- Object lock: default run pins `object_lock_enabled = false` and
  zero config resources (the existing-bucket no-op guarantee);
  enabled run pins the resource + mode/days; versioning-coupling
  precondition and days-xor-years validation via `expect_failures`;
  lock-enabled-no-retention run (config resource count 0).
- Lifecycle: transition + noncurrent-transition rendering,
  storage-class validation, and the F5 gap closures (noncurrent
  expiration, `enabled = false`, `prefix`).

**Bucket plan additions:** `lifecycle_rules` passthrough asserted via
`lifecycle_rule_ids` ordering (baseline rule first), a
transitions-rendering run, reserved-id rejection.

**Evidence plan suite (~the family norm):** the variant baseline
suite; retention wiring (mode/days/years through to the config
resource); COMPLIANCE default + GOVERNANCE override; the pinned
versioning/lock (no exposed variable to flip); the tri-state logging
paths; policy passthrough + reserved-sid guard; the `object_lock`
output contract.

**Community apply (`tests-localstack/`, token-free 4.4,
`SERVICES=s3,sts`):** the F6 probe discipline —

- Probe A: does 4.4 accept `object_lock_enabled` at create +
  `PutObjectLockConfiguration`? (Expected yes — config surface.)
- Probe B: does 4.4 **enforce** retention (deny version delete before
  expiry)? Unprobed territory (F4); either outcome lands in
  FINDINGS.md, and the baked suite asserts only the config surface
  (the family rule: suites assert what LocalStack round-trips;
  enforcement depth is recorded, not gated on).
- The apply keeps retention days = 1 and writes **no objects** (an
  empty locked bucket deletes cleanly), so teardown never fights
  COMPLIANCE mode.

## Phases

### Phase 1: Core capability and type extension

- [ ] `object_lock` input + validations + versioning precondition +
      bucket/config wiring (default no-op pinned by a plan run)
- [ ] Lifecycle type extension + dynamic blocks + storage-class
      validation
- [ ] Core plan additions incl. the F5 coverage-gap closures
- [ ] Full family fan-out green (`just changed` shows every s3 leaf)

### Phase 2: Bucket lifecycle exposure

- [ ] `lifecycle_rules` variable + passthrough + reserved-id guard
- [ ] `lifecycle_rule_ids` re-export
- [ ] Plan additions; events-bucket parity per OQ 3's resolution

### Phase 3: Evidence bucket module

- [ ] Scaffold `modules/s3/evidence-bucket` (fork of bucket; pinned
      versioning + lock; retention surface per OQ 1)
- [ ] Variant `security_baseline.tftest.hcl` + `object_lock` output
- [ ] Plan suite per Testing Strategy; `just changed` verification

### Phase 4: Apply probes and closure

- [ ] Community apply suite + FINDINGS.md (probes A/B), run live
- [ ] READMEs: COMPLIANCE warning, retention/expiration interplay,
      brownfield note (no `token` path)
- [ ] CLAUDE.md family section update; INV-0011 delivery note;
      `docz update` (+ mangle-set restore)
- [ ] Conventional commits; PR labeled `minor`

Success criteria: `just static` + full s3 family plan fan-out green;
the diff-guard loop still passes with the two documented variants
excluded; live Community apply green.

## Open Questions

### 1. Is the default retention duration required or defaulted?

The mode defaults to COMPLIANCE (resolved, INV-0011 OQ 6a). The
duration is a different risk shape: a too-long COMPLIANCE default is
**unfixable** (locked versions survive until expiry, the bucket
cannot be deleted), a too-short default silently under-retains
evidence.

- **a. (Recommended)** Duration is **required** — the evidence
  module's `retention` object has no default `days`/`years`; every
  stack states its retention explicitly (`retention = { days = 400 }`).
  Both failure directions are eliminated at the cost of one explicit
  line per stack, which for evidence infrastructure is a feature: the
  retention period IS the design decision.
- b. Default `days = 365` — a sane evidence floor, zero-config
  bring-up; accepts the risk that a default nobody chose governs
  compliance data.
- c. Default `days = 90` — aligns with the access-logs sink's
  `log_retention_days` default; short enough to be low-regret, but
  90-day evidence retention is likely below what "harness-removal"
  auditing wants, making the default a trap in the other direction.
- Other: (your call)

### 2. Does the evidence bucket expose lifecycle rules?

Locked data still has a cost story: audit/Loki evidence ages to
Glacier tiers while retention holds (transitions are lock-compatible;
expiration defers until retention passes).

- **a. (Recommended)** Yes — the same full typed `lifecycle_rules`
  surface as `s3/bucket` (transitions + expirations), with the
  interplay section documenting deferred expiration. Evidence data is
  precisely the long-retention data that needs tiering, and the
  surface is already built in Phase 2.
- b. Expiration-only (no transitions) — smaller, but contradicts the
  cost story that makes long COMPLIANCE retention affordable.
- c. None in v1 — smallest, but the first real evidence stack
  (Loki archive) wants Glacier tiering on day one per the platform's
  "retention and lifecycle policies are set per store."
- Other: (your call)

### 3. Does events-bucket gain the same lifecycle exposure?

`events-bucket` is "bucket plus notification.tf" — a deliberate fork
pair whose `security_baseline.tftest.hcl` is the byte-identical
diff-guard.

- **a. (Recommended)** Yes — the identical `lifecycle_rules`
  variable + re-export, same PR. Keeps the fork honestly "bucket plus
  notifications" (divergence limited to notification.tf), costs one
  copied variable + one plan run, and the diff-guard pair is
  unaffected (the baseline suite does not cover lifecycle).
- b. Defer until an events-bucket consumer needs tiering — smaller
  now, but the forks drift and the eventual PR pays the same family
  fan-out again for one variable.
- Other: (your call)

### 4. Does the evidence bucket bake extra policy hardening?

Beyond Object Lock itself: deny statements pinning the lock/lifecycle
config (e.g. deny `s3:PutBucketObjectLockConfiguration` /
`s3:PutLifecycleConfiguration` to all but the deploy role).

- **a. (Recommended)** Defer — ship the F2 baseline denies only.
  COMPLIANCE mode's guarantee does not depend on bucket policy: S3
  itself refuses retention shortening for every principal including
  root, and a locked bucket cannot be deleted. Config-mutation denies
  add lockout risk (a mis-scoped deny can strand the deploy role) for
  a guarantee the lock already provides; per-stack needs ride the
  existing `additional_policy_statements` channel. Revisit with the
  platform RFC-0001 evidence text if it demands config-pinning
  explicitly.
- b. Bake opt-out deny statements now (config-pinning as default
  posture) — defense in depth for the config surface (retention
  *lengthening* and lifecycle edits remain possible in a), at the
  cost of reserved-sid surface growth and the lockout footgun.
- Other: (your call)

## References

- **INV-0011** — the parent investigation: F2 (provider probe), F4
  (Object Lock enters through the core; COMPLIANCE semantics;
  baseline friction), F5 (the type extension + coverage gaps),
  OQ 6a/7a/8a resolutions, F1 (platform context: Thanos/Loki/
  ClickHouse stores, the external "harness-removal" requirement, the
  rollup conflict resolved in favor of the purpose module).
- DESIGN-0019 / IMPL-0018 / INV-0009 — the family architecture, the
  purpose-module ruling, the diff-guard + variant precedent, the F6
  probe discipline, the wrapper-module `required_providers` gotcha.
- `modules/s3/access-logs-bucket` — the variant-suite precedent and
  the retention-days → core-rule mapping pattern.
- Platform RFC-0001 (external, outstanding) — the evidence-retention
  requirement text; to be distilled into this design's Background
  when shared (INV-0011 OQ 1).
- Platform Central Monitoring Stack ADR + DESIGN-0001 (external,
  distilled in INV-0011 F1) — "Object storage (S3) backs Thanos and
  Loki"; "retention and lifecycle policies are set per store."
- ADR-0020 — the `s3` state shape (no new rows needed).
