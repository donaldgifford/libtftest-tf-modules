---
id: IMPL-0019
title: "Secrets Manager secret producer module"
status: Draft
author: Donald Gifford
created: 2026-08-11
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0019: Secrets Manager secret producer module

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-08-11

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Module core and plan suite](#phase-1-module-core-and-plan-suite)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Cross-account surface and contract docs](#phase-2-cross-account-surface-and-contract-docs)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: LocalStack Community apply suite](#phase-3-localstack-community-apply-suite)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Contract and doc closure](#phase-4-contract-and-doc-closure)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. What is the PR and release cadence?](#1-what-is-the-pr-and-release-cadence)
  - [2. Does the apply suite prove rotation live?](#2-does-the-apply-suite-prove-rotation-live)
  - [3. When is the consumer side of the pointer contract proven?](#3-when-is-the-consumer-side-of-the-pointer-contract-proven)
  - [4. Does the no-leak invariant get a static guard?](#4-does-the-no-leak-invariant-get-a-static-guard)
- [References](#references)
<!--toc:end-->

## Objective

Build `modules/secretsmanager/secret` — the fleet's Secrets Manager
secret producer, whose generated value (bare password or RDS-format
DB-credentials JSON) never exists in Terraform state, plan output, or
code — exactly as designed, including its plan gate, Community apply
proof, and the ADR-0020 `secrets` shape reservation.

**Implements:** DESIGN-0020 (Approved; all six OQs resolved — 1a,
2 Other [managed key default / BYO override / null output for managed],
3a [+ raw `policy_json` deferred], 4a, 5a, 6a), from INV-0010
resolution 1b (producer first; the RDS reference mode is the follow-up
tracked in DESIGN-0020's Follow-up section, **not** this doc).

## Scope

### In Scope

- The new module: secret + ephemeral generation + write-only version,
  validations, pointer-only outputs, `read_principals` resource policy.
- The fleet's first `required_version = ">= 1.11"` floor (write-only
  arguments).
- Plan suite (the gate) including the permanent no-leak assertion;
  Community LocalStack apply suite + FINDINGS.md.
- ADR-0020 `secrets` shape row; module README "Remote-state key
  contract" section; CLAUDE.md + INV-0010 closure notes.

### Out of Scope

- The RDS module changes (reference mode, proxy output continuity,
  RDS `required_version` raise) — DESIGN-0020 Follow-up items 1–3.
- Rotation Lambda, multi-region replicas, BYO-caller-value via
  ephemeral variables, raw `policy_json` passthrough — all explicitly
  deferred (DESIGN-0020 Follow-up item 4).
- Any change to the three RDS modules' existing managed-secret default
  or IMPL-0017 rotation surface.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its
tasks are checked off and its success criteria are met.

---

### Phase 1: Module core and plan suite

The module itself and its offline gate. Every resolved DESIGN-0020
decision this phase encodes is cited inline so review needs no
cross-referencing.

#### Tasks

- [ ] 1.1 Scaffold `modules/secretsmanager/secret`: `versions.tf` with
      `required_version = ">= 1.11"` + a why-comment (write-only
      arguments — the fleet's first 1.11 floor; do not "simplify" it
      down), aws `~> 6.2`, random `~> 3.7`; `.tflint.hcl` (ruleset-aws
      0.48.0) + `.terraform-docs.yml` copied from `network/vpc-lookup`;
      README skeleton carrying the two standing constraints up front
      (test suites must use the real-provider-fake-creds pattern —
      `mock_provider` rejects ephemeral types, INV-0010 F3.1; outputs
      are pointer-only, never the value, F7)
- [ ] 1.2 `variables.tf`: `name` (charset validation, fleet norm),
      `username` (nullable string — the OQ 1a shape switch),
      `secret_string_version` (number, default 1, validation `>= 1`),
      `password_length` (default 32, validation `>= 16`) +
      `password_override_special` (default `"!#$%&*()-_=+[]{}<>:?"`,
      the RDS-legal set — OQ 5a), `secret_recovery_window_days`
      (default 30, validation `0 or 7–30` — OQ/resolution 5a),
      `kms_key_arn` (nullable, default null → AWS-managed
      `aws/secretsmanager` key — OQ 2 resolution), `description`,
      `tags`; attribute order per the tflint terraform-style rule
      (nullable last)
- [ ] 1.3 `main.tf`: `aws_secretsmanager_secret` (`name_prefix =
      "${var.name}-"` — resolution 5a name-reuse rationale in a
      comment, `recovery_window_in_days`, `kms_key_id =
      var.kms_key_arn`, description, tags);
      `ephemeral "random_password"` (length / special /
      override_special); `aws_secretsmanager_secret_version` with
      `secret_string_wo` (username set → `jsonencode({username,
      password})`, null → bare result — OQ 1a) and
      `secret_string_wo_version = var.secret_string_version`; comment
      marking the ephemeral-reference invariant (nothing else may read
      `ephemeral.random_password.this.result`)
- [ ] 1.4 `outputs.tf`: the pointer-only contract set exactly —
      `secret_arn`, `secret_id`, `secret_name`, `kms_key_arn`
      (passthrough; null ⇒ managed key ⇒ proxy wildcard path),
      `secret_string_version`, `username`
- [ ] 1.5 Plan suite `tests/` (real-provider-fake-creds header comment
      explaining why no `mock_provider` — F3.1): `default.tftest.hcl`
      (both content shapes planned; the **no-leak gate**:
      `secret_string_wo == null` AND `secret_string_wo_version ==
      var.secret_string_version` in a passing plan; `name_prefix`
      composition; kms passthrough null + BYO; tags),
      `validations.tftest.hcl` (`expect_failures`: name charset,
      recovery window 1–6 rejected + 0 accepted, `secret_string_version
      = 0` rejected, `password_length < 16` rejected),
      `outputs_contract.tftest.hcl` (the output set pinned by name)
- [ ] 1.6 Verify CI pickup: `just changed` with a seeded diff under
      `modules/secretsmanager/secret/` lists the module at the plan
      tier (leaf-module auto-discovery, no script changes expected)
- [ ] 1.7 `just tf docs secretsmanager/secret` (USAGE.md), `just tf
      fmt|lint|validate|test`; CLAUDE.md: start the
      `modules/secretsmanager/` section (posture, 1.11 floor,
      mock_provider constraint); conventional commit

#### Success Criteria

- `just tf validate|fmt|lint|test secretsmanager/secret` all green
- The no-leak assertion passes and is present verbatim in the suite
- `just changed` (seeded) lists the module; `just static` green
  repo-wide

---

### Phase 2: Cross-account surface and contract docs

The `read_principals` policy and the README contract surface — the
consumer-facing halves that don't need a live apply.

#### Tasks

- [ ] 2.1 `policy.tf`: `aws_secretsmanager_secret_policy` count-gated
      on `length(var.read_principals) > 0`, composing the
      `GetSecretValue` + `DescribeSecret` grant to exactly those
      principals via `aws_iam_policy_document`; `read_principals`
      variable (list(string), default `[]`) with validation rejecting
      `"*"` and non-ARN entries (OQ 3a; raw `policy_json` stays
      deferred — comment points at DESIGN-0020 Follow-up 4)
- [ ] 2.2 README: "Remote-state key contract" section (`secrets` shape
      `<account_name>/<region>/secrets/<name>/terraform.tfstate`,
      triple-coupling, pointer-only rule, SM-secret-name ≠ state-key
      `<name>` note); caveats block (CMK needed for cross-account —
      managed key cannot do it; CMK key-policy grant is out of module
      scope; rotation does **not** auto-propagate to referencing
      consumers — INV-0010 F4); replicas + BYO-value deferral notes
      (OQ 4a / OQ 1a)
- [ ] 2.3 Plan suite additions: `policy.tftest.hcl` — no policy
      resource at `[]` (count 0), grant shape via `jsondecode` for a
      two-principal case, `expect_failures` for `"*"` and a non-ARN
      string
- [ ] 2.4 `just tf docs` regen; fmt/lint/test; conventional commit

#### Success Criteria

- Plan suite green including the policy shapes; `just static` green
- README carries the key contract + all three caveats

---

### Phase 3: LocalStack Community apply suite

The live proof. Secrets Manager is Community-tier: token-free
`localstack/localstack:4.4`, `SERVICES=secretsmanager,sts`, no Pro, no
named volume.

#### Tasks

- [ ] 3.1 `tests-localstack/apply.tftest.hcl`: apply with
      `secret_recovery_window_days = 0` (real teardown); metadata-only
      assertions per OQ 6a — outputs are real ARNs (`secret_arn`
      matches the SM ARN shape and embeds the suffixed name), the
      version-listing data source shows a current (`AWSCURRENT`)
      version, `kms_key_arn` output null on the managed-key path; no
      value read anywhere
- [ ] 3.2 Rotation run per IMPL OQ 2 resolution (if 2a: a second run
      block bumping `secret_string_version` to 2, asserting the
      AWSCURRENT version id **changed** via the version-listing data
      source — still metadata-only; if 2b: record the deferral in
      FINDINGS.md instead)
- [ ] 3.3 `tests-localstack/FINDINGS.md`: parity notes — whether
      LocalStack emulates recovery-window name-reuse blocking (probe
      once, record outcome), anything the rotation run surfaces, the
      `SERVICES` line and the no-token reminder
- [ ] 3.4 Run live: `just tf test-localstack secretsmanager/secret`
      against a running Community 4.4 container — suite passing;
      `just changed` (seeded) now shows the module in the community
      tier
- [ ] 3.5 Conventional commit

#### Success Criteria

- Apply suite passing against live LocalStack Community 4.4
- FINDINGS.md records the name-reuse probe outcome
- `just changed` shows plan + community tiers for the module

---

### Phase 4: Contract and doc closure

The fleet-level bookkeeping that makes the RDS follow-up start from
zero re-derivation.

#### Tasks

- [ ] 4.1 ADR-0020: add the `secrets` shape row (producer =
      `secretsmanager/secret`) + a reserved consumer-row placeholder
      naming the RDS reference mode as the intended first consumer
- [ ] 4.2 CLAUDE.md: complete the `modules/secretsmanager/` section
      (module posture, resolved decisions incl. the KMS
      default/override/null-output semantics, test-tier layout, the
      1.11 floor, the mock_provider constraint, deferral list)
- [ ] 4.3 INV-0010: append a note that the producer half of resolution
      1b is delivered (pointer to DESIGN-0020 + the module path)
- [ ] 4.4 `docz update` for indexes; restore the known TOC mangling
      (impl/0009, impl/0017, inv/0008 — and check inv/0010 / adr/0020)
- [ ] 4.5 Final gates: `just static`, full plan matrix locally
      (`just tf test secretsmanager/secret`), `just docs lint` on
      touched docs; PR per IMPL OQ 1 resolution, labeled `minor` (new
      module); DESIGN-0020 status → Implemented and this doc →
      Completed on merge

#### Success Criteria

- CI green: static + plan (+ community tier if
  `CI_RUN_LOCALSTACK_APPLY` is enabled); `ci-gate` passes
- ADR-0020 and the module README agree on the key shape verbatim
- CLAUDE.md reflects the Follow-up section as the next piece of work

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/secretsmanager/secret/versions.tf` | Create | First `>= 1.11` floor; aws `~> 6.2`, random `~> 3.7` |
| `modules/secretsmanager/secret/variables.tf` | Create | Resolved surface (OQ 1a/2/3a/5a shapes) |
| `modules/secretsmanager/secret/main.tf` | Create | Secret + ephemeral + write-only version |
| `modules/secretsmanager/secret/policy.tf` | Create | Count-gated `read_principals` resource policy |
| `modules/secretsmanager/secret/outputs.tf` | Create | Pointer-only contract set |
| `modules/secretsmanager/secret/{.tflint.hcl,.terraform-docs.yml,README.md,USAGE.md}` | Create | Standard module chrome + contract/caveats README |
| `modules/secretsmanager/secret/tests/*.tftest.hcl` | Create | Plan gate incl. the no-leak assertion |
| `modules/secretsmanager/secret/tests-localstack/{apply.tftest.hcl,FINDINGS.md}` | Create | Community apply proof + parity notes |
| `docs/adr/0020-*.md` | Modify | `secrets` shape row + reserved consumer row |
| `CLAUDE.md` | Modify | `modules/secretsmanager/` section |
| `docs/investigation/0010-*.md` | Modify | Producer-half-delivered note |
| `docs/design/0020-*.md` | Modify | Status → Implemented at closure |

## Testing Plan

- Plan suite (the gate, offline, real-provider-fake-creds):
  default shapes ×2 content modes, no-leak gate, kms null/BYO,
  validations (name, recovery window, version, length, principals),
  policy on/off + grant shape, output-contract pin — target ~12–15
  runs across 4 files.
- Community apply (opt-in, live LocalStack 4.4,
  `SERVICES=secretsmanager,sts`): metadata-only apply proof + rotation
  run per OQ 2 — 1–2 runs.
- No Pro tier. No `mock_provider` anywhere in this module (INV-0010
  F3.1) — enforced by comment + review, and by OQ 4's resolution if a
  guard is chosen.

## Dependencies

- PR #94 (INV-0010 + DESIGN-0020, both resolved) merged to main —
  this work branches from it.
- Terraform ≥ 1.11 locally/CI: satisfied (mise pin 1.15.8).
- aws provider `~> 6.2` (resolves ≥ 6.58.0, all `_wo` surfaces
  verified) and random `~> 3.7` (in-fleet precedent) — no pins change.
- A running token-free `localstack/localstack:4.4` container for
  Phase 3 (Community; no auth token — per the standing fleet rule).

## Open Questions

### 1. What is the PR and release cadence?

- **a. (Recommended)** One PR spanning all four phases, labeled
  `minor` (one new module, no existing module touched except docs;
  the four phases are a working order, not shippable increments —
  unlike IMPL-0018, where five phases spanned four modules and
  per-phase PRs paid for themselves). Commit-per-task keeps review
  navigable.
- b. Stacked per-phase PRs (IMPL-0018 OQ 1 precedent). Maximum
  isolation, but three of the four PRs would be unreleasable on their
  own (`dont-release` + rebase overhead) for a single-module effort.
- c. Two PRs: module + tests (Phases 1–3, `minor`), then contract/doc
  closure (Phase 4, `dont-release`). Cleaner docs diff, but the
  ADR/CLAUDE closure landing separately from the module briefly leaves
  the contract undocumented on main.
- Other: (your call)

### 2. Does the apply suite prove rotation live?

- **a. (Recommended)** Yes — a second run block bumps
  `secret_string_version` 1 → 2 and asserts the `AWSCURRENT` version
  id changed via the version-listing data source. Still metadata-only
  (no value read, OQ 6a intact), one extra apply against LocalStack,
  and it turns the F4 version-gate story from "documented" into
  "continuously proven" — the mechanism the RDS follow-up will lean
  on.
- b. No — plan-tier version assertions only; record in FINDINGS.md
  that live rotation is deferred to the RDS follow-up's fixture.
  Slightly faster suite, one less moving part.
- Other: (your call)

### 3. When is the consumer side of the pointer contract proven?

- **a. (Recommended)** With the RDS reference mode (the DESIGN-0020
  follow-up): its serverless Community apply will instantiate this
  module as its fixture and read the pointer through a real
  remote-state object — the `vpc-lookup` / `read-replica` precedent
  (producer ships first; the first real consumer proves the contract).
  This module's apply suite asserts the outputs only.
- b. Now — add a fixture that writes this module's outputs to an
  account-scoped state object in LocalStack S3 plus a stub consumer
  read in the apply suite. Front-loads contract proof, but duplicates
  exactly what the RDS fixture will do weeks later and adds an S3
  dependency to an otherwise SM-only suite.
- Other: (your call)

### 4. Does the no-leak invariant get a static guard?

- **a. (Recommended)** Not in v1. Terraform itself enforces the hard
  half (write-only arguments cannot persist; no readable
  `secret_string` attribute exists when only `_wo` is used), the plan
  suite's `secret_string_wo == null` assertion is the mechanical
  backstop, and the README + inline comment carry the review
  invariant. `static-check.sh` guards are reserved for cross-file
  invariants no tool can see (the s3 core-source rule); this one has
  tool coverage.
- b. Add a `static-check.sh` grep: `ephemeral.random_password` may be
  referenced only inside `main.tf`'s secret-version resource, and
  never in `outputs.tf`. Cheap insurance against a future editor
  wiring the value into an output — at the cost of another bespoke
  grep to maintain.
- Other: (your call)

## References

- **DESIGN-0020** — Secrets Manager secret producer module
  (`docs/design/0020-secrets-manager-secret-producer-module.md`) —
  Approved; the resolved decisions this doc implements, and the
  Follow-up section holding the RDS reference-mode thread.
- **INV-0010** — RDS master password via customer-managed Secrets
  Manager secrets — the F2/F3 probe evidence (provider surfaces,
  mock_provider incompatibility, local-ephemeral plan-testability) and
  resolutions 1b/3a/4a/5a/6a.
- ADR-0020 — remote-state key contract (gains the `secrets` shape in
  Phase 4).
- IMPL-0018 — the prior multi-phase module implementation whose task
  granularity and PR-cadence trade-offs OQ 1 references.
- `network/vpc-lookup` — producer-precedent for contract-first
  shipping (OQ 3).
- `test/fixtures/terragrunt-inputs.tfvars` — shared globals; the plan
  suites need no per-suite edits (the var-file supplies unused globals
  silently).
