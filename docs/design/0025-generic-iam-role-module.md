---
id: DESIGN-0025
title: "Generic IAM role module"
status: Draft
author: Donald Gifford
created: 2026-08-28
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0025: Generic IAM role module

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-08-28

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Module layout](#module-layout)
  - [The variable surface](#the-variable-surface)
  - [Trust policy composition](#trust-policy-composition)
  - [Policy channels](#policy-channels)
  - [The two worked examples](#the-two-worked-examples)
  - [Adoption runbook](#adoption-runbook)
  - [Remote-state key contract](#remote-state-key-contract)
  - [Outputs](#outputs)
- [Testing Strategy](#testing-strategy)
- [Phases](#phases)
- [Follow-ups](#follow-ups)
- [Open Questions](#open-questions)
  - [1. What shape is the trust surface?](#1-what-shape-is-the-trust-surface)
  - [2. Do trust conditions land in v1?](#2-do-trust-conditions-land-in-v1)
  - [3. What is the policy channel?](#3-what-is-the-policy-channel)
  - [4. Where does deploy-role adoption happen?](#4-where-does-deploy-role-adoption-happen)
- [References](#references)
<!--toc:end-->

## Overview

`modules/iam/role` — **one generic module replacing the queued
`iam/deploy-role` + `iam/cross-account-role` pair** (INV-0011 queue
revision, 2026-08-28). The two patterns have identical resource
surfaces — an `aws_iam_role` with a composed trust policy, policy
attachments, and inline policies — and differ only in inputs; per the
operator direction, the module condenses to one and "the inputs
define what it does." Its first two instances are the platform
DESIGN-0001 §4 principals: the **per-account deploy role** (exists
outside Terraform today — the brownfield adopt-via-`import` case from
the INV-0011 sequencing note) and the **`sse-platform-access`
cross-account pattern** (trusted by the hub argocd-deployer; its
cluster-side binding is an `eks/access-entries` entry, DESIGN-0024).

## Goals and Non-Goals

### Goals

- Both §4 patterns expressible with one module and zero pattern
  branches: a deploy-shaped instance (trusted by the hub automation
  principals; the role every ADR-0020 `assume_role` block references
  by name) and a platform-access-shaped instance (trusted by one
  assumed-role principal; a scoped inline policy) differ only in
  their inputs.
- **Brownfield-first:** the existing externally-provided deploy roles
  adopt via `import` blocks with a documented match-reality-first
  runbook — the module receives what the hub buildout creates
  manually (INV-0004 doctrine; the sequencing note's
  cleanly-importable tier).
- A typed, fail-closed trust surface: exact principal ARNs only,
  wildcards rejected at plan, no raw-JSON trust channel (OQ 1).
- Pointer-only outputs published at the platform-reserved ADR-0020
  `iam/<name>` shape.
- Producer-only: like `secretsmanager/secret`, the module reads no
  remote state and declares none of the six Terragrunt globals
  (pass-every-input Terragrunt injects them harmlessly, IMPL-0015
  Q6a).

### Non-Goals

- **Service-principal trust** (EC2 instance profiles, Lambda
  execution roles, `pods.eks.amazonaws.com`) — resource-owning
  modules mint their own service roles (`eks/cluster`,
  `managed-node-group`, `pod-identity-access`, `bedrock/claude-code`
  all do); this module is for standalone **trust-boundary** roles
  assumed by other principals. Subject to OQ 1.
- **Standalone policy management** (`aws_iam_policy` resources) — a
  future `iam/policy` sibling if a shared-policy need ever appears
  (OQ 3); v1 attaches existing ARNs and writes inline documents only.
- SSO permission sets, OIDC/SAML identity providers, instance
  profiles — out of scope; different lifecycles, different owners.
- The pod-identity role path — `eks/pod-identity-access` owns it
  (including its own Mode B `existing_role_arn` passthrough).
- **Actually adopting the live deploy roles** — `import` blocks live
  in the live repo's stacks; this repo ships the module and the
  runbook (OQ 4).

## Background

- **The platform §4 principals (distilled in INV-0011 F1):** the hub
  argocd-deployer's pod-identity role assumes each spoke's
  `sse-platform-access` role; that assumed role binds to a deploy
  RBAC group via an access entry (the DESIGN-0024 consumer).
  Break-glass is SSO → admin. The **deploy-role path** is
  load-bearing repo-wide already: every ADR-0020 remote-state read
  composes `arn:aws:iam::<account_id>:role/<deploy_role_name>` and
  assumes it — the role this module will eventually own is referenced
  **by name** across the fleet, which fixes the module's naming
  posture (exact `name`, no prefix).
- **The queue revision (INV-0011, 2026-08-28):** the deploy role
  exists outside Terraform in the other accounts today, so the
  module's job is adoption, not greenfield; the two queued IAM
  DESIGNs condensed into this one.
- **In-repo precedent:** `eks/pod-identity-access` already carries
  the fleet's role-building conventions — the three-channel policy
  surface (`managed_policy_arns` / `customer_managed_policy_arns` /
  `inline_policies` map of JSON), `permissions_boundary`, and
  deterministic naming. This module reuses that surface verbatim
  (OQ 3) so the fleet has one way to express role policies.
- **Import mechanics (the sequencing note):** IAM roles import
  cleanly and piecewise — the role, each attachment, and each inline
  policy are individually importable; trust-policy diffs converge in
  place with zero downtime (IAM is metadata).

## Detailed Design

### Module layout

```text
modules/iam/role/
├── main.tf              # role + attachments + inline policies
├── trust.tf             # data.aws_iam_policy_document.trust
├── variables.tf
├── outputs.tf
├── versions.tf
├── .tflint.hcl
├── README.md            # patterns + adoption runbook + key contract
├── USAGE.md
├── tests/               # plan suite (the gate)
└── tests-localstack/    # Community apply + FINDINGS.md
```

A new `iam/` service directory; the `role/` sub-directory leaves
sibling room (`iam/policy`, `iam/oidc-provider`) the same way
`network/vpc-lookup` and `dns/zone-lookup` do.

### The variable surface

```hcl
variable "name" {
  description = "Exact IAM role name — no prefix, no suffixing. Consumers reference this role BY NAME (the fleet's deploy_role_name global composes assume_role ARNs from it), so the physical name is the contract. Changing it replaces the role."
  type        = string
  nullable    = false
  # validation: IAM role-name charset, length <= 64
}

variable "trusted_role_arns" {
  description = "Exact IAM principal ARNs (roles or users) granted sts:AssumeRole on this role. No wildcards, no service principals, at least one entry — a role nobody can assume is dead weight (see OQ 1)."
  type        = list(string)
  nullable    = false
  # validations: non-empty; each matches arn:aws:iam::<12-digit>:(role|user)/...;
  # wildcard characters rejected
}
```

Plus the standard optional set: `description`, `path` (default
`"/"`), `max_session_duration` (default 3600, validated 3600–43200),
`permissions_boundary` (null default), the three policy channels
(below), and `tags`.

### Trust policy composition

`data.aws_iam_policy_document.trust` — one statement, `Effect =
"Allow"`, `actions = ["sts:AssumeRole"]`, `principals { type = "AWS",
identifiers = var.trusted_role_arns }`. The document data source
evaluates locally (no API call), so the composed `assume_role_policy`
is **plan-known** and the plan suite asserts it via `jsondecode` —
the same plan-knowability discipline as the S3 core's deterministic
bucket ARN. No conditions in v1 (OQ 2).

### Policy channels

Verbatim from `eks/pod-identity-access` (OQ 3):

- `managed_policy_arns` (list, AWS-managed) and
  `customer_managed_policy_arns` (list, caller-owned) — separate
  variables so the plan distinguishes AWS-owned from caller-owned at
  a glance; each drives its own
  `aws_iam_role_policy_attachment` `for_each`.
- `inline_policies` — `map(string)`, policy name → JSON document,
  driving `aws_iam_role_policy` `for_each`. The JSON channel is for
  **authorization** policy documents; the conftest credential gate
  is indifferent to it (no persisted-credential argument exists on
  these resources).

### The two worked examples

The README carries both §4 patterns as full call sites:

1. **Deploy role** — `name` = the fleet's `deploy_role_name` value;
   `trusted_role_arns` = the hub automation principals (the Atlantis
   pod-identity role — the same stable-creator principal DESIGN-0024
   OQ 4 sanctions for cluster creation); policy = the account's
   deploy policy ARN (content is the caller's — typically broad;
   the module does not opine).
2. **sse-platform-access** — `trusted_role_arns` = the hub
   argocd-deployer pod-identity role ARN; `inline_policies` = the
   scoped EKS-access document (`eks:DescribeCluster` + what the
   deploy flow needs); the README cross-references DESIGN-0024: the
   *cluster-side* half of this pattern is an `eks/access-entries`
   entry binding the assumed role to the deploy RBAC group.

### Adoption runbook

A README section ("Adopting an existing role") with the
import-block worked example for the live repo:

- `import` blocks target the module's addresses: the role by name
  (`module.deploy_role.aws_iam_role.this`), each attachment by
  `<role-name>/<policy-arn>`, each inline policy by
  `<role-name>:<policy-name>`.
- **Match reality first, converge second:** write the module inputs
  to mirror the live role (trust ARNs, attachments, inline documents
  verbatim), import, verify the zero-diff plan, then converge
  conventions (descriptions, tags, session duration) in later
  reviewed plans. Trust-policy diffs converge in place — no
  replacement, no downtime.

### Remote-state key contract

The module publishes at the **platform-reserved iam shape**:
`<account_name>/<region>/iam/<name>/terraform.tfstate` (platform
DESIGN-0001 reserves `<account>/<region>/iam/<role>`; ADR-0020 gains
the producer row at IMPL time — a new module inventing its own shape
fails CI). `<name>` is the standard triple coupling: role name ==
live-repo folder == future consumer input. Foreseeable TF consumers:
cross-account trust wiring (a spoke's platform-access stack reading
the hub principal's `role_arn`) — none wired in v1; the row reserves
the shape the way `secrets` was reserved ahead of its consumer.

### Outputs

Pointer-only: `role_arn`, `role_name`, `role_unique_id`. No policy
echo (the caller supplied them), no credential-adjacent values
(nothing here mints credentials — `tools/bedrock-keyctl` territory).

## Testing Strategy

- **Plan suite (`tests/`, the gate):** real-provider-fake-creds (the
  policy-document data source evaluates locally, no API call). Runs:
  a deploy-shaped instance and a platform-access-shaped instance
  pinning the composed trust JSON (`jsondecode` on
  `assume_role_policy` — principal set, single statement, action),
  attachment and inline `for_each` addresses stable under map edits;
  validation failures via `expect_failures` (empty trust list,
  wildcard ARN, malformed ARN, service principal passed as ARN, bad
  session duration, bad name charset); boundary + tags pass-through.
- **Community apply (`tests-localstack/`):** token-free 4.4,
  `SERVICES=iam,sts` — create + attach + inline round-trip asserted
  live. FINDINGS.md records the known LocalStack caveat up front:
  **STS AssumeRole against LocalStack proves nothing about trust
  policies** (it mints creds for any role ARN — the IMPL-0015
  Phase 1 finding), so the apply asserts the IAM surface
  (`get-role`, attachments, inline documents round-tripping), never
  "assumability." The OQ 4 import-feasibility probe rides here as a
  recorded stretch, not a gate.

## Phases

Design-level sketch; the IMPL doc (post-review) carries the task
breakdown:

1. Module core + plan suite (surface, trust composition, policy
   channels, validations).
2. README (both worked examples, the adoption runbook, the key
   contract section).
3. Community apply + FINDINGS.md (incl. the trust-enforcement caveat
   and the import probe).
4. Closure: ADR-0020 producer row, CLAUDE.md `iam/` section, the
   INV-0011 delivery note, minor release.

## Follow-ups

Recorded at OQ review (2026-08-29, operator direction): the OQ 2 and
OQ 3 deferrals stand **only to get started** — both surfaces are
expected **sooner rather than later**, not parked-until-someday.
They are deliberately additive (no v1 shape blocks either), and each
fires its own DESIGN (or a documented minor change) when picked up:

1. **Trust conditions (from OQ 2):** the typed conditions surface —
   `external_id` first (the third-party confused-deputy control),
   then broader typed conditions if needed. Additive to
   `trusted_role_arns`; the v1 single-statement composition is built
   so a conditions block slots in without reshaping the variable.
   Trigger: the first third-party or cross-org trust requirement.
2. **Policy management (from OQ 3):** customer-managed policy
   *creation* — either an in-module `policies` map (name → JSON
   minting `aws_iam_policy` + attaching) or, more likely, the
   `iam/policy` sibling so shared-policy ownership stays
   unambiguous. The v1 three-channel attach surface is unaffected
   either way. Trigger: the first policy shared across two roles, or
   the deploy-policy content moving under Terraform management.

## Open Questions

> **All resolved 2026-08-29: 1a, 2a, 3a, 4a — with OQ 2 and OQ 3
> carrying recorded follow-ups (see [Follow-ups](#follow-ups)):
> both are important and likely needed sooner rather than later;
> deferred from v1 only so the module can ship and the deploy-role
> adoption can start.**

### 1. What shape is the trust surface?

**Resolved: a.** ARN-only typed list; no service principals, no JSON
channel.

- **a. (Recommended)** `trusted_role_arns` — a flat list of exact
  IAM role/user ARNs, regex-validated, wildcards rejected, non-empty
  required; composed into a single AssumeRole statement. Both v1
  consumers need exactly this and nothing more; anything wider is
  additive later (the fleet's additive-only-until-a-concrete-need
  doctrine, per `secretsmanager/secret` OQ 3a).
- b. Add an optional `trusted_services` list (service principals) —
  generalizes to EC2/Lambda-style roles, but resource-owning modules
  already mint their own service roles, and offering the channel
  here invites exactly the scope creep the Non-Goals fence off.
- c. A raw `assume_role_policy_json` escape hatch — maximum
  genericity, zero guardrails: a JSON channel bypasses every
  validation (wildcard principals included), which is the fail-open
  this typed surface exists to prevent.
- Other: (your call)

### 2. Do trust conditions land in v1?

**Resolved: a, with a recorded follow-up.** Deferred from v1 to get
started, NOT parked — conditions are expected sooner rather than
later; see [Follow-ups](#follow-ups) item 1.

- **a. (Recommended)** No — defer. Both v1 consumers are intra-org,
  role-ARN-pinned trust; `sts:ExternalId` is a third-party
  confused-deputy control with no current caller, and an unexercised
  surface is untested surface. Conditions arrive additively (typed,
  per-need) when a real third-party trust shows up.
- b. A single optional `external_id` now — cheap and common in the
  wild, but it would ship unused and unproven by any real consumer.
- c. A typed conditions list now — the most general and the most
  unexercised; also the hardest to validate meaningfully.
- Other: (your call)

### 3. What is the policy channel?

**Resolved: a, with a recorded follow-up.** The attach-only
three-channel surface ships v1; policy *creation* is expected sooner
rather than later — see [Follow-ups](#follow-ups) item 2.

- **a. (Recommended)** Mirror `eks/pod-identity-access` verbatim:
  `managed_policy_arns` + `customer_managed_policy_arns` +
  `inline_policies` (map, name → JSON). One fleet-wide way to
  express role policies; no standalone `aws_iam_policy` creation in
  v1 (policy lifecycle — sharing across roles, versioning — is a
  different concern that belongs to a future `iam/policy` sibling if
  ever needed).
- b. Also create customer-managed policies in-module (a `policies`
  map of name → JSON that mints `aws_iam_policy` + attaches) —
  one-stop call sites, but a policy shared by two roles then has an
  ambiguous owner, and deleting a role-with-policies cascades
  differently than the attach-only surface.
- Other: (your call)

### 4. Where does deploy-role adoption happen?

**Resolved: a.** Live-repo work; this repo ships the runbook + the
import-feasibility probe as recorded evidence.

- **a. (Recommended)** The live repo. This repo ships the module +
  the README adoption runbook (import blocks, match-reality-first);
  the actual `import` of each account's existing deploy role is
  live-repo work against live state, per the INV-0011 sequencing
  note. The Community apply suite adds a FINDINGS **probe** of
  import-in-`terraform test` feasibility (fixture-created role +
  `import` block) as recorded evidence for the runbook — a stretch,
  not a gate.
- b. Gate the module on an in-repo zero-diff import proof (apply
  suite creates a role out-of-band, imports it through the module,
  asserts an empty follow-up plan) — highest confidence, but it
  couples the release to `terraform test` import mechanics and
  duplicates what each live-repo adoption will prove anyway.
- Other: (your call)

## References

- **INV-0011** — the queue revision (2026-08-28) condensing the IAM
  pair into this module; the sequencing note's cleanly-importable
  tier; F1 (the platform §4 distillation).
- Platform DESIGN-0001 §4 (external, cited by ID) — argocd-deployer →
  `sse-platform-access` → deploy RBAC group; the deploy-role path;
  the reserved `<account>/<region>/iam/<role>` state key.
- **DESIGN-0024 / IMPL-0020** — the access-entries module (the
  cluster-side half of the platform-access pattern; the
  stable-creator principal the deploy-role example names).
- **DESIGN-0004 / IMPL-0004** — `eks/pod-identity-access`: the
  policy-channel surface this module reuses verbatim.
- **ADR-0020** — the remote-state key contract; gains the `iam`
  producer row.
- **INV-0004** — the create-or-adopt / brownfield import-first
  doctrine the adoption runbook implements.
- **IMPL-0015** — Q6a (producer modules and the six globals); the
  Phase 1 LocalStack STS finding the apply suite's caveat cites.
