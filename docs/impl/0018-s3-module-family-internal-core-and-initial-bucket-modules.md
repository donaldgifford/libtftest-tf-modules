---
id: IMPL-0018
title: "S3 module family internal core and initial bucket modules"
status: Draft
author: Donald Gifford
created: 2026-08-02
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0018: S3 module family internal core and initial bucket modules

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-08-02

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Internal core module and CI plumbing](#phase-1-internal-core-module-and-ci-plumbing)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: access-logs-bucket producer](#phase-2-access-logs-bucket-producer)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: bucket reference consumer](#phase-3-bucket-reference-consumer)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: events-bucket](#phase-4-events-bucket)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Guards, fleet verification, and doc closure](#phase-5-guards-fleet-verification-and-doc-closure)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. What is the PR and release cadence across the five phases?](#1-what-is-the-pr-and-release-cadence-across-the-five-phases)
  - [2. What type does the policy-statement variable surface use?](#2-what-type-does-the-policy-statement-variable-surface-use)
  - [3. How is the shared baseline test suite kept identical across modules?](#3-how-is-the-shared-baseline-test-suite-kept-identical-across-modules)
  - [4. How are the two LocalStack fidelity probes executed?](#4-how-are-the-two-localstack-fidelity-probes-executed)
  - [5. Which LocalStack image do the s3 Community apply suites pin?](#5-which-localstack-image-do-the-s3-community-apply-suites-pin)
- [References](#references)
<!--toc:end-->

## Objective

Build the `modules/s3/` family exactly as designed: the shared internal
core at `modules/s3/internal/core` (relative-path source, never
versioned), then `s3/access-logs-bucket`, `s3/bucket`, and
`s3/events-bucket` on top of it, with the F2 security baseline, the
tri-state access-logging contract on the reserved
`<account_name>/<region>/s3/access-logs/terraform.tfstate` key, ADR-0020
assertions/README contracts from the first commit, and LocalStack
Community apply coverage including the two F6 fidelity probes.

**Implements:** DESIGN-0019 (all five phases; all design OQs resolved
2026-08-02). Execution tracking lives in this document — one IMPL for the
whole family, per operator direction.

**Research findings folded in below** (both discovered while writing this
doc, both corrected in Phase 1):

1. The justfile's `tf_test_varfile` is a *relative* path with three `../`
   segments, so every `just tf test*` recipe assumes depth-3 module
   directories. The core at `modules/s3/internal/core` is depth 4 — the
   var-file would resolve to a nonexistent path and `terraform test`
   would error. One-line fix: hoist the variable to an absolute path
   built from `justfile_directory()`.
2. `scripts/changed-modules.sh` has no internal-module fan-out (a core
   edit would not re-run the purpose modules' plan suites) — already a
   named task in DESIGN-0019 Phase 1.

## Scope

### In Scope

- `modules/s3/internal/core` + the three consumable modules and their
  full test surfaces (core plan suite, per-module plan suites including
  the shared baseline suite, three Community apply suites).
- justfile var-file path fix; changed-modules.sh internal fan-out rule +
  self-test cases; Phase-5 static-gate guards (versioned-core-source
  grep, baseline-suite identity check).
- ADR-0020 additions (s3 producer/consumer rows, conditional-read note),
  per-module README contract sections, CLAUDE.md, root README regen.
- F6 probes 1 (log delivery) and 2 (notification firing) with outcomes
  recorded in FINDINGS.md; negative probes fall back to config-surface
  depth (DESIGN-0019 OQ 6a).
- docz closure: INV-0009 → Concluded, DESIGN-0019 → Implemented, this
  IMPL → Completed.

### Out of Scope

- `s3/cloudfront-origin-bucket`, `s3/presigned-transfer-bucket`
  (deferred per INV-0009 OQ 8; cataloged in INV-0009 F5).
- Any live-repo (Terragrunt) changes; the reserved stack path is enforced
  there, documented here.
- SQS/SNS/EventBridge destination resources beyond test fixtures.
- Replication, object lock, website hosting, CORS, MFA delete.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its
tasks are checked off and its success criteria are met. Conventional
commit per numbered task; run `just tf fmt|lint <module>` after each
task.

---

### Phase 1: Internal core module and CI plumbing

Everything later phases stand on: the core module, its direct plan
suite, and the two CI corrections.

#### Tasks

- [x] 1.1 justfile: hoist `tf_test_varfile` to an absolute path
      (`justfile_directory() + "/test/fixtures/terragrunt-inputs.tfvars"`)
      so depth-4 module dirs resolve the shared var-file; verify an
      existing module still passes (`just tf test network/vpc-lookup`)
- [x] 1.2 Scaffold `modules/s3/internal/core`: versions.tf
      (`required_version = ">= 1.1"`, aws `~> 6.2`, random `~> 3.7`),
      `.tflint.hcl` + `.terraform-docs.yml` copied from
      `network/vpc-lookup`, README (not independently consumable; nesting
      exemption + never-versioned condition), generated USAGE.md
- [x] 1.3 naming.tf: `name` validation (lowercase alnum + hyphens, 3-37),
      `name_override`, count-gated `random_string` (5 lowercase alnum)
      behind `shard_prefix_enabled`, composed-name local; destructive
      shard-toggle note in README
- [x] 1.4 bucket.tf: `aws_s3_bucket` (+ `force_destroy`, tags),
      public-access block (all four on, no variables), ownership controls
      (BucketOwnerEnforced, no variable), versioning (`versioning_enabled`
      default false), SSE configuration from the `encryption` object (kms
      default + `bucket_key_enabled`, s3 mode, CMK pass-through),
      lifecycle (`abort_incomplete_multipart_days` default 7 +
      `extra_lifecycle_rules`); preconditions: composed-name
      length/charset, `kms_key_arn` requires kms mode
- [x] 1.5 policy.tf: composed policy document — fixed
      `DenyInsecureTransport` + `DenyOldTls` sids, opt-in VPCE deny from
      `allowed_vpc_endpoint_ids`, `internal_policy_statements` merge
      (OQ 2a: typed object list — required `sid`, optional
      effect/principals/conditions) with the reserved-baseline-sid
      validation; one `aws_s3_bucket_policy`
- [x] 1.6 logging.tf: `logging` object input, count-gated
      `aws_s3_bucket_logging`, null-prefix defaulting to
      `<composed-name>/`, self-logging precondition
- [ ] 1.7 outputs.tf: `bucket_id` / `bucket_name` / `bucket_arn`,
      `bucket_policy_json`, `logging_target` + `logging_prefix`,
      attribute-derived `security_baseline` object (DESIGN-0019 shape)
- [ ] 1.8 Core plan suites (`tests/`): baseline defaults, encryption
      modes (kms default / CMK / s3), naming + shard + override, policy
      sid composition via jsondecode, logging tri-state wiring + prefix
      default, validation.tftest.hcl `expect_failures` (name charset +
      bounds, composed length, kms-key-on-s3-mode, reserved sid,
      self-logging)
- [ ] 1.9 changed-modules.sh: internal fan-out rule (diff under
      `modules/<service>/internal/**` adds every leaf module under
      `modules/<service>/`) + changed-modules.test.sh cases via the
      `CHANGED_FILES_OVERRIDE` seam
- [ ] 1.10 CLAUDE.md: start the `modules/s3/` section (core + family
      shape); commit

#### Success Criteria

- `just tf validate|fmt|lint|test s3/internal/core` all green — proving
  the depth-4 var-file fix and the core suite together
- `scripts/changed-modules.test.sh` green including the fan-out cases (a
  seeded core-file change lists every s3 leaf module)
- `just static` green repo-wide (core auto-discovered, USAGE.md fresh)
- `just tf test network/vpc-lookup` still green (var-file fix regressed
  nothing)

---

### Phase 2: access-logs-bucket producer

The per-region log sink; producer of the reserved-key contract.

#### Tasks

- [ ] 2.1 Module: core call with SSE-S3 pinned
      (`encryption = { mode = "s3" }`), versioning pinned off, **no**
      access_logging surface; log-delivery grant via
      `internal_policy_statements` (`logging.s3.amazonaws.com`,
      `s3:PutObject` on `<arn>/*`, `aws:SourceAccount` condition —
      DESIGN-0019 OQ 2a); retention via `extra_lifecycle_rules`
      (`log_retention_days` default 90, null disables — OQ 1a); `name`
      defaults to `"access-logs"` (OQ 3a)
- [ ] 2.2 variables.tf (name-composition globals `account_id` +
      `region`, retention, shard/name_override/force_destroy/tags
      pass-throughs) and outputs.tf (contract `bucket_name` + additive
      `bucket_arn` / `bucket_id`, `security_baseline` re-export)
- [ ] 2.3 Plan suites: `security_baseline.tftest.hcl` (the canonical
      first copy), default.tftest.hcl (AES256, grant sid + condition,
      retention rule, composed default name
      `access-logs-<account_id>-<region>`), validation.tftest.hcl
- [ ] 2.4 Community apply suite (`tests-localstack/`) + FINDINGS.md
      (OQ 5a: token-free `localstack/localstack:4.4`, minimal SERVICES)
- [ ] 2.5 README with the ADR-0020 producer contract section (reserved
      key, non-default-sink pattern); USAGE.md
- [ ] 2.6 ADR-0020: s3 producer row + reserved-stack-name note
- [ ] 2.7 CLAUDE.md; root README module table regen (`just readme`);
      commit

#### Success Criteria

- `just tf test s3/access-logs-bucket` and
  `just tf test-localstack s3/access-logs-bucket` green
- ADR-0020 carries the s3 producer row; `just static` green

---

### Phase 3: bucket reference consumer

The general-purpose bucket; the fleet's first count-gated remote-state
read.

#### Tasks

- [ ] 3.1 Module: six Terragrunt globals; tri-state `access_logging`;
      remote_state.tf — count-gated read of the reserved key with
      `assume_role` + `region = remote_state_bucket_region`; resolved
      logging into the core; baseline pass-throughs (`versioning_enabled`,
      `kms_key_arn`, `force_destroy`, `allowed_vpc_endpoint_ids`,
      `shard_prefix_enabled`, `name_override`, MPU days, tags)
- [ ] 3.2 `additional_policy_statements` pass-through into the core's
      `internal_policy_statements` (DESIGN-0019 OQ 4b: additive-only;
      the core's reserved-sid validation is the guard)
- [ ] 3.3 Plan suites: `security_baseline.tftest.hcl` copy;
      default.tftest.hcl — override_data stub + ADR-0020 assertion
      (`config.key == "sandbox/us-east-1/s3/access-logs/terraform.tfstate"`
      on the enabled path), zero-instance assertions on the disabled and
      override paths, additive statement rendering beside intact baseline
      sids; validation.tftest.hcl (tri-state combinations, reserved-sid
      `expect_failures`)
- [ ] 3.4 Community apply: `fixtures/access-logs` instantiating the
      **real** access-logs-bucket module + seeding the reserved-key state
      object into the shared `remote_state_bucket` (proxy / read-replica
      composing-fixture precedent); apply with the default lookup;
      **F6 probe 1** (log-delivery materialization; OQ 4a: manual probe
      first, then bake only the assertable depth) → FINDINGS.md
- [ ] 3.5 README consumer contract section; USAGE.md
- [ ] 3.6 ADR-0020: consumer row + the conditional-read note
- [ ] 3.7 CLAUDE.md; root README regen; commit

#### Success Criteria

- All three tri-state paths pinned green in the plan suite
- Community apply green end-to-end: reserved key seeded by the fixture,
  read back through `assume_role`, logging wired to the sink
- Probe-1 outcome recorded in FINDINGS.md either way (negative →
  config-surface depth per DESIGN-0019 OQ 6a)

---

### Phase 4: events-bucket

#### Tasks

- [ ] 4.1 Module: bucket surface (tri-state +
      `additional_policy_statements` included) + notification.tf —
      the singleton `aws_s3_bucket_notification` in the module root,
      typed `sns_topics` / `sqs_queues`
      lists (arn, events, filter_prefix, filter_suffix) +
      `eventbridge_enabled` bool (DESIGN-0019 OQ 5a),
      at-least-one-destination precondition
- [ ] 4.2 Plan suites: `security_baseline.tftest.hcl` copy; notification
      shape assertions; ADR-0020 three-path assertions; validation
      (no-destination `expect_failures`)
- [ ] 4.3 Community apply: SQS queue + queue-policy fixture
      (+ EventBridge enabled run); **F6 probe 2** (notification firing;
      OQ 4a: manual probe first) → FINDINGS.md
- [ ] 4.4 README (contract section + destination-policy ownership note);
      USAGE.md; CLAUDE.md; root README regen; commit

#### Success Criteria

- `just tf test s3/events-bucket` and
  `just tf test-localstack s3/events-bucket` green
- Probe-2 outcome recorded in FINDINGS.md either way

---

### Phase 5: Guards, fleet verification, and doc closure

#### Tasks

- [ ] 5.1 Static-gate guards: versioned-core-source grep (the core is
      consumed only via the relative path — no registry/git-ref source
      anywhere under `modules/s3/`) + baseline-suite identity check
      (OQ 3a: `diff -q` across the three copies)
- [ ] 5.2 Full pass from a clean tree: `just static`; all four plan
      suites; all three Community applies
- [ ] 5.3 Fidelity greps: reserved-key literal consistent across module
      code, tests, ADR-0020, and READMEs; no un-prefixed fixture keys
- [ ] 5.4 docz closure: INV-0009 → Concluded (probe outcomes recorded in
      its F6), DESIGN-0019 → Implemented, this IMPL → Completed;
      `docz update` (restore any TOC mangling); root README regen; commit

#### Success Criteria

- Everything green in one run from a clean tree
- Both guards fail the static gate when deliberately violated (verified
  once with a scratch edit, then reverted)
- INV-0009, DESIGN-0019, and this IMPL carry final statuses; CI fully
  green on the PR(s)

## File Changes

- **Phase 1** — new: `modules/s3/internal/core/{versions,variables,
  naming,bucket,policy,logging,outputs}.tf`, `.tflint.hcl`,
  `.terraform-docs.yml`, `README.md`, `USAGE.md`,
  `tests/{default,naming,policy,logging,validation}.tftest.hcl`
  (exact split at implementation). Modified: `justfile` (var-file path),
  `scripts/changed-modules.sh`, `scripts/changed-modules.test.sh`,
  `CLAUDE.md`.
- **Phase 2** — new: `modules/s3/access-logs-bucket/` (module files +
  `tests/` + `tests-localstack/` + FINDINGS.md). Modified: ADR-0020,
  `CLAUDE.md`, root `README.md`.
- **Phase 3** — new: `modules/s3/bucket/` (module files incl.
  remote_state.tf + `tests/` + `tests-localstack/` with
  `fixtures/access-logs/` + FINDINGS.md). Modified: ADR-0020,
  `CLAUDE.md`, root `README.md`.
- **Phase 4** — new: `modules/s3/events-bucket/` (module files incl.
  notification.tf + `tests/` + `tests-localstack/` with SQS/EventBridge
  fixtures + FINDINGS.md). Modified: `CLAUDE.md`, root `README.md`.
- **Phase 5** — modified: `scripts/static-check.sh` (guards), INV-0009,
  DESIGN-0019, this doc, doc README indexes, root `README.md`.

## Testing Plan

The four layers from DESIGN-0019's Testing Strategy, mapped to commands:

1. **Core plan suite** — `just tf test s3/internal/core`; direct
   resource assertions (the core is the root module there).
2. **Purpose-module plan suites** — `just tf test s3/<module>`; the
   shared baseline suite + ADR-0020 three-path assertions + type
   surface. These are the CI gate tier.
3. **Community apply suites** — `just tf test-localstack s3/<module>`
   against the token-free `localstack/localstack:4.4` Community image
   (OQ 5a); composing fixture for `bucket`; probes 1 and 2 with
   FINDINGS.md outcomes.
4. **Static gate** — `just static` (core auto-discovered; Phase-5 guards
   added).

Implementation notes carried from fleet experience: any apply/setup
`.tftest.hcl` referencing a Terragrunt global inside a `run` block needs
a top-level `variable {}` declaration (the shared var-file supplies
values silently otherwise); regenerate USAGE.md lock-free (delete
`.terraform.lock.hcl` first) so the static gate's deterministic
constraint form holds; tflint wants variable `nullable` after the
validation block.

## Dependencies

- DESIGN-0019 (Approved) / INV-0009 — all design decisions; nothing here
  re-litigates them.
- ADR-0020 + IMPL-0015 — key contract, six Terragrunt globals, shared
  var-file, assume_role read shape.
- ADR-0019 / IMPL-0016 — static gate + changed-modules matrix (both
  scripts modified in Phase 1/5).
- mise toolchain (terraform, tflint, terraform-docs, just); LocalStack
  Community image (no Pro token needed anywhere in this IMPL).
- Precedents: `network/vpc-lookup` (Community apply tier),
  `rds/proxy` + `rds/read-replica` (composing fixtures), IMPL-0017
  (identical-surface porting + parity notes).

## Open Questions

Option (a) is the recommendation; pick a letter or write in an
alternative.

> **Resolved 2026-08-02 (operator review):** 1 = **a**, 2 = **a**,
> 3 = **a**, 4 = **a**, 5 = **a for now** — hold the token-free 4.4
> Community pin; newer LocalStack releases have no token-free edition,
> so the tier's eventual replacement (hobby-account token or floci
> testcontainers) is deliberately punted — see the OQ-5 resolution.

### 1. What is the PR and release cadence across the five phases?

**Resolved (a).**

- a) **(Chosen)** One PR per phase, five total: `dont-release` for
  Phase 1 (CI plumbing + a non-consumable internal module — nothing for
  the live repo to pin) and Phase 5 (guards + docs), `minor` for Phases
  2, 3, 4 (each ships a consumable module, so each gets a tag the live
  repo can pin immediately). Phase success criteria map one-to-one onto
  PR gates, and probe learnings from Phase 3 land before Phase 4 opens.
- b) One PR for the whole family with per-phase commits and a single
  `minor` release at the end — the IMPL-0017 precedent, but that was
  one surface across existing modules; here it means five phases of
  review in one diff and no module is pinnable until everything lands.
- c) Two PRs: Phases 1+2 (core + producer), then 3+4+5 — fewer reviews
  than (a) while keeping the producer pinnable early.

### 2. What type does the policy-statement variable surface use?

Applies to the core's `internal_policy_statements` and the consumer
modules' `additional_policy_statements` (same type).

**Resolved (a).**

- a) **(Chosen)** A typed object list with optionals:
  `sid` (string, required — the reserved-sid validation needs it),
  `effect` (optional, default "Allow"), `principals`
  (optional map(list(string)), e.g. Service/AWS keys), `actions` +
  `resources` (list(string)), `conditions` (optional list of
  test/variable/values objects). Plan-time type checking,
  self-documenting USAGE.md, and the reserved-sid validation is a simple
  sid check — matches the fleet's typed-hybrid precedent (read-replica's
  replicas map).
- b) `list(string)` of raw JSON statement fragments merged with
  jsondecode — maximally flexible (any IAM feature ever), but no type
  safety, ugly in tfvars, and the reserved-sid check must parse JSON.
- c) `list(any)` — loose HCL, fewest keystrokes, but zero plan-time
  validation and tflint/terraform-docs render it as opaque.

