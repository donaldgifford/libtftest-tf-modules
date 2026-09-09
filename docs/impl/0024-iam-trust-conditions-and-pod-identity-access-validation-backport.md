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
`modules/iam/role` (`require_org_id` / `external_id`), the four
policy-channel validations backported to
`modules/eks/pod-identity-access`, and the `create_role = false`
coherence guard found while reading that module.

The trust-conditions half is the **prerequisite** the IMPL-0022
security review attached to `iam/role`'s cross-account instances: the
module's apply-time backstop does not exist cross-account, so a typo'd
ARN leaves a dangling principal, and `aws:PrincipalOrgID` is the
control that survives it.

## Scope

### In Scope

- `iam/role`: `require_org_id` + `external_id`, composed into the
  **existing single trust statement**, with the zero-diff invariant
  pinned by a test.
- `eks/pod-identity-access`: validations on `permissions_boundary`,
  `managed_policy_arns`, `customer_managed_policy_arns`,
  `inline_policies`; precondition rejecting policy inputs under
  `create_role = false`.
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

- [ ] 1.1 `variables.tf`: `require_org_id` (null default, `^o-[a-z0-9]{10,32}$`
      or null) and `external_id` (null default, 2–1224 chars,
      `[\w+=,.@:\/-]*`). Descriptions carry the honest scope — org id
      mitigates a dangling principal in an account *outside* the org
      and does nothing for a typo inside it.
- [ ] 1.2 `locals.tf` (new): `trust_conditions`, the compact list built
      from the two nullable inputs so a null contributes no block.
- [ ] 1.3 `trust.tf`: `dynamic "condition"` inside the **existing**
      statement. Comment states the AND-vs-OR invariant — conditions
      in one statement AND, separate statements OR, so splitting them
      would silently widen.
- [ ] 1.4 **Probe before asserting**: render the document with one and
      with two conditions and read the JSON. `aws_iam_policy_document`
      collapses single-element sets (the IMPL-0022 finding on
      `Principal.AWS`); confirm whether condition `values` collapse
      the same way before writing any assertion.
- [ ] 1.5 `tests/trust_conditions.tftest.hcl` (new): the zero-diff run
      (**no `Condition` key at all**, not an empty map), org-id alone,
      external-id alone, and both-together asserting **one** statement
      with **two** conditions.
- [ ] 1.6 Four rejection runs (malformed org id, empty-string org id,
      out-of-range external id, bad-charset external id), each
      message-probed — six rules now sit across the two new variables
      and `expect_failures` proves only that the variable errored.
- [ ] 1.7 `just tf fmt|lint|test iam/role`; regenerate USAGE.md
      lock-free.

#### Success Criteria

- Every pre-existing `iam/role` run passes **unchanged** — the
  zero-diff bar, since the module shipped as `v0.23.0` one day prior.
- Both conditions render into one statement; the two-condition run
  fails if a refactor ever splits them.
- Each of the four rejections verified against its own rule.

---

### Phase 2: The pod-identity-access backport

#### Tasks

- [ ] 2.1 `variables.tf`: the four validations, mirrored **verbatim**
      from `iam/role` (same regexes, same error-message wording where
      the input names match) so the two surfaces are diffable.
- [ ] 2.2 The `managed_policy_arns` comment carrying the F2 note — the
      channel partition is what makes cross-channel duplication
      unrepresentable; anyone loosening the regexes for `aws-cn` /
      `aws-us-gov` must keep the account field mutually exclusive or
      restore the precondition.
- [ ] 2.3 `main.tf`: the Part C coherence precondition on
      `aws_eks_pod_identity_association.this` — policy inputs with
      `create_role = false` fail at plan instead of silently doing
      nothing. Sited on the association because it is the one resource
      that exists in **both** modes; a precondition on the count-gated
      role would evaluate zero times in exactly the mode it must catch.
- [ ] 2.4 **Verify the gap before fixing it**: confirm on the current
      module that `create_role = false` + `managed_policy_arns` plans
      green and attaches nothing. A guard written against an assumed
      bug is a guard nobody has seen fire.
- [ ] 2.5 Five `expect_failures` runs (four validations + the
      precondition), each message-probed.
- [ ] 2.6 `just tf fmt|lint|test eks/pod-identity-access`; regenerate
      USAGE.md lock-free.

#### Success Criteria

- Every pre-existing `pod-identity-access` run passes unchanged.
- The five new rejections each fire their own rule, verified by
  message.
- Task 2.4's before/after evidence recorded in this doc — the
  silent-discard reproduced, then rejected.

---

### Phase 3: Live coverage and closure

#### Tasks

- [ ] 3.1 `iam/role` Community apply: a conditions run reading the
      trust document back through `tests-localstack/fixtures/verify`,
      asserting IAM **stored** the condition. FINDINGS records that
      LocalStack cannot *enforce* it (its STS mints credentials for
      any role ARN, IMPL-0015 Phase 1) — surface only, and the note
      says so rather than implying more.
- [ ] 3.2 Decide whether `pod-identity-access`'s apply suite needs a
      run at all: its new rules are **plan-time rejections**, and
      IMPL-0022's lesson was "a fix is not covered just because a
      regression exists at the tier where the logic lives." Record the
      call either way — if the answer is no, say why in FINDINGS.
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

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/iam/role/variables.tf` | Modify | `require_org_id`, `external_id` + validations |
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
| plan (gate) | `iam/role` | 25 today → +8 (4 composition, 4 rejection) |
| plan (gate) | `eks/pod-identity-access` | +5 rejections |
| Community apply | `iam/role` | +1 conditions read-back run |

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

1. **Should `require_org_id` accept a list?** DESIGN-0027 OQ 1 —
   resolved **(a) single string**; widening a validated string to a
   validated list later is additive.
2. **Does `pod-identity-access` need an apply-tier run for these
   rules?** Deferred to task 3.2 with the reasoning recorded there
   rather than assumed now.

## References

- DESIGN-0027 — the design this implements.
- DESIGN-0025 Follow-up 1 — the reserved conditions surface.
- IMPL-0022 — the security review (F1/F2/F4/F6) driving this work.
- IMPL-0020 — `expect_failures` verification discipline.
- IMPL-0021 — the `object_lock` coherence guard Part C mirrors.
- DESIGN-0004 — `eks/pod-identity-access`.
