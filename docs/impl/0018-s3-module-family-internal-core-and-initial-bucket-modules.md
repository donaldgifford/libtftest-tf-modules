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
- [x] 1.7 outputs.tf: `bucket_id` / `bucket_name` / `bucket_arn`,
      `bucket_policy_json`, `logging_target` + `logging_prefix`,
      attribute-derived `security_baseline` object (DESIGN-0019 shape)
- [x] 1.8 Core plan suites (`tests/`): baseline defaults, encryption
      modes (kms default / CMK / s3), naming + shard + override, policy
      sid composition via jsondecode, logging tri-state wiring + prefix
      default, validation.tftest.hcl `expect_failures` (name charset +
      bounds, composed length, kms-key-on-s3-mode, reserved sid,
      self-logging)
- [x] 1.9 changed-modules.sh: internal fan-out rule (diff under
      `modules/<service>/internal/**` adds every leaf module under
      `modules/<service>/`) + changed-modules.test.sh cases via the
      `CHANGED_FILES_OVERRIDE` seam
- [x] 1.10 CLAUDE.md: start the `modules/s3/` section (core + family
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

- [x] 2.1 Module: core call with SSE-S3 pinned
      (`encryption = { mode = "s3" }`), versioning pinned off, **no**
      access_logging surface; log-delivery grant via
      `internal_policy_statements` (`logging.s3.amazonaws.com`,
      `s3:PutObject` on `<arn>/*`, `aws:SourceAccount` condition —
      DESIGN-0019 OQ 2a); retention via `extra_lifecycle_rules`
      (`log_retention_days` default 90, null disables — OQ 1a); `name`
      defaults to `"access-logs"` (OQ 3a)
- [x] 2.2 variables.tf (name-composition globals `account_id` +
      `region`, retention, shard/name_override/force_destroy/tags
      pass-throughs) and outputs.tf (contract `bucket_name` + additive
      `bucket_arn` / `bucket_id`, `security_baseline` re-export)
- [x] 2.3 Plan suites: `security_baseline.tftest.hcl` (landed as the
      documented F3 VARIANT — AES256/no-KMS, so the byte-identical
      diff-guard pair is bucket/events-bucket), default.tftest.hcl
      (grant sid + Service principal + SourceAccount condition +
      objects-only Resource, retention wiring via the new
      `lifecycle_rule_ids` core output, composed default name
      `access-logs-<account_id>-<region>`, non-default-sink name run),
      validation.tftest.hcl (retention 0, name charset) — 6/6 green.
      Root `versions.tf` gained the aws `~> 6.2` requirement
      (tflint-ignored as unused): without it terraform test cannot bind
      the test-file provider block and every plan run fails on real
      credential resolution.
- [x] 2.4 Community apply suite (`tests-localstack/`) + FINDINGS.md
      (OQ 5a: token-free `localstack/localstack:4.4`, `SERVICES=s3,sts`)
      — real apply of the full chain (bucket/PAB/ownership/SSE/
      versioning/lifecycle/policy), no fixture (pure producer), **run
      and passing 1/1**; grant with Service principal + SourceAccount
      condition accepted verbatim; `s3_use_path_style = true` required;
      teardown clean without force_destroy
- [x] 2.5 README with the ADR-0020 producer contract section (flat
      reserved key `<account_name>/<region>/s3/access-logs/
      terraform.tfstate`, no `<name>` segment; non-default-sink =
      another live-repo folder + consumer `access_logging.target_bucket`
      override); USAGE.md already regenerated in 2.3
- [x] 2.6 ADR-0020: `s3` added to the `<shape>` list (with the flat-key
      exception), `s3/bucket` consumer row (marked Phase 3, the 13th
      read), and a "reserved stack name" section — the live-repo folder
      `s3/access-logs` IS the contract; non-default sinks opt out via
      the consumer `target_bucket` override
- [x] 2.7 CLAUDE.md (s3 bullet: Phase 2 implemented — sink posture,
      flat reserved key, F3 baseline variant, wrapper-module
      required_providers gotcha, test results); root README module
      table regen (`just readme` — both s3 modules picked up); commit

#### Success Criteria

- `just tf test s3/access-logs-bucket` and
  `just tf test-localstack s3/access-logs-bucket` green
- ADR-0020 carries the s3 producer row; `just static` green

---

### Phase 3: bucket reference consumer

The general-purpose bucket; the fleet's first count-gated remote-state
read.

#### Tasks

- [x] 3.1 Module: six Terragrunt globals; tri-state `access_logging`
      (validation: target_bucket/prefix require enabled — contradictory
      combos fail at plan, not silently ignore); count-gated read of the
      flat reserved key in main.tf with `assume_role` +
      `use_path_style = true` (rds/instance pattern); resolution via
      `one(...[*].outputs.bucket_name)` (null on both no-read paths) +
      `coalesce(override, lookup)`; all baseline pass-throughs.
      `logging_target`/`logging_prefix` re-exported as the tri-state
      test window. tflint gotcha: multi-line conditional needs
      parentheses (`terraform_conditional_parentheses`)
- [x] 3.2 `additional_policy_statements` pass-through into the core's
      `internal_policy_statements` (DESIGN-0019 OQ 4b: additive-only;
      the core's reserved-sid validation is the guard) — same typed
      object list as the core, landed with 3.1 (one module surface)
- [x] 3.3 Plan suites (9 runs green): `security_baseline.tftest.hcl` —
      the family's CANONICAL copy (events-bucket's must stay
      byte-identical for the Phase-5 diff guard); default.tftest.hcl —
      override_data stub + the ADR-0020 assertion (`config.key ==
      "sandbox/us-east-1/s3/access-logs/terraform.tfstate"`),
      `length(data...) == 0` on both no-read paths, resolved
      target/prefix per path, additive statement beside intact baseline
      sids + resource_suffixes expansion; validation.tftest.hcl
      (disabled+target, disabled+prefix, reserved sid, name charset).
      Two `terraform test` gotchas: a variable-validation failure does
      NOT short-circuit data-source evaluation (an `expect_failures`
      run on the default tri-state still attempts a real S3 read —
      disable logging in those runs), and there is no `setequal()`
      function (use `toset(a) == toset(b)`). The reserved-sid guard is
      mirrored onto the root variable because `expect_failures` cannot
      target a child module's validation.
- [x] 3.4 Community apply (3 runs, **run and passing**):
      `fixtures/access-logs` instantiates the **real**
      access-logs-bucket module + seeds the reserved-key state object
      (composing-fixture precedent; no `reference-vpc` — S3-only suite
      skips the ~1-2 min NAT). Default-lookup run resolves
      `logging_target` to the sink the fixture actually created, so the
      account-scoped + `assume_role` read is proven end to end
      (LocalStack STS mints creds for the role ARN; global
      `AWS_ENDPOINT_URL` routes both STS and S3); override run creates
      zero data-source instances on a real apply.
      **F6 probe 1 → NEGATIVE:** LocalStack 4.4 round-trips the logging
      *configuration* faithfully but never materializes delivered log
      objects (10 requests, sink empty at 60 s and ~150 s, no container
      log activity). Per DESIGN-0019 OQ 6a the suite asserts the
      config surface only — no vacuous delivery test. Recorded in
      FINDINGS.md
- [x] 3.5 README: the tri-state table, the ADR-0020 consumer contract
      (flat reserved key, count-gating, bootstrapping order), the
      additive-statements section, and the test-split table; USAGE.md
      regenerated lock-free
- [x] 3.6 ADR-0020: `s3/bucket` consumer row (flat key, count-gated) +
      a **conditional-read** subsection — the first optional read in the
      fleet; the key contract binds only the default path, and the
      pattern generalizes to any compose-by-default/override-explicitly
      consumer
- [x] 3.7 CLAUDE.md (Phase 3 implemented: tri-state, count-gated read,
      the root-mirrored reserved-sid guard, both terraform test gotchas,
      the negative F6 probe); root README regen (17 modules); commit

#### Success Criteria

- All three tri-state paths pinned green in the plan suite
- Community apply green end-to-end: reserved key seeded by the fixture,
  read back through `assume_role`, logging wired to the sink
- Probe-1 outcome recorded in FINDINGS.md either way (negative →
  config-surface depth per DESIGN-0019 OQ 6a)

---

### Phase 4: events-bucket

#### Tasks

- [x] 4.1 Module: the full `s3/bucket` surface (tri-state +
      `additional_policy_statements`) + notification.tf — the singleton
      `aws_s3_bucket_notification` in the module root, typed
      `sqs_queues` / `sns_topics` lists (id, arn, events,
      filter_prefix, filter_suffix; unique-id + non-empty-events
      validations) + `eventbridge_enabled` (OQ 5a), and the
      at-least-one-destination precondition. Four notification outputs
      (`notification_id`, `eventbridge_enabled`, and the two id=>arn
      maps) give the suites an attribute-derived window. This is the
      one purpose module whose root aws requirement is genuinely used,
      so no tflint-ignore
- [x] 4.2 Plan suites (13 runs green): `security_baseline.tftest.hcl`
      **byte-identical** to `s3/bucket`'s (verified `diff -q`) — the
      destination the precondition needs rides in the file-level
      `variables` block as `eventbridge_enabled = true`, which
      `s3/bucket` silently ignores. **Gotcha confirmed by probe:** a
      test-file `variables` block tolerates variables the module under
      test does not declare, exactly like `-var-file`; that is what
      makes byte-identity possible. Plus the three ADR-0020 tri-state
      runs, four notification-shape runs (single SQS, all three kinds
      at once, per-entry filters, EventBridge-only), and validation
      (no-destination against the resource, duplicate ids, empty event
      list, inherited guards)
- [x] 4.3 Community apply (3 runs, **run and passing**):
      `fixtures/destinations` = state bucket + the real access-logs
      sink at the reserved key + an SQS queue **with its queue policy**
      (owned by the destination stack — the fixture is the worked
      example) + an SNS topic; runs cover SQS-with-default-tri-state
      and all-three-kinds-with-logging-off.
      **F6 probe 2 → POSITIVE:** LocalStack delivers both the
      `s3:TestEvent` handshake and a full `ObjectCreated:Put` record
      within seconds. Baked depth stays the configuration surface
      anyway — `terraform test` has no way to receive an SQS message
      (no data source; the `external` provider would be a new
      dependency), so here the *harness* is the limiter, not the
      emulator (the inverse of probe 1). **Second finding:** LocalStack
      does NOT enforce the destination policy (registering a
      notification to a policy-less queue succeeds, where real S3
      returns InvalidArgument) — so the apply does not verify the
      fixture's queue policy; the README section is the contract.
      Both recorded in FINDINGS.md
- [x] 4.4 README (destinations + the singleton rationale, the
      destination-policy ownership note with the required queue-policy
      shape and the real-S3-rejects/LocalStack-doesn't caveat, test
      table; the shared surface defers to `s3/bucket`'s README);
      USAGE.md lock-free; CLAUDE.md; root README regen (18 modules);
      commit

#### Success Criteria

- `just tf test s3/events-bucket` and
  `just tf test-localstack s3/events-bucket` green
- Probe-2 outcome recorded in FINDINGS.md either way

---

### Phase 5: Guards, fleet verification, and doc closure

#### Tasks

- [x] 5.1 Static-gate guards in `scripts/static-check.sh` (new section
      5, so `just static` and the CI `static` job both carry them):
      (a) any `source = ` line under `modules/s3/` pointing at the core
      must be exactly `"../internal/core"` — a registry name or git ref
      fails; (b) `diff -q` of `events-bucket`'s
      `security_baseline.tftest.hcl` against `bucket`'s. The identity
      set is the **pair**, not three copies — `access-logs-bucket` is
      the documented F3 variant (SSE-S3, no tri-state) and is
      deliberately excluded. Both guards verified by deliberate
      violation (versioned source → caught with the offending line;
      appended comment → caught with the diff), then reverted
- [x] 5.2 Full pass from a clean tree, all in one run:
      `just static` exit 0 (18 modules, now including the two new
      guards); plan suites **47/47** — core 19, access-logs-bucket 6,
      bucket 9, events-bucket 13; Community applies **7/7** —
      access-logs-bucket 1, bucket 3, events-bucket 3
- [x] 5.3 Fidelity greps clean: all six `terraform.tfstate` key
      literals under `modules/s3/` are account-scoped
      (`${var.account_name}/…` in module + fixture code,
      `sandbox/…` in the two plan assertions) with zero un-prefixed
      keys; the reserved-key literal is consistent across module code,
      tests, fixtures, READMEs, ADR-0020, DESIGN-0019 and INV-0009; all
      three core consumers use `source = "../internal/core"` verbatim
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