### 3. How is the shared baseline test suite kept identical across modules?

**Resolved (a).**

- a) **(Chosen)** Plain per-module copies + an identity check in the
  Phase-5 static-gate guard (`diff -q` across the three
  security_baseline.tftest.hcl files; any divergence fails CI). Copies
  keep `terraform test` completely standard; the guard makes drift
  loud — the same keep-honest mechanism the fleet already trusts, now
  machine-enforced.
- b) Copies kept identical by review convention only — zero tooling, but
  the whole point of the shared suite is catching silent drift, and
  review is the thing that misses it.
- c) One canonical file symlinked into each module's tests directory —
  true single source, but git symlinks are platform-fragile and make the
  test dirs non-standard for tooling that walks them.

### 4. How are the two LocalStack fidelity probes executed?

**Resolved (a).**

- a) **(Chosen)** Manual probe first, suite second: before writing
  each apply suite's deep assertions, run a throwaway
  terraform-plus-aws-CLI session against the pinned Community image (put
  an object, wait briefly, list the sink / poll the queue), record the
  verdict in FINDINGS.md, then bake **only the assertable depth** into
  the committed suite. No flaky sleeps in CI; the suite asserts what the
  image is known to do (DESIGN-0019 OQ 6a already fixed the fallback).
- b) Write full-depth assertions in the suite first and trim on failure —
  fewer steps when the probe passes, but a failing probe means committing
  through red runs, and timing-dependent assertions risk staying flaky
  instead of being consciously excluded.

