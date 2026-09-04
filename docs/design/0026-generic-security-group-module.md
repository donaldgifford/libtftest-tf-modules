---
id: DESIGN-0026
title: "Generic security group module"
status: Draft
author: Donald Gifford
created: 2026-08-28
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0026: Generic security group module

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
  - [Module layout and VPC resolution](#module-layout-and-vpc-resolution)
  - [The security group resource](#the-security-group-resource)
  - [The rules surface](#the-rules-surface)
  - [Egress posture](#egress-posture)
  - [Guards](#guards)
  - [The Gateway frontend worked example](#the-gateway-frontend-worked-example)
  - [Adoption](#adoption)
  - [Outputs and state shape](#outputs-and-state-shape)
- [Testing Strategy](#testing-strategy)
- [Phases](#phases)
- [Open Questions](#open-questions)
  - [1. How is the VPC resolved?](#1-how-is-the-vpc-resolved)
  - [2. What is the naming and replacement posture?](#2-what-is-the-naming-and-replacement-posture)
  - [3. What is the egress posture?](#3-what-is-the-egress-posture)
  - [4. Is world-open ingress guarded?](#4-is-world-open-ingress-guarded)
  - [5. Does the state shape get reserved now?](#5-does-the-state-shape-get-reserved-now)
- [References](#references)
<!--toc:end-->

## Overview

`modules/network/security-group` — the generalization of the Gateway
frontend security-group proposal (INV-0011 F1 batch 4, generalized by
the queue revision 2026-08-28): a **standalone ingress-allowlist SG
producer with standard outputs** — per the operator, "we are just
setting standard outputs we want instead of lookups." Typed granular
rules (CIDR / prefix-list / referenced-SG, one resource per rule),
**live** prefix-list references (the counterpart to DESIGN-0024's
plan-time endpoint fence), and a hard scope guardrail: frontend-style
standalone SGs only — resource-owning modules keep their own SGs and
the AWS Load Balancer Controller keeps backend + node-SG rules. First
consumer: the per-Gateway-class frontend SGs (webhook prefix lists
such as GitHub, corp CIDRs under the hairpin posture).

## Goals and Non-Goals

### Goals

- Declarative frontend SGs whose **rule content is the product**:
  webhook source lists, corp ranges, and partner CIDRs churn — the
  module's value is reviewed, plan-diffed allowlist changes with
  per-rule lifecycle (this is what makes it pass the ACM
  "terraform for terraform's sake" test that parked
  `acm/certificate`).
- **Live prefix-list rules:** an SG rule referencing
  `prefix_list_id` tracks the list — edits propagate without a
  Terraform apply. The README states the contrast with the EKS
  fence's plan-time expansion explicitly (DESIGN-0024 promised this
  module as "the live version of this pattern").
- Standard outputs (`security_group_id` first) so chart-side
  consumers (the LBC frontend-SG annotation, fed through live-repo
  values) and future TF consumers take the id without lookups.
- Stable rule addresses: `for_each` over typed maps keyed by logical
  rule names — adding one webhook source never churns a sibling
  rule.
- Replacement-safe under a live ALB attachment (OQ 2) and
  brownfield-adoptable: the manually-created hub SGs import
  piecewise (SG + each rule individually), per the INV-0011
  sequencing note.

### Non-Goals

- **SGs for resource-owning modules** — the cluster/node SGs, RDS
  SGs, and EFS mount-target SGs stay in their modules (the scope
  guardrail; this module must never become the fleet's
  SG-of-everything).
- **Backend rules** — the AWS Load Balancer Controller owns backend
  and node-SG rules; it is closest to the source that defines them
  (operator direction, INV-0011 F1 batch 4).
- **Prefix-list management** — the module consumes prefix-list IDs;
  creating/maintaining `aws_ec2_managed_prefix_list` entries is a
  future `network/prefix-list` sibling if ever.
- Kubernetes objects (Gateway/Ingress annotations carrying the SG
  id) — chart-side, live-repo values.
- Egress *policy enforcement* beyond the chosen v1 posture (OQ 3).

## Background

- **The operator proposal (INV-0011 F1 batch 4):** frontend-only
  ingress-allowlist SGs per Gateway class. Webhook sources (e.g.
  GitHub) arrive as prefix lists; the **hairpin posture** is
  accepted — corp traffic egresses the corp network and re-enters
  through the public ALB's ingress rule, so the corp public egress
  IPs belong in the allowlist.
- **The fleet's SG idiom is already granular** (the module
  productizes it): `eks/cluster`'s `security_group.tf` uses
  `aws_vpc_security_group_ingress_rule` / `_egress_rule` — one rule
  per resource, "no full-SG churn on a single-rule edit," per-rule
  tags and descriptions. Never inline blocks (mixing inline and
  granular rules is the known drift pathology).
- **Provider mechanics that shape the design:** (1)
  `aws_security_group` **revokes AWS's default allow-all egress at
  create** — egress must be declared or the SG has none, which
  silently breaks ALB → target and health-check traffic (why
  `eks/cluster` declares its explicit `nodes_all` egress rule; why
  OQ 3's default exists). (2) SG `name` and `description` are
  **create-time** (ForceNew) — the replacement posture (OQ 2)
  matters because a destroy-first replacement of an attached SG
  deadlocks on `DependencyViolation` and a fixed name collides with
  its successor.
- The queue revision (INV-0011, 2026-08-28) generalized the Gateway
  module into this one; the sequencing note put it on the
  build-manually-now, adopt-later tier.

## Detailed Design

### Module layout and VPC resolution

```text
modules/network/security-group/
├── main.tf              # SG + ingress/egress rule for_each
├── data.tf              # data.terraform_remote_state.vpc (OQ 1)
├── variables.tf         # name, rules maps, posture toggles, globals
├── outputs.tf
├── versions.tf
├── .tflint.hcl
├── README.md            # scope guardrail + worked example + contract
├── USAGE.md
├── tests/               # plan suite (the gate)
└── tests-localstack/    # Community apply + FINDINGS.md
```

Sibling to `network/vpc-lookup` (the `network/` room note). VPC
resolution per OQ 1: the standard remote-state read — `vpc_name` +
the six Terragrunt globals compose
`<account_name>/<region>/vpc/<vpc_name>/terraform.tfstate` with the
standard `assume_role` block, `vpc_id` read at the use site
(ADR-0001); the module joins the ADR-0020 consumer table beside the
six existing vpc consumers.

### The security group resource

Per OQ 2 (recommended shape): `name_prefix = "${var.name}-"` with
`create_before_destroy = true` — the SG idiom for ForceNew-heavy
resources. Replacements are rare (rules are granular; only
name/description/vpc changes force one), but when one happens the
successor is created before the predecessor's delete, and the prefix
guarantees no name collision. The `Name` tag carries the friendly
`var.name`; `description` defaults from `var.name` with the ForceNew
note in its variable description. The README is honest about the
limit: a replacement still mints a new SG id, so chart-side
attachments need their value update regardless — CBD removes the
deadlock and the collision, not the id change.

### The rules surface

```hcl
variable "ingress_rules" {
  description = "Ingress allowlist, keyed by logical rule name (stable addresses). Each rule names exactly ONE source: cidr_ipv4 | cidr_ipv6 | prefix_list_id | referenced_security_group_id. prefix_list_id rules are LIVE references — list edits propagate without an apply (unlike the EKS endpoint fence's plan-time expansion). description is required: every allowlist entry says why it exists."
  type = map(object({
    description                  = string
    from_port                    = number
    to_port                      = optional(number) # null → from_port
    ip_protocol                  = optional(string, "tcp")
    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    prefix_list_id               = optional(string)
    referenced_security_group_id = optional(string)
  }))
  default = {}
}
```

- `for_each` over the map →
  `aws_vpc_security_group_ingress_rule.this[<logical name>]` — the
  fleet's typed-map convention (`read-replica` replicas, DESIGN-0024
  access entries): plan diffs read as named intentions, removals
  never churn siblings.
- **Exactly-one-source validation** — the granular-rule API's own
  constraint, failed at plan with the four source fields named.
- `description` non-empty validation — the allowlist is an audit
  surface.
- `to_port` null-collapses to `from_port`; `ip_protocol = "-1"`
  requires no ports (validated — the API rejects ports with
  all-protocols).

### Egress posture

Per OQ 3 (recommended shape): `allow_all_egress = true` (default)
emits one granular all-egress rule — byte-for-byte the
`eks/cluster` `nodes_all` shape — plus an additive typed
`egress_rules` map (same object type as ingress) for restricted
setups. The default exists because the provider revokes AWS's
default egress at create: a silent no-egress SG breaks the primary
use case (ALB health checks and target traffic) in the worst
discovery mode. The all-egress rule is explicit in every plan — the
posture is visible, not implied.

### Guards

- **Exactly-one-source** and **description-required** (above), plus
  the ports-with-protocol-`-1` rejection.
- **World-open guard (OQ 4):** any ingress rule whose source is
  `0.0.0.0/0` or `::/0` fails validation unless
  `allow_world_open_ingress = true` — fail-closed against the
  pasted-wide-open classic; a deliberately public frontend is one
  explicit, reviewable line away.
- No at-least-one-rule floor: an SG with an empty allowlist is
  useless but harmless (a legitimate bring-up intermediate).

> **The world-open guard's boundary (post-IMPL-0020 review,
> 2026-09-01).** The guard inspects the literal `cidr_ipv4` /
> `cidr_ipv6` fields only. A `prefix_list_id` source whose list
> contains `0.0.0.0/0` admits the world and the module cannot see
> it — **by design**: the reference is live, so a plan-time
> expansion of the list would give false assurance (the list can be
> edited to world-open a minute after the apply, which is exactly
> what "live" means). This is the shape of IMPL-0020's HIGH fence
> finding — a guard testing raw inputs while the resolved value
> differs — with the difference that here resolution is impossible
> on purpose, so the boundary is **documented instead of closed**:
> prefix-list contents are the list owner's audit surface, and the
> README states this beside the worked example's GitHub-webhook
> list. (`referenced_security_group_id` sources have no equivalent
> hole — an SG reference admits that SG's members, never the world.)

### The Gateway frontend worked example

The README's full call site, `gateway-frontend-public`:

- `443` from `prefix_list_id = <github-webhooks list>` (a
  customer-maintained prefix list — its lifecycle is outside this
  module, see Non-Goals) — the live-reference callout sits here.
- `443` from the corp egress CIDRs — with the hairpin note: corp
  traffic exits the corp network and re-enters through this rule on
  the public ALB (the accepted-cost posture from the operator
  discussion).
- Consumption: the SG id flows to the LBC frontend-SG annotation
  through live-repo chart values; with a caller-provided frontend
  SG, the LBC manages backend rules referencing it — backend stays
  the controller's (Non-Goals).
- The cross-link pair: this README points at the `eks/cluster` fence
  README's plan-time warning, and the fence callout already points
  here for "the live version of this pattern."

### Adoption

Import blocks in the live repo, piecewise: the SG by `sg-…` id, each
rule by `sgr-…` id, into the module's named addresses.
**Import-and-match-reality first, converge conventions second** —
rule descriptions update in place; a source/port change **replaces**
that one rule (a brief window on a live ALB SG — sequence adds
before removes when tightening). Same runbook shape as
DESIGN-0025's, recorded in the README.

### Outputs and state shape

- `security_group_id` — the standard output (the operator's stated
  point), plus `security_group_arn`, `security_group_name` (the
  physical, suffixed name), and `ingress_rule_ids` /
  `egress_rule_ids` maps (logical name → `sgr-…` id; the adoption
  and ops surface).
- Per OQ 5: the ADR-0020 shape table gains **`sg`** —
  `<account_name>/<region>/sg/<name>/terraform.tfstate`, `<name>`
  triple-coupled as usual. First foreseeable TF consumer: a sibling
  SG stack's `referenced_security_group_id` taken cross-stack, or an
  `eks/cluster` additional-SG input; chart-side consumers keep
  taking the id through live-repo values either way.

## Testing Strategy

- **Plan suite (`tests/`, the gate):** `override_data` stubs the vpc
  read with the full nine-key contract (the IMPL-0014 Phase 4
  convention). Runs: a Gateway-shaped rule map pinning per-rule
  attributes and stable addresses (all four source types, incl. a
  referenced-SG rule); the null-collapse (`to_port`) and protocol
  behaviors; `expect_failures` for exactly-one-source (zero and two
  sources), empty description, ports-with-`-1`, and the world-open
  guard (plus its explicit-toggle pass run); the egress posture
  runs (default all-egress rule present; `allow_all_egress = false`
  + typed egress map); the ADR-0020 composed-key assertion; the
  `name_prefix` + CBD pin. **Verification discipline
  (post-IMPL-0020 review, 2026-09-01):** four-plus guards stack on
  the one `ingress_rules` variable, so a passing `expect_failures`
  run proves only that the variable errored, not that the intended
  guard fired — the IMPL doc carries per-rule verification
  (message-probe or mutation, per the CLAUDE.md recipe) as an
  explicit task.
- **Community apply (`tests-localstack/`):** pure EC2 API — real
  apply against token-free 4.4 (`SERVICES=ec2,sts`), no Pro, no
  named volume (the `vpc-lookup` precedent). The fixture sources the
  shared `test/fixtures/reference-vpc` via `run "setup"` (DESIGN-0016
  — consumer apply tests never hand-roll VPCs; the ~1–2 min NAT cost
  is the accepted price) and creates a small
  `aws_ec2_managed_prefix_list` so a live prefix-list rule
  round-trips. Asserts: SG lands in the contract VPC; CIDR +
  prefix-list + referenced-SG rules round-trip; the all-egress rule
  exists. FINDINGS.md records any 4.4 parity gaps
  (assert-what-round-trips discipline).

## Phases

Design-level sketch; the IMPL doc (post-review) carries the task
breakdown:

1. Module core + plan suite (SG, rule maps, posture toggles,
   guards, key assertion).
2. README: scope guardrail up top, the Gateway worked example, the
   adoption runbook, the fence cross-link pair, the key contract.
3. Community apply on reference-vpc + prefix-list fixture +
   FINDINGS.md.
4. Closure: ADR-0020 consumer row + `sg` shape row, CLAUDE.md
   `network/` update, INV-0011 delivery note, minor release.

## Open Questions

> **All resolved 2026-08-29: 1a, 2a, 3a, 4a, 5a.** The Detailed
> Design above is written to the resolved shapes.

### 1. How is the VPC resolved?

**Resolved: a.** The standard remote-state read; the module joins
the ADR-0020 vpc consumer table.

- **a. (Recommended)** The standard remote-state read: `vpc_name` +
  the six globals → the ADR-0020 vpc key with `assume_role`, exactly
  like the six existing vpc consumers. Every planned SG lives in a
  contract VPC (reference-vpc / vpc-lookup precede SGs in every
  buildout order), and state is the fleet's ground truth for
  cross-module facts.
- b. A raw `vpc_id` input only — the simplest module, but it breaks
  the ground-truth-through-state doctrine and pushes a lookup burden
  onto every caller.
- c. The tri-state (default read, explicit `vpc_id` override
  count-gates the data source away — the `s3/bucket` F4 precedent) —
  flexibility without a driver: the bucket's tri-state solved a
  bootstrapping-order problem SGs do not have.
- Other: (your call)

### 2. What is the naming and replacement posture?

**Resolved: a.** `name_prefix` + create-before-destroy; friendly
name on the `Name` tag.

- **a. (Recommended)** `name_prefix = "${var.name}-"` +
  `create_before_destroy = true`, friendly name on the `Name` tag.
  SG name and description are create-time; with a fixed name a
  forced replacement destroy-first deadlocks on the attached SG
  (`DependencyViolation`) and CBD is impossible (name collision).
  Prefix + CBD makes the rare replacement survivable; the README
  records what it does not fix (a new SG id still needs the
  chart-side value update).
- b. Exact `name` — a predictable physical name (console
  friendliness, marginally simpler adoption), bought with the
  replacement deadlock. The `secretsmanager/secret` precedent went
  prefix for the same class of reason (reserved names there,
  collision here).
- Other: (your call)

### 3. What is the egress posture?

**Resolved: a.** Visible all-egress default rule + the additive
typed `egress_rules` map.

- **a. (Recommended)** `allow_all_egress = true` default (one
  explicit granular all-egress rule — the `eks/cluster` `nodes_all`
  shape) + an additive typed `egress_rules` map. The provider
  revokes AWS's default egress at create, so a surface-less module
  would ship SGs that silently fail health checks; the default makes
  the primary case work and the rule is visible in every plan.
- b. Fail-closed: no default egress, every caller declares it —
  strictest, but the frontend use case always needs
  egress-to-targets, and the failure mode of forgetting (ALB targets
  unreachable) is discovered live, not at plan.
- c. Ingress-only v1 with egress hard-coded all-allow (no
  `egress_rules` surface) — smallest surface, but restricted-egress
  callers are locked out until a module change, for the cost of one
  typed map now.
- Other: (your call)

### 4. Is world-open ingress guarded?

**Resolved: a.** Fail-closed with the explicit
`allow_world_open_ingress` override.

- **a. (Recommended)** Yes, fail-closed with an explicit override:
  `0.0.0.0/0` / `::/0` in any ingress rule fails validation unless
  `allow_world_open_ingress = true`. Catches the pasted-wide-open
  classic at plan (the exact class of mistake the fleet's guardrails
  exist for), while a deliberately public frontend stays one
  reviewable line away.
- b. No guard — allowlist content is caller policy; but this module
  IS the allowlist product, and its highest-blast-radius
  misconfiguration deserves a plan-time gate.
- c. Hard deny — but public-facing frontends are a legitimate
  primary use; a hard deny forks the module the first time one
  ships.
- Other: (your call)

### 5. Does the state shape get reserved now?

**Resolved: a.** The `sg` shape row lands in ADR-0020 at IMPL time.

- **a. (Recommended)** Yes — the ADR-0020 shape table gains `sg`
  (`<account_name>/<region>/sg/<name>`) at IMPL time. The producer
  publishes its outputs into stack state regardless; the row is a
  one-line reservation that documents the folder convention, and
  ADR-0020's grep gate treats a new module inventing an undocumented
  shape as a CI failure — so the real alternative to reserving is
  publishing into an undocumented shape, not publishing nothing.
  First TF consumer is foreseeable (cross-stack
  `referenced_security_group_id`; `eks/cluster` additional SGs).
- b. Defer the row until a TF consumer is wired (the ACM
  "terraform for terraform's sake" caution) — but the caution's
  target is building *modules* without consumers, not documenting a
  key a producer already publishes; deferring just leaves the shape
  informal.
- Other: (your call)

## References

- **INV-0011** — F1 batch 4 (the operator's Gateway frontend-SG
  proposal: prefix-list webhooks, hairpin posture, LBC keeps
  backend); the queue revision (2026-08-28) generalizing it here;
  the sequencing note's import-later tier.
- **DESIGN-0024 / IMPL-0020** — the EKS endpoint fence: the
  plan-time-expansion counterpart whose README callout promises this
  module as the live version; the cross-link pair.
- **`eks/cluster` `security_group.tf`** — the granular-rule idiom
  and the explicit all-egress precedent this module productizes.
- **ADR-0020** — the remote-state key contract: the vpc consumer row
  this module joins and the `sg` shape row it adds (OQ 5).
- **DESIGN-0016 / IMPL-0014** — the shared `reference-vpc` fixture
  the apply suite sources.
- **INV-0004** — vpc-lookup and the create-or-adopt doctrine; the
  `network/` sibling-room convention.
- Platform DESIGN-0001 (external, cited by ID) — the Gateway classes
  and the frontend/backend division of labor with the LBC.
