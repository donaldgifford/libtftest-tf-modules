---
id: IMPL-0024
title: "IAM trust conditions and pod-identity-access validation backport"
status: Completed
author: Donald Gifford
created: 2026-09-09
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0024: IAM trust conditions and pod-identity-access validation backport

**Status:** Completed
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
- [Phase 2 finding: task 2.4 contradicts Part C](#phase-2-finding-task-24-contradicts-part-c)
- [Phase 1 probe findings (task 1.4)](#phase-1-probe-findings-task-14)
  - [1. Go's RE2 caps a bounded repeat at 1000 — {2,1224} is an invalid regex](#1-gos-re2-caps-a-bounded-repeat-at-1000--21224-is-an-invalid-regex)
  - [2. One org id renders a STRING, two render a LIST](#2-one-org-id-renders-a-string-two-render-a-list)
  - [3. Two conditions sharing an operator MERGE — not predicted by the design](#3-two-conditions-sharing-an-operator-merge--not-predicted-by-the-design)
  - [4. Zero-diff confirmed](#4-zero-diff-confirmed)
- [Adversarial security review (pre-merge, `iac-security`)](#adversarial-security-review-pre-merge-iac-security)
  - [MEDIUM — `external_id` on the deploy role breaks all 12 remote-state readers](#medium--external_id-on-the-deploy-role-breaks-all-12-remote-state-readers)
  - [LOW — `external_id` was described as a "shared secret"; it is not](#low--external_id-was-described-as-a-shared-secret-it-is-not)
  - [LOW — the README named the typo space without splitting it](#low--the-readme-named-the-typo-space-without-splitting-it)
  - [Accepted, not fixed](#accepted-not-fixed)
  - [Test-precision gaps closed (2 of 3)](#test-precision-gaps-closed-2-of-3)
  - [Release-notes gap found](#release-notes-gap-found)
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

- [x] 3.1 `iam/role` Community apply: a conditions run reading the
      trust document back through `tests-localstack/fixtures/verify`,
      asserting IAM **stored** the condition. FINDINGS records that
      LocalStack cannot *enforce* it (its STS mints credentials for
      any role ARN, IMPL-0015 Phase 1) — surface only, and the note
      says so rather than implying more.
- [x] 3.2 **RESOLVED — no apply-tier runs for `pod-identity-access`**
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
- [x] 3.3 READMEs: `iam/role` gains a trust-conditions section stating
      the `aws:PrincipalOrgID` scope honestly (mitigates an
      out-of-org dangling principal, no help in-org) and updated run
      counts; `pod-identity-access` documents the four rejected shapes
      and the `create_role` coherence rule.
- [x] 3.4 DESIGN-0025 Follow-up 1 marked delivered, pointing at
      DESIGN-0027. CLAUDE.md: the conditions surface, the mirrored
      policy-channel standard, and the Part C guard.
- [x] 3.5 `just static`; **`just readme`** (the module table — a
      SEPARATE `readme-check` CI job that `just static` does not
      cover, and which failed on the first push here because both
      modules moved to `unreleased` and their plan-file counts
      changed); `docz update` + the mangle-set restore;
      `just docs lint`. Note the mangle-set `git checkout` does not
      help for a doc you are actively editing — DESIGN-0027's
      `create_role` TOC anchor loses its underscore on every
      `docz update` and must be repaired by hand.
- [x] 3.6 PR labeled `minor`. **Merged as PR #114 → shipped as
      `v0.24.0`** (2026-09-11; tag verified against the merge commit
      `6221ad7`). `### RELEASE NOTES` **must** call the
      `pod-identity-access` change out as possibly-plan-breaking and
      list the four rejected shapes — it can fail a
      previously-succeeding plan, and that is the one thing a consumer
      needs told. Done, and extended after the security review with
      the channel-move detach window and the rejected non-commercial
      partitions.

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

## Adversarial security review (pre-merge, `iac-security`)

Run against the PR #114 diff, scoped to attack the four claims this
IMPL makes rather than restate them. **Verdict: no HIGH, and no path
found to widen the trust surface, bypass a condition, or render
something that looks restrictive but is not.** The IMPL-0022 review
found four real defects; this one found one operational trap and two
documentation errors. The difference is worth recording — the
structural fixes from that review (channel partitioning, normalized
comparison) held under direct attack here.

What was attacked and held, briefly, because knowing what was *tried*
is most of the value:

- **`ForAllValues:StringEquals` with an absent key evaluates TRUE** —
  the single most common way an IAM condition is silently ineffective.
  Unreachable here: `test` is hardcoded `StringEquals` in `locals.tf`
  with no set-operator prefix anywhere, so the module cannot express
  it. Likewise no `StringNotEquals`/`Null` negation path.
- **Empty `values`.** Unreachable from both directions — the org list
  only contributes at `length > 0` and its regex rejects `""`; the
  external id only contributes non-null with a length floor of 2.
- **Type unification.** `concat` of `list(string)` and
  `tuple([string])` unifies rather than dropping a condition
  (confirmed live by `external_id_alone`).
- **Set collapse.** `statement.condition` is a `TypeSet`; the two
  blocks hash differently so neither collapses, and the merged key
  order is Go-map-sorted, so no perpetual diff.
- **Action escape.** `sts:ExternalId` is only evaluated for
  `sts:AssumeRole`, which is the statement's only action — there is
  no second action to slip past the condition.
- **All four regexes**, probed empirically. `^o-[a-z0-9]{10,32}$` and
  the external-id charset are AWS's own documented patterns verbatim;
  the RE2 split is confirmed *necessary and correctly done* (the
  charset pattern was verified to discriminate, so `can()` is not
  swallowing a compile error). The two policy-channel regexes accept
  `job-function/`, `service-role/`, and path-bearing customer ARNs.
- **`aws:PrincipalOrgID` + `StringEquals` is the correct and complete
  spelling.** It is populated from the calling principal's account
  org (correct under role chaining), absent for anonymous and service
  principals (so absent + `StringEquals` → deny, fail-closed). The
  only narrower option is `aws:PrincipalOrgPaths` with
  `ForAnyValue:StringLike` for OU scoping — narrower, not correcter,
  and it drags in the footguns this module currently cannot express.
  Recorded as a possible additive, not a defect.

### MEDIUM — `external_id` on the deploy role breaks all 12 remote-state readers

Verified independently before fixing: **zero** `external_id` appears
in any `assume_role` block fleet-wide outside this module. The
module's own worked example 1 is the per-account deploy role, so the
hazard sits on its primary instance.

Set `external_id` there and every consumer plan dies `AccessDenied`
on the **next** plan — separated from the apply that caused it. The
S3 backend's `assume_role` does accept `external_id`, so the fix is
one line per block, but it must land in the same change; under time
pressure the tempting move is to strip the id back off, which retires
the control rather than adopting it.

This is a **composition hazard, not a module defect** — `external_id`
is correct for a third-party trust, which is what it is for. Fixed as
documentation: a new README subsection and an explicit warning in the
variable description.

### LOW — `external_id` was described as a "shared secret"; it is not

AWS documents an external id as unique and unpredictable but
explicitly **not a secret**, and it lands in CloudTrail
`requestParameters.externalId` on **both** sides of the AssumeRole,
plus plan output and state. Leaving `sensitive` off was the right
call; the description was what invited an operator to rely on its
confidentiality — and it contradicted the README's own correct
ordering (`aws:PrincipalOrgID` survives a dangling principal,
`sts:ExternalId` alone does not). Reworded.

### LOW — the README named the typo space without splitting it

`require_org_ids` covers a mistyped **account number** (which almost
always lands outside the orgs, and is the dangerous half — an account
whose owner can create the dangling role). It does not cover a role-
name typo inside the org, nor a hostile insider in a member account.
The README said the second half; it now says which half *is* covered
and why that is the one that matters.

### Accepted, not fixed

- **Partition hardcoding.** `arn:aws-us-gov:` / `arn:aws-cn:` managed
  policy ARNs are rejected (probed). The fleet is commercial-only, so
  this is inert; recorded so it reads as known-and-accepted rather
  than an oversight. The `variables.tf` comment already warns that
  loosening for another partition must preserve the account-field
  exclusivity that makes IMPL-0022's F2 unrepresentable.
- **A UTF-8 BOM fails `can(jsondecode())`.** The only false-rejection
  candidate found; `PutRolePolicy` would almost certainly reject it
  too. Trailing newline, CRLF, tab indentation, leading whitespace
  and duplicate keys all pass.
- **A computed input resolving to unset silently drops the control**
  (`try(..., [])`, `compact()` emptying, `nullable = false` coercing
  an explicit `null` to `[]`). This is the *shape* of IMPL-0020's
  HIGH — the fence that expands to nothing. Not built: the review
  rated it LOW because on an existing role the plan shows a visible
  `assume_role_policy` diff, and the proposed fix is a third input
  (`require_trust_conditions`) hedging a scenario no live consumer
  has — no instance sets either condition yet. **Recorded as a
  DESIGN-0027 follow-up rather than shipped**, so the decision is
  visible if a consumer ever computes these inputs.
- **Org/trust-list coherence.** A principal in an account outside
  every listed org yields an un-assumable role with no plan signal.
  Fails closed, and the account→org mapping is not plan-knowable, so
  it cannot be validated here.

### Test-precision gaps closed (2 of 3)

The review confirmed the two load-bearing assertion idioms are real
evidence, by probe rather than assumption: `toset()` on a *bare
string* is a **conversion error**, so a two-org run regressing to a
collapsed string errors rather than passing; and `one()` errors on a
2-element list, so every conditions run double-pins the statement
count. It also re-ran the AND-invariant mutation independently and
got the same two reds.

Two gaps were real and are fixed:

1. `single_org_id_renders_a_string` had **no "nothing else rendered"
   guard** — the mirror of `external_id_alone`'s absence assert was
   missing. Added, plus the `keys(Condition) == {StringEquals}`
   operator pin. **Mutation-verified**: forcing the external id to
   render always turns this run red at the new assert, where before
   the change it passed.
2. No conditions run re-asserted `Principal` or `Action`, so a
   refactor perturbing them while editing the `dynamic "condition"`
   block would only have been caught in `trust.tftest.hcl`. Both
   added to `both_conditions_and_within_one_statement`.

The third — that `apply_with_trust_conditions`' lone
`startswith(role_unique_id, "AROA")` assert is true of the
pre-existing role in shared state and would pass with both conditions
dropped — is **left as-is and documented**: the real evidence is
`verify_conditions_readback`, which reads the document back through
`data.aws_iam_role`. The run is not wrong; it simply must not be
counted as conditions coverage.

### Release-notes gap found

Moving an ARN between the two policy channels on
`eks/pod-identity-access` is **not address-neutral** — it is a
destroy + create of the attachment, i.e. a real if brief detach
window. The channel-partition validations make that move necessary
for any caller who had put everything in one channel, so the
migration note now says so.

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