### 5. Which LocalStack image do the s3 Community apply suites pin?

**Resolved (a, held at the token-free 4.4 pin — the tier's future is
punted).** The suites pin the token-free Community
`localstack/localstack:4.4` (the vpc-lookup precedent). Operator note
recorded for later: LocalStack's newer releases no longer ship a
token-free Community edition, so this pin is a holding position, not a
destination. The eventual options are a "hobby" LocalStack account with
its own auth token (the closest equivalent of the old Community tier on
new images), or — more likely — replacing the Community-tier LocalStack
dependency outright with
[floci testcontainers for Go](https://floci.io/floci/testcontainers/go/).
That migration is fleet-wide (vpc-lookup and the EKS/EFS Community
suites ride the same tier), owns its own future INV, and is out of scope
here; nothing in this IMPL may take a dependency that assumes a token.

- a) **(Chosen, 4.4 pin held)** The token-free Community image, current 4.x at
  implementation time (the `network/vpc-lookup` precedent — its
  FINDINGS.md pins `localstack/localstack:4.4` with a minimal SERVICES
  list). Keeps the cheap tier genuinely tokenless for CI and
  contributors; the exact 4.x pin + SERVICES set
  (`s3,sts` base, plus `sqs,sns,events` for events-bucket) is recorded
  in each FINDINGS.md at probe time.
- b) Run them against the operator's LocalStack Pro container (already
  running locally for the RDS suites) — one container for everything
  locally, but it silently couples the Community tier to a Pro token and
  the parity actually exercised stops matching what CI's Community tier
  would run.

## References

- DESIGN-0019 — the design this implements (phases mirrored 1:1)
- INV-0009 — findings + resolved family layout
- ADR-0020 — remote-state key contract (s3 rows land in Phases 2-3)
- ADR-0019 / IMPL-0016 — static gate + changed-modules matrix
- IMPL-0015 — Terragrunt globals + shared var-file + assume_role reads
- IMPL-0017 — per-phase tracking style, identical-surface + parity-note
  precedents
- `network/vpc-lookup` — Community apply tier + image pin precedent
- `rds/proxy` / `rds/read-replica` — composing-fixture precedent
