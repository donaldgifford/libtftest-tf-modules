---
id: IMPL-0024
title: "IAM trust conditions and pod-identity-access validation backport"
status: Draft
author: Donald Gifford
created: 2026-09-09
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0024: IAM trust conditions and pod-identity-access validation backport

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-09-09

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Trust conditions on iam/role](#phase-1-trust-conditions-on-iamrole)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: The pod-identity-access backport](#phase-2-the-pod-identity-access-backport)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Live coverage and closure](#phase-3-live-coverage-and-closure)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Objective

Implement DESIGN-0027: the typed trust-conditions surface on
`modules/iam/role` (`require_org_ids` / `external_id`), the four
policy-channel validations backported to
`modules/eks/pod-identity-access`, and the `create_role = false`
coherence gap found while reading that module — which task 2.4's
evidence turned from a guard into a documentation fix (Part C
withdrawn).

The trust-conditions half is the **prerequisite** the IMPL-0022
security review attached to `iam/role`'s cross-account instances: the
module's apply-time backstop does not exist cross-account, so a typo'd
ARN leaves a dangling principal, and `aws:PrincipalOrgID` is the
control that survives it.

## Scope

### In Scope

- `iam/role`: `require_org_ids` (a **list** — the fleet spans several
  organizations) + `external_id`, composed into the **existing single
  trust statement**, with the zero-diff invariant pinned by a test.
- `eks/pod-identity-access`: validations on `permissions_boundary`,
  `managed_policy_arns`, `customer_managed_policy_arns`,
  `inline_policies`. **Not** a precondition on the
  `create_role = false` policy discard — Part C was withdrawn after
  task 2.4; the discard is documented instead.
- Plan-suite runs for every new rule, each verified against the rule
  it names.
- A conditions run in `iam/role`'s Community apply suite, read back
  through the existing verify fixture.
- README / USAGE / CLAUDE.md / DESIGN-0025 follow-up updates.

### Out of Scope

- A generic conditions escape hatch (DESIGN-0027 Non-Goal — it is the
  raw-JSON trust channel by another name).
- Conditions on `eks/pod-identity-access` (fixed service principal;
  no caller-supplied principal surface).
- Policy *creation* / the `iam/policy` sibling (DESIGN-0025
  Follow-up 2, still deferred).
- Making conditions mandatory on any instance.
- The live-repo adoption of either module.

---

## Implementation Phases

### Phase 1: Trust conditions on iam/role

#### Tasks

- [x] 1.1 `variables.tf`: `require_org_ids` (`list(string)`, `[]`
      default, `nullable = false`; per-entry `^o-[a-z0-9]{10,32}$`
      and a no-duplicates rule, each its own block) and `external_id`
      (null default, 2–1224 chars, `[\w+=,.@:\/-]*`). Descriptions
      carry the honest scope — org id mitigates a dangling principal
      in an account *outside* the org and does nothing for a typo
      inside it.
- [x] 1.2 `locals.tf` (new): `trust_conditions`, the compact list built
      from the two inputs so an unset one contributes no block.
- [x] 1.3 `trust.tf`: `dynamic "condition"` inside the **existing**
      statement. Comment states all three IAM combining rules —
      values OR inside a condition, conditions AND inside a
      statement, statements OR inside a document — because the middle
      one is the invariant and the other two are what make it
      counterintuitive.
- [x] 1.4 **Probe before asserting**: render the document with one org
      id, two org ids, and both conditions, and read the JSON.
      `aws_iam_policy_document` collapses single-element sets (the
      IMPL-0022 finding on `Principal.AWS`); condition `values` are a
      set, so confirm the one-vs-two shape before writing any
      assertion. With the list resolution this is no longer a
      nicety — a one-org assertion would silently prove nothing about
      the multi-org case the surface exists for.
- [x] 1.5 `tests/trust_conditions.tftest.hcl` (new): the zero-diff run
      (**no `Condition` key at all**, not an empty map), one org id,
      **two** org ids, external-id alone, and both-together asserting
      **one** statement with **two** conditions.
- [x] 1.6 Five rejection runs (malformed org id, empty-string org id,
      duplicate org id, out-of-range external id, bad-charset
      external id), each message-probed — three rules now sit on
      `require_org_ids` alone and `expect_failures` proves only that
      the variable errored.
- [x] 1.7 `just tf fmt|lint|test iam/role`; regenerate USAGE.md
      lock-free.

#### Success Criteria

- Every pre-existing `iam/role` run passes **unchanged** — the
  zero-diff bar, since the module shipped as `v0.23.0` one day prior.
- Both cardinalities of `require_org_ids` asserted, so neither shape
  of the collapse can hide a vacuous test.
- Both conditions render into one statement; the two-condition run
  fails if a refactor ever splits them.
- Each of the five rejections verified against its own rule.

---

### Phase 2: The pod-identity-access backport

#### Tasks

- [x] 2.1 `variables.tf`: the four validations, mirrored **verbatim**
      from `iam/role` (same regexes, same error-message wording where
      the input names match) so the two surfaces are diffable.
- [x] 2.2 The `managed_policy_arns` comment carrying the F2 note — the
      channel partition is what makes cross-channel duplication
      unrepresentable; anyone loosening the regexes for `aws-cn` /
      `aws-us-gov` must keep the account field mutually exclusive or
      restore the precondition.
- [x] 2.3 **WITHDRAWN, replaced by documentation** (operator
      decision 2026-09-09, after task 2.4's evidence). No
      precondition. Instead the discard is made *visible*: the
      `create_role` description states that the four Mode A policy
      inputs are accepted and ignored in Mode B and why the
      tolerance is deliberate, each of the four inputs carries a
      "MODE B: ignored" note, and the README gains a
      "Mode B ignores the four policy inputs" section ending with
      the symptom a confused caller would actually search for.
- [x] 2.4 **Verify the gap before fixing it**: confirmed —
      `create_role = false` + `managed_policy_arns` plans green and
      attaches nothing. It also surfaced that this is **deliberate
      and already regression-tested** (`mode_b.tftest.hcl` passes
      policy inputs on purpose "to prove gating"), which is what
      withdrew 2.3. A guard written against an assumed bug is a guard
      nobody has seen fire.
- [x] 2.5 `expect_failures` runs, each message-probed. **Four
      landed** (one per validation); the fifth belonged to the withdrawn
      2.3 precondition and is not written. Note these runs each need
      an `override_data` on the eks remote state: a
      variable-validation failure does **not** short-circuit
      data-source evaluation, so without it the run dies on real
      credentials rather than the rule under test.
- [x] 2.6 `just tf fmt|lint|test eks/pod-identity-access`; regenerate
      USAGE.md lock-free.

#### Success Criteria

- Every pre-existing `pod-identity-access` run passes unchanged
  (9 runs green, including `mode_b`, which the withdrawn Part C
  guard would have broken).
- The four new rejections each fire their own rule, verified by
  message.
- Task 2.4's evidence recorded in this doc — the silent discard
  reproduced, and found to be deliberate and already regression-
  tested, which is what withdrew Part C.

---

### Phase 3: Live coverage and closure

#### Tasks

- [ ] 3.1 `iam/role` Community apply: a conditions run reading the
      trust document back through `tests-localstack/fixtures/verify`,
      asserting IAM **stored** the condition. FINDINGS records that
      LocalStack cannot *enforce* it (its STS mints credentials for
      any role ARN, IMPL-0015 Phase 1) — surface only, and the note
      says so rather than implying more.
- [ ] 3.2 **RESOLVED — no apply-tier runs for `pod-identity-access`**
      (operator: "only if it can be done without LocalStack Pro").
      Verified it cannot: every apply creates an
      `aws_eks_pod_identity_association`, and its own FINDINGS.md
      records the suite's last green run against **Pro 2026.6.0** —
      the `tests-localstack/` directory name says community, the
      edition does not. Independently, all five new rules reject at
      **plan**, so an `expect_failures` never reaches apply and the
      tier could not observe them anyway. Record both reasons in
      FINDINGS so the constraint is not mistaken for the whole
      argument.
- [ ] 3.3 READMEs: `iam/role` gains a trust-conditions section stating
      the `aws:PrincipalOrgID` scope honestly (mitigates an
      out-of-org dangling principal, no help in-org) and updated run
      counts; `pod-identity-access` documents the four rejected shapes
      and the `create_role` coherence rule.
- [ ] 3.4 DESIGN-0025 Follow-up 1 marked delivered, pointing at
      DESIGN-0027. CLAUDE.md: the conditions surface, the mirrored
      policy-channel standard, and the Part C guard.
- [ ] 3.5 `just static`; `docz update` + the mangle-set restore;
      `just docs lint`.
- [ ] 3.6 PR labeled `minor`. `### RELEASE NOTES` **must** call the
      `pod-identity-access` change out as possibly-plan-breaking and
      list the four rejected shapes — it can fail a
      previously-succeeding plan, and that is the one thing a consumer
      needs told.

#### Success Criteria

- Both plan gates green; `iam/role` apply green including the
  conditions run.
- `just static` clean; README/USAGE/CLAUDE.md current.
- Release notes name the breaking-shaped change; release tagged.

---

## Phase 2 finding: task 2.4 contradicts Part C

Task 2.4 exists to reproduce the silent discard before guarding it.
It did reproduce — and it also found three reasons the guard is
probably **wrong**, which is exactly what "verify before fixing"
is for.

**1. The combination is deliberately tested today.**
`tests/mode_b.tftest.hcl` passes `managed_policy_arns` and
`inline_policies` *with* `create_role = false`, commented
"**Policy inputs intentionally non-empty to prove gating**", and
asserts zero attachments result. A Part C precondition would fail
that run at plan. It is not an accidental gap nobody considered; it
is a deliberate regression proving the count-gating works.

**2. The module already has an "ignored in Mode B" idiom.**
DESIGN-0004 says of `role_name_override`: "When `create_role =
false`, the input is ignored." Its Validation section lists two
cross-variable rules and says nothing about policy inputs — so the
accept-and-ignore behavior is the module's established posture, not
an oversight.

**3. It collides with the fleet's own Terragrunt convention.**
CLAUDE.md records that "in production Terragrunt injects these via
includes into **every** module regardless of use," and IMPL-0015
Q6a resolved that producer-only modules receiving unused inputs is
normal and must not error. A wrapper that passes a uniform input set
across many instances — some Mode A, some Mode B — is the *expected*
shape here. Part C would make that pattern a plan failure on a
module shipped since `v0.21.0`.

**Why the IMPL-0021 precedent does not transfer cleanly.** The
`object_lock` coherence guard rejected retention-without-lock on a
**brand-new surface with zero consumers**, where the only cost was
to a hypothetical future caller. `create_role = false` plus policy
inputs is an **existing accepted combination** on a shipped module
whose callers this repo cannot see (the ADR-0020 blind spot). Same
shape, materially different blast radius.

**Resolution (operator, 2026-09-09): Part C withdrawn, documented
instead.** Making the discard *visible* was the part actually
missing; making it *fatal* would break working callers to tell them
something a sentence can. The Part B validations have none of these
problems — they reject *malformed* values, not *unused* ones — and
shipped unchanged.

**The lesson worth carrying: "this input is silently ignored" is a
documentation defect by default, and a validation defect only when
nothing yet depends on the tolerance.** Look for the regression test
before assuming the silence was an accident.

## Phase 1 probe findings (task 1.4)

The probe ran **before** any assertion was written, and it changed
both the code and the tests. Three of the four findings were not in
DESIGN-0027.

### 1. Go's RE2 caps a bounded repeat at 1000 — `{2,1224}` is an invalid regex

The obvious spelling of the `external_id` rule,
`can(regex("^[\w+=,.@:/-]{2,1224}$", ...))`, is not a working
validation. RE2 rejects the pattern outright
(`invalid repeat count in {2,1224}`), and **`can()` swallows that
error and returns `false`** — so the rule would have rejected *every*
non-null `external_id`. Fail-closed, but total: the variable would
have been unusable, and no test in the plan would have said why.

Split into two rules — charset by regex, length by `length()` — which
is better independent of the bug: they are different failures and now
carry different messages. `variables.tf` comments the trap so nobody
re-merges them.

**Reusable:** `can()` cannot distinguish "the input failed the
pattern" from "the pattern is broken." A validation built on
`can(regex(...))` should be probed against a value that must PASS,
not only against values that must fail — every fail-case test would
have been green here.

### 2. One org id renders a STRING, two render a LIST

The `aws_iam_policy_document` single-element-set collapse (IMPL-0022,
`Principal.AWS`) applies to condition `values` as predicted:

```json
"aws:PrincipalOrgID": "o-a1b2c3d4e5"                    // one
"aws:PrincipalOrgID": ["o-a1b2c3d4e5","o-f6g7h8i9j0"]   // two
```

This is why OQ 1's list resolution made the probe mandatory rather
than nice-to-have: a single-org assertion is vacuous for the
multi-org case the list exists to serve. Both cardinalities have
their own run.

### 3. Two conditions sharing an operator MERGE — not predicted by the design

DESIGN-0027 describes "two conditions in one statement." The rendered
document does not have two condition entries; conditions sharing the
same test operator collapse into **one** `StringEquals` object with
two variable keys:

```json
"Condition": {"StringEquals": {
  "aws:PrincipalOrgID": "o-a1b2c3d4e5",
  "sts:ExternalId": "hub-to-spoke-42"
}}
```

The AND invariant is unaffected — IAM ANDs keys within an operator
block exactly as it ANDs operator blocks — but the **assertion shape
is not what the design implied**. `length(Condition) == 2` is simply
false (it is 1). The suite asserts
`keys(Condition.StringEquals) == {both}` plus
`keys(Condition) == {StringEquals}`. Written from the design text
instead of the probe, the AND-invariant test would have failed for
the wrong reason and likely been "fixed" into something weaker.

### 4. Zero-diff confirmed

With both inputs unset the statement renders **no `Condition` key at
all** — not an empty map — so every `v0.23.0` invocation is
byte-identical. Pinned first in the suite, asserting key *absence*.

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/iam/role/variables.tf` | Modify | `require_org_ids`, `external_id` + validations |
| `modules/iam/role/locals.tf` | Create | `trust_conditions` composition |
| `modules/iam/role/trust.tf` | Modify | `dynamic "condition"` in the existing statement |
| `modules/iam/role/tests/trust_conditions.tftest.hcl` | Create | zero-diff, each condition, both-together, 4 rejections |
| `modules/iam/role/tests-localstack/apply_localstack.tftest.hcl` | Modify | conditions read-back run |
| `modules/eks/pod-identity-access/variables.tf` | Modify | the four mirrored validations |
| `modules/eks/pod-identity-access/main.tf` | Modify | `create_role` coherence precondition |
| `modules/eks/pod-identity-access/tests/` | Modify | 5 rejection runs |
| `modules/*/README.md`, `USAGE.md` | Modify | docs + run counts |
| `docs/design/0025-*.md` | Modify | Follow-up 1 delivered |
| `CLAUDE.md` | Modify | conditions surface + mirrored standard |

## Testing Plan

| Tier | Module | Content |
|---|---|---|
| plan (gate) | `iam/role` | 25 today → +10 (5 composition incl. both org-id cardinalities, 5 rejection) |
| plan (gate) | `eks/pod-identity-access` | +5 rejections — **plan tier only**, see task 3.2 |
| Community apply | `iam/role` | +1 conditions read-back run (token-free 4.4; pure IAM + STS) |
| any apply | `eks/pod-identity-access` | **none** — Pro-gated, and plan-time rejections cannot reach apply |

The `expect_failures` discipline applies throughout: a passing run is
evidence the object errored, **not** evidence the named rule fired.
Nine new rejection runs here, message-probed one file at a time.

## Dependencies

- `iam/role` at `v0.23.0` (merged, tagged).
- No new provider or Terraform version floor: every new validation is
  single-variable, and the Part C guard is a `precondition`, which
  spans variables at any version. Both modules keep their current
  `required_version`.

## Open Questions

1. **Should `require_org_ids` accept a list?** DESIGN-0027 OQ 1 —
   **resolved (b), operator 2026-09-09: yes, a list.** The fleet
   spans multiple organizations. Named `require_org_ids`,
   `list(string)`, `[]` default. Consequence for testing: the
   single-element-set collapse becomes load-bearing, so both
   cardinalities need their own assertion (task 1.4/1.5).
2. **Does `pod-identity-access` need an apply-tier run for these
   rules?** **Resolved: no** — Pro-gated *and* unobservable at that
   tier. See task 3.2 and DESIGN-0027 OQ 3.

## References

- DESIGN-0027 — the design this implements.
- DESIGN-0025 Follow-up 1 — the reserved conditions surface.
- IMPL-0022 — the security review (F1/F2/F4/F6) driving this work.
- IMPL-0020 — `expect_failures` verification discipline.
- IMPL-0021 — the `object_lock` coherence guard Part C mirrors.
- DESIGN-0004 — `eks/pod-identity-access`.
