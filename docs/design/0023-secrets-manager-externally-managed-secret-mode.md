---
id: DESIGN-0023
title: "Secrets Manager externally managed secret mode"
status: Draft
author: Donald Gifford
created: 2026-08-27
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0023: Secrets Manager externally managed secret mode

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
  - [The mode discriminator](#the-mode-discriminator)
  - [Resource gating](#resource-gating)
  - [The guardrail](#the-guardrail)
  - [Output contract under external mode](#output-contract-under-external-mode)
  - [The no-version ordering contract](#the-no-version-ordering-contract)
  - [What does not change](#what-does-not-change)
  - [CI mechanics](#ci-mechanics)
- [Testing Strategy](#testing-strategy)
- [Phases](#phases)
  - [Phase 1: Mode surface and gating](#phase-1-mode-surface-and-gating)
  - [Phase 2: Suites and closure](#phase-2-suites-and-closure)
- [Open Questions](#open-questions)
  - [1. Where does the mode guardrail live?](#1-where-does-the-mode-guardrail-live)
  - [2. Does value mode join the output contract?](#2-does-value-mode-join-the-output-contract)
  - [3. How deep does the external apply verification go?](#3-how-deep-does-the-external-apply-verification-go)
- [References](#references)
<!--toc:end-->

## Overview

`modules/secretsmanager/secret` gains an **externally-managed mode**:
the module creates the secret shell, resource policy, and CMK wiring —
and **never a value**. The value arrives out-of-band (an operator, the
cluster registration flow's neighbors, a provisioning tool) and the
module never sees, generates, or seeds it. This is the third content
leg DESIGN-0020 deliberately left open (INV-0011 F6), selected by a
`value_mode` discriminator defaulting to today's generated behavior
(INV-0011 OQ 9a), with **no placeholder version** in v1 (OQ 10a).

The concrete first consumers come from the platform substrate: ArgoCD
**git credentials** and **Okta OIDC client secrets** — the two secret
classes the platform's DESIGN-0001 restricts substrate Terraform to
("secrets whose values originate outside the platform … as *shells*
with externally-supplied values"). Fleet registration secrets are
explicitly NOT this: cluster stacks write those in the live repo; no
module here ever touches them.

## Goals and Non-Goals

### Goals

- One additive `value_mode` input (`"generated"` default /
  `"external"`), zero change for every existing consumer.
- External mode creates **no value-bearing resource at all**: the
  ephemeral password and the `aws_secretsmanager_secret_version`
  resource are count-gated off together — the fleet's first in-tree
  count-gated ephemeral, probe-validated by INV-0010 F3 ("a
  `count = 0` ephemeral is simply never opened").
- Shell, `read_principals` policy, KMS posture (managed-key default /
  BYO CMK / faithful-null output), `name_prefix`, recovery window,
  and the ADR-0020 `secrets` key shape all apply unchanged — external
  consumers read the identical pointer contract.
- A plan-time guardrail: external mode with any generation knob set
  fails loudly (the no-silent-ignored-input doctrine).
- The two generation-echo outputs (`secret_string_version`,
  `username`) go **faithfully null** in external mode — the
  established `kms_key_arn` precedent (INV-0011 F6).

### Non-Goals

- **Seeding a placeholder version.** Resolved v1-out (INV-0011
  OQ 10a): the shell exists, `GetSecretValue` fails until the value
  is written — an ordering contract the consuming stacks own. The
  ECR-style write-only placeholder is a recorded follow-up if a
  consumer needs a well-formed shape pre-population, not a v1
  surface.
- **BYO caller-supplied values through Terraform.** Still deferred
  (DESIGN-0020 Follow-up 4, unchanged): external mode is
  "no value through Terraform, ever," not "value via ephemeral
  variable."
- **Rotation.** External values rotate out-of-band by whoever owns
  them; `secret_string_version` has no meaning in this mode (the
  guardrail rejects it).
- **A separate sibling module.** Rejected as OQ 9b — it would
  duplicate the shell/policy/KMS surface and split the `secrets`
  state-shape producers.

## Background

INV-0011 F6 concluded, building on DESIGN-0020 / INV-0010:

- DESIGN-0020 OQ 1 resolved exactly two content shapes (generated
  bare / generated RDS-JSON) and explicitly deferred BYO-value;
  "external" (no value at all) is a third leg the design left open.
  INV-0010 OQ 3 option c even named the pattern — rejected for the
  RDS create mode, directly on-point here.
- Mechanics are probe-validated: ephemeral blocks take `count`;
  INV-0010's probe module was literally a count-gated ephemeral →
  `secret_string_wo` (F6). This module already cannot use
  `mock_provider` (ephemeral types are rejected at the type level),
  so the real-provider-fake-creds constraint is unchanged.
- Contract friction identified (F6): `outputs_contract.tftest.hcl`
  pins the six-output set by name, and two outputs are
  generation-mode echoes whose semantics vanish in external mode —
  resolved by faithful null (OQ 9a), with the contract-set question
  in OQ 2 below.
- The conftest credential gate (`policy/credentials.rego`) constrains
  any future placeholder to the `_wo` form — already the only legal
  path; external mode itself adds no persisted-credential surface at
  all (there is nothing to persist).

## Detailed Design

### The mode discriminator

```hcl
variable "value_mode" {
  description = "How the secret's value comes to exist. \"generated\" (default): the module generates it in-memory and writes it write-only — today's behavior, unchanged. \"external\": the module creates the SHELL ONLY (secret + policy + KMS wiring) and never any value; the value arrives out-of-band and GetSecretValue fails until it does. An enum (not a bool) so the deferred BYO-ephemeral leg can land as a third value without a surface change."
  type        = string
  default     = "generated"
  nullable    = false

  validation {
    condition     = contains(["generated", "external"], var.value_mode)
    error_message = "value_mode must be \"generated\" or \"external\"."
  }
}
```

The enum-over-bool choice is deliberate (OQ 9a): DESIGN-0020
Follow-up 4's BYO-ephemeral leg lands later as a third value with no
breaking rename.

### Resource gating

The ephemeral and the version resource gate off **together** — the
value path exists as a unit or not at all:

```hcl
locals {
  generated = var.value_mode == "generated"
}

ephemeral "random_password" "this" {
  count = local.generated ? 1 : 0
  # ... unchanged args
}

resource "aws_secretsmanager_secret_version" "this" {
  count = local.generated ? 1 : 0
  # ... unchanged args, referencing ephemeral.random_password.this[0]
}
```

Notes:

- This is the fleet's **first in-tree count-gated ephemeral**
  (INV-0011 F6) — the INV-0010 F3 probe already proved a `count = 0`
  ephemeral is never opened under the real-provider pattern. The
  main.tf comment records the probe citation so nobody "simplifies"
  the gate into conditionals inside the resource.
- The existing generated path gains `[0]` indexing — a pure
  refactor; the plan suite's no-leak assertion
  (`secret_string_wo == null`) moves to the indexed address and
  otherwise stands.
- The ephemeral-reference invariant is unchanged: nothing outside the
  version resource may reference the ephemeral's result.

### The guardrail

External mode with generation knobs set fails at plan — a
cross-variable rule (mechanism per OQ 1) covering:

- `username != null`
- `password_length != 32` (the default)
- `password_override_special` non-default
- `secret_string_version != 1` (the default)

The error message names `value_mode` and the offending knob, and
states the why: a generation input silently ignored under external
mode would misrepresent what the module manages. (Default-value
comparison, not null-comparison, because the generation variables
carry defaults — the guard triggers only on deliberate caller input.)

### Output contract under external mode

Per INV-0011 OQ 9a, the pointer outputs are mode-independent
(`secret_arn`, `secret_id`, `secret_name`, `kms_key_arn`) and the two
generation echoes go faithfully null:

```text
secret_string_version — null in external mode (no version gate exists)
username              — null in external mode (no content shape exists)
```

The faithful-null rule is the `kms_key_arn` precedent: an output that
reports a fact that does not exist reports null, never a synthetic
default. Whether the contract also grows a `value_mode` output is
OQ 2 — the `outputs_contract.tftest.hcl` set-pin makes that a
deliberate, reviewed change either way.

### The no-version ordering contract

With no seeded version (OQ 10a), `GetSecretValue` on a fresh external
shell fails with `ResourceNotFoundException` ("Secrets Manager can't
find the specified secret value") until the out-of-band write lands.
The README documents this as the mode's **ordering contract**:

- The consuming stack (ESO ClusterSecretStore templates, CI reading
  git credentials) must tolerate the empty window or sequence its
  bring-up after the value write — consumer-owned, exactly like the
  registration-secret flow the platform already runs ("secrets flow
  one way, from Secrets Manager into the cluster").
- The operator runbook line: write the value with
  `aws secretsmanager put-secret-value` (or the owning tool), which
  creates AWSCURRENT without touching the Terraform-managed shell —
  subsequent applies see no diff (the module manages no version
  resource in this mode, so there is nothing to fight over).
- If a consumer ever genuinely needs a well-formed placeholder
  pre-population, the recorded follow-up is the ECR-style
  `secret_string_wo` + pinned version pattern — behind the same
  conftest gate.

### What does not change

Everything else is mode-independent, verbatim from DESIGN-0020:
`name_prefix` naming + the recovery-window rationale,
`secret_recovery_window_days`, the KMS posture and its cross-account
CMK caveat, `read_principals` (count-gated policy, wildcard
rejection), `description`/`tags`, the ADR-0020
`<account_name>/<region>/secrets/<name>` key shape and its
triple-coupling, and the `required_version = ">= 1.11"` floor (the
generated path still uses write-only args; the floor comment
stays).

### CI mechanics

No new tiers, no new directories — the module's existing plan gate
and Community apply suite grow runs. `just changed` picks the module
up on any diff as today.

## Testing Strategy

Both tiers keep the real-provider-fake-creds pattern (the
mock_provider incompatibility is structural and mode-independent).

**Plan suite additions (`tests/`):**

- External-mode shape run: version resource count 0 (and by
  construction no ephemeral opens), shell/policy/KMS planned
  normally, the two echo outputs null, pointer outputs present.
- Guardrail runs: each generation knob under external mode fails
  (`expect_failures` per OQ 1's mechanism).
- Generated-path regression: the existing no-leak assertion
  (`secret_string_wo == null` on the indexed address) and the full
  existing suite stay green — the refactor-visibility runs.
- Contract run: the output set updated per OQ 2's resolution.

**Community apply additions (`tests-localstack/`,
`SERVICES=secretsmanager,sts`, token-free 4.4):**

- Apply an external shell (+ `read_principals` policy), assert the
  pointer outputs are real ARNs and — per OQ 3 — that **zero**
  versions exist, via the plural metadata-only
  `aws_secretsmanager_secret_versions` data source (the DESIGN-0020
  F4-proof fixture pattern; never the singular value-bearing one).
- Teardown via `secret_recovery_window_days = 0` as today.
- FINDINGS.md: whether LocalStack's `GetSecretValue` on a
  version-less secret returns the same `ResourceNotFoundException`
  shape as AWS (parity note for consumer runbooks).

## Phases

### Phase 1: Mode surface and gating

- [ ] `value_mode` variable + validation; count-gate the ephemeral +
      version resource together (probe citation comment); `[0]`
      indexing refactor
- [ ] Guardrail per OQ 1; faithful-null echo outputs (+ OQ 2
      contract change if resolved yes)
- [ ] Plan suite additions per Testing Strategy
- [ ] `just tf docs`; conventional commit

Success criteria: full plan suite green including every existing
generated-path run unchanged in outcome; `just static` green;
`just conftest` green (no new persisted-credential surface).

### Phase 2: Suites and closure

- [ ] Community apply additions per OQ 3; run live against 4.4
- [ ] FINDINGS.md parity note
- [ ] README: the external mode section — ordering contract, runbook
      line, placeholder follow-up pointer, consumer examples (git
      credentials, OIDC client)
- [ ] CLAUDE.md secretsmanager section update; INV-0011 delivery
      note; ADR-0020 consumer-table note if OQ 2 adds the output
- [ ] `docz update` (+ mangle-set restore); conventional commits; PR
      labeled `minor`

Success criteria: `just tf test-localstack secretsmanager/secret`
green live; docs agree with the shipped surface verbatim.

## Open Questions

> **All resolved 2026-08-27: 1a, 2a, 3a.** The guardrail is a
> precondition on the secret resource, `value_mode` joins the pinned
> output contract (seven outputs), and the external apply asserts
> zero versions via the plural metadata-only data source. The
> Detailed Design above is already written to the recommended
> shapes — no amendments.

### 1. Where does the mode guardrail live?

This module's `required_version = ">= 1.11"` floor makes
cross-variable `validation` blocks legal (unlike the `>= 1.1` fleet
norm that forced the precondition convention in `rds/*`).

- **a. (Recommended)** A `lifecycle.precondition` on
  `aws_secretsmanager_secret.this` (the always-present resource) —
  the fleet's established cross-variable mechanism, one home for the
  whole rule, `expect_failures`-testable, and consistent with how
  `rds/*` and `pod-identity-access` read. Consistency wins while
  both mechanisms work.
- b. Cross-variable `validation` blocks on each generation variable
  ("not settable when value_mode = external") — the error binds to
  the exact offending variable (better operator UX), legal at this
  module's floor, and arguably the fleet's future direction; but it
  splits one rule across four variables and diverges from every
  sibling module's convention today.
- Other: (your call)

### 2. Does value mode join the output contract?

`outputs_contract.tftest.hcl` pins the output set by name — adding
one is a deliberate contract change.

- **a. (Recommended)** Yes — add a `value_mode` output (the input,
  echoed). Consumers and operators can distinguish "external shell
  awaiting its value" from "generated secret" from state alone —
  which is exactly the diagnostic needed when `GetSecretValue`
  fails during the ordering window — and future consumers (an ESO
  template generator, the RDS reference mode's sanity checks) get a
  branchable fact. Cost: a seven-output contract and one suite
  update.
- b. No — keep the six-output contract; the mode is inferable from
  the null echoes (`secret_string_version == null` ⇒ external).
  Smaller, but inference-from-null is exactly the kind of implicit
  contract the pinned-set discipline exists to avoid.
- Other: (your call)

### 3. How deep does the external apply verification go?

- **a. (Recommended)** Assert the **absence** of versions live: the
  plural metadata-only `aws_secretsmanager_secret_versions` fixture
  reads the applied shell and the suite asserts zero versions — the
  mode's defining property proven against a real API, value-free by
  construction (metadata only). Plus the policy-present and
  pointer-ARN assertions.
- b. Plan-only coverage for external mode (apply suite unchanged) —
  cheaper, but the one property that distinguishes this mode
  ("no version exists") would never be proven against an API, and
  the fixture pattern needed already exists from the F4 proof.
- Other: (your call)

## References

- **INV-0011** — the parent investigation: F6 (the third content
  leg; probe-validated gating; contract friction; guardrail;
  no-version wrinkle), OQ 9a/10a resolutions, F1 (the platform
  consumers: git credentials + Okta OIDC shells; registration
  secrets excluded from substrate Terraform).
- DESIGN-0020 / IMPL-0019 — the producer module this extends: the
  ephemeral-reference invariant, the no-leak gate, the pointer-only
  contract, the KMS/policy/naming surfaces reused verbatim, and
  Follow-up 4 (BYO-value stays deferred).
- INV-0010 — F3 (count-gated ephemeral probe; mock_provider
  incompatibility), OQ 3c (the named-but-rejected pattern this mode
  now ships for the right consumers).
- `policy/credentials.rego` — the conftest gate constraining any
  future placeholder to the write-only form.
- Platform DESIGN-0001 §3 (external, distilled in INV-0011 F1
  batch 4) — substrate Terraform owns only externally-sourced secret
  shells; the registration-secret boundary.
- ADR-0020 — the `secrets` key shape (unchanged; the consumer table
  grows a note only if OQ 2 adds the output).
