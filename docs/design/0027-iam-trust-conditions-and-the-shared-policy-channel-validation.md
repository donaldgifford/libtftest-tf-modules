---
id: DESIGN-0027
title: "IAM trust conditions and the shared policy-channel validation surface"
status: Draft
author: Donald Gifford
created: 2026-09-09
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0027: IAM trust conditions and the shared policy-channel validation surface

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-09-09

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Part A — trust conditions on iam/role](#part-a--trust-conditions-on-iamrole)
  - [Part B — the shared policy-channel validation surface](#part-b--the-shared-policy-channel-validation-surface)
  - [Part C — the create_role = false coherence gap](#part-c--the-create_role--false-coherence-gap)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Overview

Two changes that share a root cause. **Part A** adds the typed trust
conditions DESIGN-0025 Follow-up 1 reserved — `aws:PrincipalOrgID`
and `sts:ExternalId` — to `modules/iam/role`, which the IMPL-0022
security review promoted from "expected sooner rather than later" to
a **prerequisite for the cross-account instances**. **Part B**
backports that review's four policy-channel validations to
`modules/eks/pod-identity-access`, the only other module in the fleet
carrying the same four-input policy surface, where all four inputs are
today entirely unvalidated. **Part C** examined a coherence gap
found while reading that module — with `create_role = false`, every
policy input is silently discarded — and **withdrew** the guard it
proposed once IMPL-0024 task 2.4 showed the tolerance is deliberate,
tested, and relied on by the fleet's Terragrunt calling pattern. It
ships as documentation instead.

The root cause shared by A and B is the lesson IMPL-0020 recorded
and IMPL-0022 re-learned: **a permissive default plus a
partially-specified input is a silent widening**, and a mirrored
surface is only as strong as its weakest copy. Part C is the
counterexample that bounds it — see its section.

## Goals and Non-Goals

### Goals

- Give `iam/role` a fail-closed, typed way to require the calling
  principal be in a named AWS Organization and/or present an external
  id, composed into the existing single trust statement.
- Preserve the **zero-diff invariant**: every `iam/role` invocation
  that sets neither input must render a byte-identical trust document
  to `v0.23.0`. The module shipped one day before this work; a
  churning trust policy on an untouched call would be unacceptable.
- Bring `eks/pod-identity-access`'s policy surface to parity with
  `iam/role`'s, so the "mirror" claim in both READMEs is true in both
  directions rather than aspirational.
- Make visible — in variable descriptions and the README — that
  `create_role = false` discards the four Mode A policy inputs.
  (This goal was originally "reject at plan"; see Part C for why
  rejecting was withdrawn in favour of documenting.)

### Non-Goals

- **A generic conditions escape hatch.** A
  `list(object({test, variable, values}))` pass-through was
  considered and rejected: it is the raw-JSON trust channel by
  another name — any condition or none — which is precisely the
  fail-open shape DESIGN-0025 OQ 1a rejected. Each new condition
  gets a typed input and its own validation, the same way each trust
  rule gets its own validation block.
- **Conditions on `eks/pod-identity-access`.** Its trust is a fixed
  service principal (`pods.eks.amazonaws.com`) minted by the module,
  not caller input; there is no principal-shaped surface to condition.
- **Policy creation** (DESIGN-0025 Follow-up 2 / the `iam/policy`
  sibling). Unaffected and still deferred.
- **Making conditions mandatory.** Neither input is set by default
  (`[]` and `null` respectively), so no condition renders unless
  asked for. The cross-account *guidance* is README/design-level;
  forcing it would break the deploy-role instances that legitimately
  trust in-account automation principals.

## Background

`modules/iam/role` shipped as `v0.23.0` (IMPL-0022, PR #112). Its
pre-merge `iac-security` review found four real defects, two of which
directly motivate this design:

- **F4** — the module's documented apply-time backstop ("a wrong ARN
  spelling fails the apply") holds only **same-account**. IAM cannot
  resolve a principal in an account it does not own, so a
  cross-account ARN is stored as an unvalidated literal: a typo
  applies green, grants nobody, and leaves a **dangling principal**
  that whoever later creates a role by that name inherits. Both of
  the module's worked examples are cross-account.
- **F1/F2/F6** — the policy channels needed four validations that the
  module now has and `eks/pod-identity-access` does not.

`aws:PrincipalOrgID` is the control that survives F4. A dangling
principal squatted in an account **outside** the organization cannot
assume the role no matter what the trust list literally says. Both v1
consumers of `iam/role` (the per-account deploy role and the
`sse-platform-access` spoke role) are intra-org, so the condition
costs them nothing and buys the F4 mitigation.

**Its limit stated honestly:** `aws:PrincipalOrgID` does **not** fix
a typo'd ARN naming a nonexistent role *inside* the org. It shrinks
the dangling-principal blast radius from "anyone who can create a
role in the named account" to "anyone who can create a role in the
named account **and** that account is in our org." That is a large
reduction for an external-account typo and no help at all for an
internal one. It is a mitigation, not a fix; correct ARNs remain the
primary control.

`sts:ExternalId` is the orthogonal, classic confused-deputy control
DESIGN-0025 Follow-up 1 named first. It has no current consumer —
the trigger is "the first third-party trust requirement" — but it
ships alongside because the two share one composition mechanism and
adding it later would mean touching the same statement twice.

## Detailed Design

### Part A — trust conditions on `iam/role`

Two new optional variables, each contributing no condition when unset:

| Variable | Type | Default | Renders |
|---|---|---|---|
| `require_org_ids` | `list(string)` | `[]` | `StringEquals` on `aws:PrincipalOrgID` |
| `external_id` | `string` | `null` | `StringEquals` on `sts:ExternalId` |

`require_org_ids` is a **list** (OQ 1, resolved (b) at review): the
fleet spans multiple organizations, so a role trusting principals
from more than one is a real topology, not a hypothetical. It takes
the `[]` default and `nullable = false` of the module's other
optional lists rather than a null sentinel — empty means "no
condition," and there is no second no-op spelling to reason about.

`external_id` stays a string: an external id is singular by
definition — it is the shared secret one relationship is keyed on,
and a list of accepted values would mean "any of these secrets will
do," which is not a thing anyone wants.

**Composition — the load-bearing decision.** Both conditions go into
the **existing single statement**, never into new statements:

```hcl
data "aws_iam_policy_document" "trust" {
  statement {
    sid    = "AllowAssumeRole"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.trusted_role_arns
    }

    actions = ["sts:AssumeRole"]

    dynamic "condition" {
      for_each = local.trust_conditions
      content {
        test     = condition.value.test
        variable = condition.value.variable
        values   = condition.value.values
      }
    }
  }
}
```

**IAM's three combining rules, which do not agree with each other** —
this is the whole reason composition is a design decision here:

| Level | Combines as | Consequence |
|---|---|---|
| `values` within one condition | **OR** | `require_org_ids` listing two orgs means "in **either** org" — the intended multi-org semantic |
| `condition` blocks within one statement | **AND** | org id **and** external id must both hold |
| `statement` blocks in one document | **OR** | either statement alone grants the assume |

So a list of org ids OR-s correctly *inside* one condition, while the
two conditions must stay *inside* one statement to AND. Splitting
them across statements would turn "in our org **and** presenting the
external id" into "in our org **or** presenting the external id": a
silent widening with no diff a reviewer would notice, and exactly the
F-class shape this design exists to avoid. The single-statement
composition is therefore a **security invariant**, not a style
choice, and the plan suite pins the statement count at 1 in every
conditions run.

`local.trust_conditions` is a compact list built from the two inputs,
so an unset input contributes no block at all:

```hcl
trust_conditions = concat(
  length(var.require_org_ids) == 0 ? [] : [{
    test     = "StringEquals"
    variable = "aws:PrincipalOrgID"
    values   = var.require_org_ids
  }],
  var.external_id == null ? [] : [{
    test     = "StringEquals"
    variable = "sts:ExternalId"
    values   = [var.external_id]
  }],
)
```

**Validations** (single-variable, so `required_version >= 1.1` is
unchanged). Each rule gets its own block, so a rejection run is
verifiable against the rule it names — the `trusted_role_arns`
pattern:

- `require_org_ids` — every entry matches `^o-[a-z0-9]{10,32}$`, the
  AWS organization-id format. This is the F1 lesson applied
  preemptively: an empty string would render
  `"aws:PrincipalOrgID": [""]`, a condition no principal can satisfy.
  It fails *closed*, so it is not a security hole — but it is an
  unexplained total lockout, and the regex costs one block.
- `require_org_ids` — no duplicates. Same rationale as
  `trusted_role_arns`: the condition is an audit surface and should
  state each org once. Org ids are already lowercase-canonical by
  format, so unlike the ARN case a plain `distinct()` is sufficient
  and normalization would be theatre.
- `external_id` — null, or 2–1224 characters matching AWS's documented
  external-id charset `[\w+=,.@:\/-]*`.

**Zero-diff.** With `require_org_ids = []` and `external_id = null`
the `dynamic` block emits nothing and the rendered document is
byte-identical to `v0.23.0`'s. Pinned by a plan run asserting the
statement carries no `Condition` key at all — asserting an *empty*
condition map would pass on a document that renders
`"Condition": {}`, which is a different document.

> **Correction from the IMPL-0024 task 1.4 probe.** The rendered
> document does **not** carry two condition entries. Conditions
> sharing a test operator merge into ONE `StringEquals` object with
> two variable keys — `{"StringEquals": {"aws:PrincipalOrgID": ...,
> "sts:ExternalId": ...}}`. The AND invariant above is unaffected
> (IAM ANDs keys within an operator block just as it ANDs operator
> blocks), but the assertion shape is: `length(Condition) == 2` is
> false, and the suite pins
> `keys(Condition.StringEquals)` instead.

**The single-element collapse applies here too.**
`aws_iam_policy_document` collapses single-element sets, which
IMPL-0022 found on `Principal.AWS`. Condition `values` are a set, so
one org id very likely renders as a bare **string** and two as a
**list** — meaning an assertion written against a one-org run proves
nothing about a two-org run, which is precisely the case this OQ
resolution exists to support. Probe the rendered JSON first, then
test **both** cardinalities.

### Part B — the shared policy-channel validation surface

The four validations `iam/role` gained in IMPL-0022 become the
fleet's standard for this surface, mirrored verbatim into
`eks/pod-identity-access`:

| Input | Rule | Defect it closes |
|---|---|---|
| `permissions_boundary` | null or IAM policy ARN | **F1** — `""` applies as *no boundary* (the provider omits the argument on create, deletes the boundary on update), so a plan reads "bounded" and applies unbounded |
| `managed_policy_arns` | `^arn:aws:iam::aws:policy/.+$` | **F6**, and structurally **F2** |
| `customer_managed_policy_arns` | `^arn:aws:iam::[0-9]{12}:policy/.+$` | **F6**, and structurally **F2** |
| `inline_policies` | `can(jsondecode(v))` | apply-time `MalformedPolicyDocument` moved to plan |

The two channel regexes partition on the account field (`aws` vs 12
digits), which are mutually exclusive — so listing one ARN in both
channels becomes **unrepresentable** rather than merely guarded.
That is how F2 is fixed in both modules: a `setintersection`
precondition on top would be permanently unreachable, and an
unreachable guard is untestable and rots. Both modules carry the
comment telling anyone who loosens the regexes (for `aws-cn` /
`aws-us-gov`) to keep the account field mutually exclusive or restore
the precondition.

**This is a behavior change to a shipped module.** See Migration.

### Part C — the `create_role = false` coherence gap

`eks/pod-identity-access` gates every Mode A resource on
`var.create_role`. When it is `false`, the caller supplies
`existing_role_arn` and the module creates only the association — but
`managed_policy_arns`, `customer_managed_policy_arns`,
`inline_policies` and `permissions_boundary` are still *accepted*,
and silently do nothing. A caller who sets `create_role = false` and
passes a policy ARN believes they granted a permission they did not.

The first draft of this design called for a **coherence
precondition** rejecting the combination at plan, on the IMPL-0021
`object_lock` precedent (retention set, lock disabled, retention
silently discarded → reject).

> **WITHDRAWN — IMPL-0024 task 2.4, operator decision 2026-09-09.**
> Task 2.4 exists to reproduce a gap before guarding it. It
> reproduced the discard *and* found three reasons the guard is
> wrong:
>
> 1. **It is deliberately tested today.**
>    `tests/mode_b.tftest.hcl` passes `managed_policy_arns` and
>    `inline_policies` *with* `create_role = false`, commented
>    "Policy inputs intentionally non-empty to prove gating," and
>    asserts zero attachments. The precondition would fail that run.
>    This is a considered behavior with a regression, not an
>    oversight.
> 2. **The module already has an accept-and-ignore idiom.**
>    DESIGN-0004 says of `role_name_override`: "When
>    `create_role = false`, the input is ignored." Its Validation
>    section defines two cross-variable rules and deliberately says
>    nothing about the policy channels.
> 3. **It collides with the fleet's Terragrunt convention.**
>    Terragrunt "injects these via includes into **every** module
>    regardless of use" (CLAUDE.md), and IMPL-0015 Q6a resolved that
>    unused inputs must not error. A wrapper passing a uniform input
>    set across Mode A and Mode B instances is the expected shape.
>
> **Why the IMPL-0021 precedent does not transfer.** `object_lock`
> guarded a **brand-new surface with zero consumers**, where the only
> cost fell on a hypothetical future caller. This is an **existing
> accepted combination on a module shipped since `v0.21.0`** whose
> callers this repo cannot see (the ADR-0020 blind spot). Same
> shape, materially different blast radius — and "reject the
> incoherent combination" is only cheap when nobody is relying on it.
>
> **Instead:** document it. The `create_role` description and the
> four policy-channel descriptions state plainly that Mode B ignores
> them, and the README says so where a caller configuring Mode B will
> read it. Making the discard *visible* is the part that was actually
> missing; making it *fatal* would break working callers to tell them
> something a sentence can.

The lesson worth carrying: **"this input is silently ignored" is a
documentation defect by default and a validation defect only when
nothing yet depends on the tolerance.** Check for the regression
test before assuming the silence was an accident.

## API / Interface Changes

**`modules/iam/role`** — two additive optional variables
(`require_org_ids`, `external_id`). No output changes. No existing
input changes shape. Every current invocation plans zero-diff.

**`modules/eks/pod-identity-access`** — no new variables. Four
existing inputs gain validations, and one new cross-variable
precondition fires. **Previously-accepted calls can now fail at
plan** — that is the point, but it is a breaking-shaped change for
any caller currently passing an empty-string boundary, a
mis-channeled policy ARN, unparseable inline JSON, or policy inputs
alongside `create_role = false`.

## Data Model

No state-shape change. No remote-state contract change: `iam/role`
publishes at the ADR-0020 `iam` shape with the same three pointer
outputs, and `eks/pod-identity-access` remains an eks-state consumer
with unchanged outputs. Nothing downstream re-plans.

## Testing Strategy

Plan suites are the gate for both modules, per fleet convention.

**`iam/role`** (25 runs today):

- The zero-diff run — neither input set, asserting the statement has
  **no** `Condition` key.
- **One** org id: one condition, `StringEquals` on
  `aws:PrincipalOrgID`, statement count still 1.
- **Two** org ids: the same condition carrying both — the OQ 1
  cardinality, and the run that catches the single-element collapse
  making the one-org assertion vacuous.
- `external_id` alone: same shape on `sts:ExternalId`.
- **Both together**: two conditions in **one** statement — the
  AND-vs-OR invariant, the run that would catch a future refactor
  splitting them.
- Rejections, each message-probed per IMPL-0020 discipline: malformed
  org id, empty-string org id, duplicate org id, out-of-range
  external id, bad-charset external id.

The `aws_iam_policy_document` single-element-set collapse applies to
condition `values` as it does to `Principal.AWS` — probe the rendered
JSON before writing the assertion rather than assuming a list.

**`eks/pod-identity-access`**: one `expect_failures` run per new
validation plus one for the Part C precondition, each verified
against the rule it names (five validations and preconditions now sit
on that module's inputs, so a green `expect_failures` alone proves
only that *something* errored). **Plan tier only** — see OQ 3.

**Apply suite**: `iam/role`'s Community suite gains a conditions run,
reading the trust document back through the existing
`fixtures/verify` to confirm IAM stores the condition — the far-side
check, not the provider's recording. This one is Community-safe (pure
IAM + STS on token-free 4.4). LocalStack cannot *enforce* the
condition — its STS mints credentials for any role ARN (IMPL-0015
Phase 1) — so it asserts the surface only, and FINDINGS says so
rather than letting a green run imply more.

## Migration / Rollout Plan

**`iam/role`** — purely additive; no consumer action. Ships as a
**minor**.

**`eks/pod-identity-access`** — the validations can fail a
previously-succeeding plan. Mitigating facts, checked rather than
assumed:

- The module's four inputs have no in-repo consumers outside its own
  test suites (the live-repo callers are unknown to this repo, which
  is the usual ADR-0020 blind spot).
- Every rejected input is one the caller almost certainly did not
  intend: an unbounded role that reads as bounded, a policy in the
  wrong channel, unparseable JSON, or permissions that silently never
  attach.
- The failure is a **plan** failure with a message naming the fix, not
  a broken apply or a destroyed resource.

Release notes must call the change out explicitly as
possibly-plan-breaking with the four rejected shapes listed.
`pod-identity-access` is one of the four eks modules the hub posture
pins at `v0.21.0`+; this rides the next minor with the rest of the
fleet, and the hub buildout should re-plan before adopting it.

## Open Questions

1. **Should `require_org_id` accept a list of org ids?**
   **RESOLVED (b), operator, 2026-09-09: list.** The fleet spans
   multiple organizations, so a role trusting principals from more
   than one is a live topology rather than the hypothetical (a)
   assumed. Named `require_org_ids`, `list(string)`, `[]` default,
   `nullable = false`; `StringEquals` OR-s the values inside the one
   condition, which is the correct "in any of our orgs" semantic.
   1. (a) No — single string, forcing multi-org into an explicit
      design conversation. Rejected: the conversation already
      happened and the answer is "we have several."
   2. **(b)** `list(string)`, `StringEquals` against all of them.
      **Chosen.** Note this makes the single-element-set collapse
      load-bearing — one org renders a string, two a list — so both
      cardinalities need their own assertion.
2. **Should the Part B backport also cover `iam/role`'s trust
   normalization** (the `trimspace` + normalized-duplicate rules)?
   1. **(a)** No — not applicable. `eks/pod-identity-access` has no
      caller-supplied principal list; its trust is a fixed service
      principal. There is nothing to normalize.
   2. (b) Add a defensive equivalent anyway — rejected as a guard
      over an input that does not exist.
3. **Does `eks/pod-identity-access` need apply-tier coverage for the
   Part B/C rules?**
   **RESOLVED: no, operator constraint 2026-09-09 — "only if it can
   be done without LocalStack Pro."** It cannot, and it would not
   help even if it could. Two independent reasons:
   1. **Pro-gated.** Every apply of this module creates an
      `aws_eks_pod_identity_association`, and EKS is Pro-only on
      token-free Community 4.4 (probed, IMPL-0020 Phase 5). Its
      `tests-localstack/FINDINGS.md` records the suite's last green
      run against Pro 2026.6.0 — the directory name says "community"
      but the edition does not.
   2. **The tier cannot observe these rules anyway.** All five are
      variable validations and a precondition: they reject at
      **plan**, so an `expect_failures` run never reaches apply. An
      apply-tier addition would assert something the plan gate
      already proves, at the cost of a Pro container.

   The IMPL-0022 lesson ("a fix is not covered just because a
   regression exists at the tier where the logic lives") is what
   forced the question, and it is worth being precise about why the
   answer differs here: that lesson bit where a *plan* regression sat
   over a degenerate *live* case — a real apply that never exercised
   the path. These rules have no live path to degenerate. Nothing is
   being waved through on the Pro constraint alone.
4. **Does the Part C precondition belong on the association resource
   or on the role?**
   1. **(a)** The association — it is the one resource that exists in
      *both* modes, so the guard fires whether or not the role is
      created, and it is where the sibling `create_role` invariant
      already lives. A precondition on the count-gated role would
      evaluate zero times in exactly the mode it needs to catch.
   2. (b) A new `terraform_data` guard resource — more addressable in
      isolation, but a resource that exists only to hold a check is
      noise when a correct site already exists.

## Follow-ups

1. **A `require_trust_conditions` opt-in guard** (raised by the
   IMPL-0024 pre-merge security review, deliberately not shipped).
   A computed input that resolves to unset — `try(..., [])`, a
   `compact()` that empties, or an explicit `null` coerced to `[]` by
   `nullable = false` — renders **no condition**, indistinguishable
   from never having asked for one. That is the same shape as
   IMPL-0020's HIGH, where a prefix-list fence expanding to nothing
   fell through to `0.0.0.0/0`, and it is why that module grew
   `rejects_fence_that_expands_to_nothing`.

   Not shipped now for two reasons. The mitigation is partly real: on
   an **existing** role the plan shows an `assume_role_policy` JSON
   diff a reviewer can see — it is only invisible on a *new* role.
   And the fix is a third input hedging a scenario no live consumer
   has, since no instance sets either condition yet; adding it now
   would be speculative surface on a module shipping this week.

   The shape if it is ever wanted — a precondition, not a validation,
   because it spans two variables:

   ```hcl
   precondition {
     condition     = !var.require_trust_conditions || length(local.trust_conditions) > 0
     error_message = "require_trust_conditions is set but no condition resolved — check that require_org_ids / external_id did not compute to empty."
   }
   ```

   **Trigger to revisit:** the first consumer that computes either
   input from a `dependency` output or a `try()` rather than writing
   it literally.

2. **`aws:PrincipalOrgPaths` with `ForAnyValue:StringLike`** for
   OU-level scoping. Narrower than `aws:PrincipalOrgID`, not
   correcter, and it would introduce the first set-operator condition
   in this module — which is exactly the change the shipped
   `keys(Condition) == {StringEquals}` assertion is designed to force
   review on. `ForAllValues:StringEquals` with an absent key
   evaluates **true**, so any set-operator work here needs its own
   fail-open analysis.

## References

- DESIGN-0025 — the `iam/role` module; Follow-up 1 reserved this
  conditions surface and the single-statement composition that makes
  it additive.
- IMPL-0022 — the build, and the adversarial security review whose
  F1/F2/F4/F6 findings drive Parts A and B.
- IMPL-0020 — the `expect_failures` verification discipline and the
  normalization lesson; the origin of "a permissive default plus a
  partially-specified input is a silent widening."
- IMPL-0021 / DESIGN-0022 — the `object_lock` coherence guard Part C
  mirrors.
- DESIGN-0004 — `eks/pod-identity-access`, the module Parts B and C
  harden.
- ADR-0020 — the remote-state key contract; unchanged by this work.
