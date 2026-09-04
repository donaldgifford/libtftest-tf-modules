---
id: IMPL-0022
title: "Generic IAM role module"
status: Draft
author: Donald Gifford
created: 2026-09-04
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0022: Generic IAM role module

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-09-04

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Module core and plan suite](#phase-1-module-core-and-plan-suite)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: README](#phase-2-readme)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Community apply](#phase-3-community-apply)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Closure](#phase-4-closure)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. Do inline policy documents get plan-time JSON validation?](#1-do-inline-policy-documents-get-plan-time-json-validation)
  - [2. Are duplicate trust entries rejected?](#2-are-duplicate-trust-entries-rejected)
- [References](#references)
<!--toc:end-->

## Objective

Implement DESIGN-0025: `modules/iam/role` — one generic
trust-boundary role module (replacing the queued `iam/deploy-role` +
`iam/cross-account-role` pair) whose inputs define what it does. A
typed, fail-closed trust surface (exact principal ARNs, wildcards
rejected), the fleet's three-channel policy surface mirrored from
`eks/pod-identity-access`, pointer-only outputs at the
platform-reserved ADR-0020 `iam/<name>` shape, and a
brownfield-first adoption runbook — the module receives what the hub
buildout creates manually (the INV-0011 cleanly-importable tier).

**Implements:** DESIGN-0025 (all four OQs resolved 2026-08-29 — 1a
[ARN-only typed trust, no JSON channel], 2a [no trust conditions in
v1; recorded follow-up for `external_id`], 3a [pod-identity-access
policy channels; recorded follow-up for policy creation], 4a
[adoption is live-repo work; this repo ships the runbook + probe]).

## Scope

### In Scope

- `modules/iam/role` (NEW, and the NEW `iam/` service directory):
  role + trust composition + policy channels + validations, plan
  suite, Community apply + FINDINGS.md.
- README: both platform §4 worked examples (deploy role,
  `sse-platform-access`), the adoption runbook, the key contract
  section, the path/two-spellings notes.
- ADR-0020 `iam` producer row; CLAUDE.md `iam/` section; INV-0011
  delivery note; minor release.

### Out of Scope

The design's Non-Goals plus the recorded follow-ups:

- Service-principal trust (EC2/Lambda/EKS-pods) — resource-owning
  modules mint their own service roles.
- Standalone policy creation (`aws_iam_policy`) — the future
  `iam/policy` sibling; v1 attaches existing ARNs and writes inline
  documents only (Follow-up 2 fires its own DESIGN when picked up).
- Trust conditions / `external_id` — Follow-up 1, additive, expected
  sooner rather than later but not v1.
- SSO permission sets, OIDC/SAML providers, instance profiles.
- The pod-identity role path (`eks/pod-identity-access` owns it).
- Actually importing the live deploy roles — live-repo work against
  live state (OQ 4a); this repo ships module + runbook.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all
its tasks are checked off and its success criteria are met.

---

### Phase 1: Module core and plan suite

The whole resource surface is small — one role, two attachment
`for_each`es, one inline `for_each`, one locally-evaluated policy
document — so the phase's weight is in the validations and their
verification.

#### Tasks

- [ ] 1.1 Scaffold `modules/iam/role` per the design's layout
      (`main.tf`, `trust.tf`, `variables.tf`, `outputs.tf`,
      `versions.tf`, `.tflint.hcl`, README/USAGE stubs, `tests/`,
      `tests-localstack/`). `versions.tf`: aws `~> 6.2`,
      `required_version = ">= 1.1"` — every validation here is
      single-variable, so the fleet floor holds (no cross-variable
      needs; contrast IMPL-0023 OQ 1). Producer-only: no
      remote-state read, none of the six Terragrunt globals
      (IMPL-0015 Q6a — Terragrunt's pass-every-input injects them
      harmlessly).
- [ ] 1.2 `variables.tf`: `name` (exact — no prefix; the by-name
      contract in the description since every ADR-0020
      `assume_role` block composes this role's ARN from
      `deploy_role_name`; IAM charset + length ≤ 64 validation),
      `trusted_role_arns` (non-empty; per-entry exact
      `arn:aws:iam::<12-digit>:(role|user)/...` regex; wildcard
      characters rejected; duplicates per OQ 2; the
      **path-bearing-ARN requirement** in the description — a
      stripped spelling of a path-bearing role fails at apply, per
      the design's path note), `description`, `path` (default
      `"/"`, description carrying the two-spellings caveat and the
      keep-`/`-for-access-entries guidance), `max_session_duration`
      (default 3600, validated 3600–43200), `permissions_boundary`
      (null default), the three policy channels
      (`managed_policy_arns`, `customer_managed_policy_arns`,
      `inline_policies` map of JSON — verbatim shape from
      `eks/pod-identity-access`; validation per OQ 1), `tags`.
- [ ] 1.3 `trust.tf`: `data.aws_iam_policy_document.trust` — one
      `Allow` statement, `actions = ["sts:AssumeRole"]`,
      `principals { type = "AWS", identifiers =
      var.trusted_role_arns }`. Locally evaluated, so the composed
      `assume_role_policy` is plan-known (the plan-knowability
      discipline). Single-statement composition left so Follow-up
      1's conditions block slots in without reshaping the variable.
- [ ] 1.4 `main.tf`: `aws_iam_role.this` (name, path, description,
      trust JSON, session duration, boundary, tags) + two
      `aws_iam_role_policy_attachment` `for_each`es (managed /
      customer-managed channels kept as separate variables so plans
      distinguish AWS-owned from caller-owned at a glance) +
      `aws_iam_role_policy` `for_each` over `inline_policies`.
- [ ] 1.5 `outputs.tf`: `role_arn`, `role_name`, `role_unique_id` —
      pointer-only; no policy echo, no credential-adjacent values.
- [ ] 1.6 Plan suite (`tests/`, real-provider-fake-creds — the data
      source needs no API call): a **deploy-shaped** run and a
      **platform-access-shaped** run pinning the composed trust
      JSON via `jsondecode(aws_iam_role.this.assume_role_policy)`
      (principal set, single statement, action); attachment +
      inline `for_each` addresses stable under map edits; the
      `expect_failures` set — empty trust list, wildcard ARN,
      malformed ARN, service principal passed as an ARN, bad
      session duration, bad name charset, plus the OQ-dependent
      duplicate-entry and malformed-JSON rejections; boundary +
      tags passthrough.
- [ ] 1.7 Per-rule verification of every `expect_failures` run
      (message-probe or mutation, per the CLAUDE.md recipe) — the
      design flags this explicitly: six-plus rules stack on two
      variables, and a passing run proves only that the variable
      errored.
- [ ] 1.8 `just tf all iam/role`; conventional commit.

#### Success Criteria

- Both §4 shapes plan green with the trust JSON pinned by content,
  not by reference.
- Every fail-closed rule proven to fail on its own rule.
- `just static` green (fmt / validate / tflint / docs) with the new
  module included.

---

### Phase 2: README

The README is half the deliverable here — the module's job is
adoption, and the runbook is what the live repo executes.

#### Tasks

- [ ] 2.1 The two platform §4 worked examples as full call sites:
      the **deploy role** (`name` = the fleet's `deploy_role_name`
      value; `trusted_role_arns` = the hub automation principals —
      the same stable-creator principal DESIGN-0024 OQ 4 sanctions;
      policy = the account's deploy policy ARN, content the
      caller's) and **`sse-platform-access`** (trusted by the hub
      argocd-deployer pod-identity role; a scoped inline EKS-access
      document; the cross-reference to DESIGN-0024 — the
      cluster-side half is an `eks/access-entries` entry).
- [ ] 2.2 "Adopting an existing role": `import` blocks targeting
      the module's addresses (role by name, each attachment by
      `<role-name>/<policy-arn>`, each inline policy by
      `<role-name>:<policy-name>`); **match reality first, converge
      second** — mirror the live role verbatim, import, verify the
      zero-diff plan, then converge conventions in later reviewed
      plans; trust diffs converge in place (no replacement, no
      downtime).
- [ ] 2.3 The remote-state key contract section: the
      platform-reserved `<account_name>/<region>/iam/<name>` shape,
      the triple coupling, and the reserved-ahead-of-consumers note
      (the `secrets` precedent). Both path notes land here: trust
      entries must be the real path-bearing ARNs, and roles
      destined for an access-entries binding should keep
      `path = "/"` until IMPL-0020 task 5.4's live runs answer how
      the EKS API canonicalizes path-bearing principals.
- [ ] 2.4 `just tf docs iam/role` (USAGE.md regen, lock-free
      constraint form); conventional commit.

#### Success Criteria

- Both worked examples are complete, copy-pasteable call sites.
- The runbook names every import address shape.
- `just static` green (stale-USAGE check included).

---

### Phase 3: Community apply

Pure IAM API — token-free Community, no Pro, no named volume.

#### Tasks

- [ ] 3.1 `tests-localstack/` suite (token-free
      `localstack/localstack:4.4`, `SERVICES=iam,sts`): apply a
      platform-access-shaped instance; assert the IAM surface live
      — `get-role` round-trip (name, path, trust JSON), both
      attachment channels listed, inline documents round-tripping.
- [ ] 3.2 FINDINGS.md **leads with the caveat**: LocalStack STS
      `AssumeRole` proves nothing about trust policies — it mints
      creds for any role ARN (the IMPL-0015 Phase 1 finding) — so
      the apply asserts the IAM surface, never "assumability."
- [ ] 3.3 The OQ 4a import-feasibility probe: a fixture-created
      role + an `import` block through the module's address, as a
      **recorded stretch, not a gate** — either outcome (works /
      `terraform test` can't) lands in FINDINGS as evidence for the
      runbook.
- [ ] 3.4 Run live (`just tf test-localstack iam/role`); record the
      pass + LocalStack version in FINDINGS.md.
- [ ] 3.5 Conventional commit.

#### Success Criteria

- Live Community apply green; FINDINGS.md carries the
  trust-enforcement caveat, the import-probe outcome, and the
  emulator version.

---

### Phase 4: Closure

#### Tasks

- [ ] 4.1 ADR-0020: the `iam` producer row
      (`<account_name>/<region>/iam/<name>/terraform.tfstate`) —
      reserving the shape ahead of its first TF consumer, the way
      `secrets` was reserved.
- [ ] 4.2 CLAUDE.md: the new `modules/iam/` section (module summary,
      the two follow-ups, the STS caveat); INV-0011 delivery note
      (the 2026-08-28 queue revision's condensed pair, delivered).
- [ ] 4.3 `just readme` — the module table gains the `iam/role` row
      (the separate `readme-check` CI job, not covered by `just
      static`).
- [ ] 4.4 `docz update` + the mangle-set restore; `just docs lint`.
- [ ] 4.5 PR labeled `minor`; `### RELEASE NOTES` names the new
      module and the adoption runbook.

#### Success Criteria

- ADR-0020 row present; CLAUDE.md + module table current; all doc
  gates green; release tagged.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/iam/role/{main,trust,variables,outputs,versions}.tf` | Create | the module |
| `modules/iam/role/{.tflint.hcl,README.md,USAGE.md}` | Create | lint config + docs |
| `modules/iam/role/tests/` | Create | plan suite (the gate) |
| `modules/iam/role/tests-localstack/` | Create | Community apply + FINDINGS.md |
| `docs/adr/0020-*.md` | Modify | `iam` producer row |
| `CLAUDE.md` | Modify | `iam/` section |
| `docs/investigation/` (INV-0011) | Modify | delivery note |

## Testing Plan

The design's Testing Strategy is the authority. Fleet mechanics:

- Plan suite: real-provider-fake-creds (no `mock_provider` needed —
  the policy-document data source evaluates locally).
- Per-rule `expect_failures` verification carried as task 1.7 —
  never trust a green rejection run without proving which rule
  fired.
- Community apply on token-free 4.4, `SERVICES=iam,sts`; the
  STS-proves-nothing caveat is FINDINGS.md's first line.
- New module → `scripts/changed-modules.sh` picks it up
  automatically; verify with `just changed`.

## Dependencies

- None — producer-only (no remote-state reads, no fixture
  dependencies), so this IMPL is orderable freely against
  IMPL-0021 and IMPL-0023.
- The hub buildout does **not** wait on it: roles are built
  manually now and adopted later via the Phase 2 runbook (the
  INV-0011 sequencing tier this module was designed for).
- IMPL-0020 task 5.4 (deferred live Pro applies) answers the EKS
  path-canonicalization question the Phase 2 README note cites —
  not blocking, the note ships with the open question named.

## Open Questions

### 1. Do inline policy documents get plan-time JSON validation?

DESIGN-0025 OQ 3a says mirror `eks/pod-identity-access` **verbatim**
— and the verbatim surface has no validation on `inline_policies`
values (verified in the shipped module): malformed JSON fails at
apply with IAM's `MalformedPolicyDocument`, not at plan.

- **a. (Recommended)** Keep the surface **shape** verbatim (same
  names, types, defaults) but add a per-value
  `can(jsondecode(v))` validation. Zero surface change — every
  document that was legal before still is — and it moves a
  guaranteed apply-time failure to plan, consistent with the
  fleet's fail-closed doctrine. Record a follow-up to backport the
  identical validation to `eks/pod-identity-access` so the mirror
  stays honest in both directions (a one-validation patch release
  there, whenever convenient).
- b. Byte-for-byte verbatim, no validation — the strictest reading
  of OQ 3a; the two modules stay identical today at the cost of
  apply-time discovery, and the divergence question just moves to
  whichever module gains the validation first.
- Other: (your call)

### 2. Are duplicate trust entries rejected?

`trusted_role_arns` is a list; nothing in the design's validation
set addresses the same ARN appearing twice. IAM itself dedupes
principals at policy save, so duplicates change no behavior —
this is purely an audit-surface hygiene call.

- **a. (Recommended)** Reject at validation
  (`length(var.trusted_role_arns) ==
  length(distinct(var.trusted_role_arns))`). The trust list is an
  audit surface — reviewers count principals — and a duplicate is
  copy-paste noise that misstates the count. One line, consistent
  with `eks/access-entries` rejecting duplicate principals (higher
  stakes there — duplicates silently widened access — but the same
  posture: the input states intent exactly once).
- b. Allow silently — IAM dedupes, so no behavioral risk; saves a
  validation on a surface that already carries several.
- Other: (your call)

## References

- **DESIGN-0025** — the parent design (all OQs resolved; the
  2026-09-01 amendments: the path/two-spellings note, the
  verification-discipline requirement; the two recorded
  follow-ups).
- **INV-0011** — the 2026-08-28 queue revision condensing the IAM
  pair; the sequencing note's cleanly-importable tier; F1 (the
  platform §4 distillation).
- **DESIGN-0004 / IMPL-0004** — `eks/pod-identity-access`: the
  policy-channel surface mirrored here (OQ 1 decides how exactly).
- **DESIGN-0024 / IMPL-0020** — the access-entries module (the
  cluster-side half of the platform-access pattern); task 5.4's
  open path-canonicalization question; the per-rule verification
  recipe.
- **ADR-0020** — the key contract; gains the `iam` producer row.
- **IMPL-0015** — Q6a (producer modules and the globals); the
  Phase 1 LocalStack STS finding.
- **INV-0004** — the brownfield import-first doctrine the runbook
  implements.
