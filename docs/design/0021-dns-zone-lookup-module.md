---
id: DESIGN-0021
title: "DNS zone lookup module"
status: Draft
author: Donald Gifford
created: 2026-08-27
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0021: DNS zone lookup module

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
  - [Module layout](#module-layout)
  - [Discovery mechanics](#discovery-mechanics)
  - [Variable surface](#variable-surface)
  - [Outputs](#outputs)
  - [Remote-state key contract](#remote-state-key-contract)
  - [Split-horizon pairs](#split-horizon-pairs)
  - [The external-dns worked example](#the-external-dns-worked-example)
  - [CI mechanics](#ci-mechanics)
- [Testing Strategy](#testing-strategy)
- [Phases](#phases)
  - [Phase 1: Module core and plan suite](#phase-1-module-core-and-plan-suite)
  - [Phase 2: LocalStack Community apply suite](#phase-2-localstack-community-apply-suite)
  - [Phase 3: Contract and doc closure](#phase-3-contract-and-doc-closure)
- [Open Questions](#open-questions)
  - [1. What are the discovery inputs?](#1-what-are-the-discovery-inputs)
  - [2. Does the producer carry a state-key name input?](#2-does-the-producer-carry-a-state-key-name-input)
  - [3. Is private-zone VPC scoping in v1?](#3-is-private-zone-vpc-scoping-in-v1)
  - [4. How deep does the worked example go?](#4-how-deep-does-the-worked-example-go)
- [References](#references)
<!--toc:end-->

## Overview

`modules/dns/zone-lookup` is the fleet's Route53 zone **producer**: a
zero-resource, data-source-only module that discovers an **existing**
hosted zone and publishes its facts as the remote-state contract other
modules compose — the same role `network/vpc-lookup` plays for the
network. It ships **first** in the `dns/` family (INV-0011 OQ 3,
re-confirmed against the platform rollup: "for dns we need the dns
lookup first"); the create-mode sibling `modules/dns/zone` (platform
zone + per-account delegation) follows as its own DESIGN when
spoke-substrate work starts.

The first named consumer is the external-dns pod identity: an
`eks/pod-identity-access` caller composes a Route53 change-records
grant from this module's `zone_arn`/`zone_id` outputs read via remote
state (the DESIGN-0002 `external_dns_zone_ids` heritage, finally served).

## Goals and Non-Goals

### Goals

- Discover one existing hosted zone (public or private) and publish a
  small, stable output contract: `zone_id` + `zone_arn` (INV-0011
  OQ 5a), plus additive facts (`zone_name`, `name_servers`,
  `private_zone`).
- Establish the ADR-0020 `dns` state shape
  (`<account_name>/<region>/dns/<name>/terraform.tfstate`) — the same
  `dns/<zone>` key the platform's DESIGN-0001 reserves from the
  consumer side.
- Support split-horizon pairs (public + internal zones sharing one
  domain name) as **two stacks**, one zone per instance (INV-0011
  OQ 3a).
- Zero resources, zero opinions: the module never owns DNS — it
  permanently serves environments where Terraform must not own the
  zone, and stands in for `dns/zone` until that module exists
  (the INV-0004 ship-the-read-only-adapter-first doctrine).
- Community-tier LocalStack apply proof (Route53 needs no Pro).

### Non-Goals

- **Creating anything.** No zones, no records, no delegation — that is
  `modules/dns/zone` (queued, its own DESIGN). Record management
  belongs to external-dns in-cluster per the platform rule; even the
  create-mode sibling will own no record resources.
- **Multi-zone maps.** One zone per instance (INV-0011 OQ 3a);
  consumers needing N zones read N states.
- **The external-dns IAM policy itself.** The module publishes
  pointers; the policy JSON is caller-composed through
  `eks/pod-identity-access`'s `inline_policies` channel (worked
  example below). No policy-fragment outputs — a lookup producer does
  not author IAM.
- **ACM validation, health checks, resolver rules** — out of scope;
  `acm/certificate` is parked separately (INV-0011 F1 batch 4).

## Background

INV-0011 concluded (F2/F3 + OQ 3/4/5, all resolved):

- `network/vpc-lookup` is the donor pattern and transfers nearly 1:1:
  zero-resource producer, discovery-by-name with an explicit-ID
  override that collapses the name path, sorted outputs for
  determinism, a two-output stable contract plus additive facts,
  published at an ADR-0020 key the consumers compose (F3).
- The pinned provider (6.58.0 under `~> 6.2`) ships everything needed:
  `data.aws_route53_zone` takes `name`, `zone_id`, `private_zone`,
  `vpc_id`, `tags` and returns `arn`, `zone_id`, `name`,
  `name_servers`, `private_zone` (F2). The plural
  `data.aws_route53_zones` returns ids only — useless for facts,
  unused here.
- Route53 wrinkles vs the VPC case (F3): zones are **global**, but the
  ADR-0020 key still embeds `<region>` (the deploying stack's
  Terragrunt folder region — path and state segment are independent,
  INV-0004); private zones need `private_zone = true` to disambiguate
  split-horizon pairs; there is no subnet-tier analog, so this module
  is substantially smaller than vpc-lookup.
- The platform context (INV-0011 F1): the hub baseline runs
  external-dns "serving both our internal DNS and external DNS"
  (split-horizon confirmed), and the platform's DESIGN-0001 reserves
  the `<account>/<region>/dns/<zone>` state key — the consumer side of
  exactly the shape this module produces under.

Prior art: INV-0004 (contract-first, ship-read-only-first, path vs
segment independence), ADR-0020 (the key contract the `dns` shape
joins), DESIGN-0004 / ADR-0002 (`eks/pod-identity-access` and its
`inline_policies = map(string)` JSON channel — the consumer seam).

## Detailed Design

### Module layout

```text
modules/dns/zone-lookup/
├── main.tf              # the single data source + XOR precondition
├── locals.tf            # discovery-arg collapsing (donor pattern)
├── outputs.tf           # contract + additive facts
├── variables.tf
├── versions.tf          # aws ~> 6.2; no write-only args, no 1.11 floor
├── .tflint.hcl
├── README.md            # + "Remote-state key contract" section
├── USAGE.md
├── tests/               # plan suite (the gate)
└── tests-localstack/    # Community apply suite + FINDINGS.md
```

The new `modules/dns/` service directory mirrors `network/`
(`vpc-lookup` beside the future `vpc`): `zone-lookup` beside the
future `zone`.

### Discovery mechanics

One `data "aws_route53_zone" "this"` with the donor's collapse
pattern — an explicit `zone_id` override wins and nulls out the
name-path arguments (mirroring vpc-lookup's `vpc_id`-collapses-tags
move):

```hcl
data "aws_route53_zone" "this" {
  zone_id      = var.zone_id
  name         = var.zone_id != null ? null : var.zone_name
  private_zone = var.zone_id != null ? null : var.private_zone
  vpc_id       = var.zone_id != null ? null : var.vpc_id

  lifecycle {
    precondition {
      condition     = (var.zone_id != null) != (var.zone_name != null)
      error_message = "Exactly one of zone_id or zone_name must be set: zone_name discovers by domain (+ private_zone / vpc_id); zone_id bypasses discovery."
    }
  }
}
```

Notes:

- vpc-lookup carries no preconditions at all (INV-0011 F3); this
  module needs exactly one, and with zero resources it hangs on the
  data source's `lifecycle` block (data sources accept preconditions).
  XOR (not "at least one") because both-set is ambiguous about which
  wins and should fail loudly rather than silently prefer the id.
- `private_zone = false` (the default) discovers the public zone of a
  split-horizon pair; `true` selects the private one. `vpc_id`
  narrows a private-zone match further (OQ 3).
- Trailing-dot tolerance: the data source accepts `zone_name` with or
  without the trailing dot; the provider returns the canonical
  dotted form. Outputs normalize (below) so consumers never see the
  dot.

### Variable surface

- `zone_name` (string, default `null`) — the domain to discover
  (e.g. `internal.example.com`). Charset validation: a permissive
  DNS-name regex (lowercase labels, dots, hyphens; trailing dot
  tolerated).
- `private_zone` (bool, default `false`) — select the private zone of
  a same-name pair. Only meaningful with `zone_name` (collapsed under
  `zone_id`, matching the donor's ignored-when-overridden semantics).
- `vpc_id` (string, default `null`) — optional private-zone
  disambiguator (OQ 3).
- `zone_id` (string, default `null`) — explicit override, XOR with
  `zone_name`.

Terragrunt globals: none — like vpc-lookup, the module reads no
remote state, so it declares none of the six shared globals (the
var-file's pass-every-input design tolerates that silently, Q6a).

Deliberately absent: a `name`/logical-name input. See OQ 2 — the
state-key identity is carried by the live-repo folder, not by a
producer variable, because the domain name and the folder name
genuinely differ here (split-horizon pairs share the domain).

### Outputs

Contract (INV-0011 OQ 5a — stable, consumers may depend on these):

```text
zone_id    — hosted zone ID (external-dns zone filters, TXT-registry args)
zone_arn   — arn:aws:route53:::hostedzone/<id> (IAM resource scoping)
```

Additive facts (renameable pre-1.0, same doctrine as vpc-lookup):

```text
zone_name     — the zone's domain, normalized without the trailing dot
name_servers  — sorted NS set (delegation wiring for the future dns/zone)
private_zone  — bool, which half of a split-horizon pair this is
```

All values derive from the data source's attributes; `name_servers`
is `sort()`ed for plan determinism (the donor's rule). `zone_name` is
`trimsuffix(data.aws_route53_zone.this.name, ".")`.

### Remote-state key contract

ADR-0020 gains the `dns` shape (INV-0011 OQ 4a; the generic segment —
room for non-Route53 DNS producers later):

```text
<account_name>/<region>/dns/<name>/terraform.tfstate
```

- `<region>` is the deploying stack's Terragrunt folder region — the
  zone itself is global; the key records where the lookup stack
  lives, the same convention any global-ish producer uses (INV-0004:
  path and segment are independent).
- `<name>` is the live-repo **folder** name (e.g. `internal`,
  `public`), NOT the domain name — see OQ 2 for the coupling shape.
- Consumers compose the key with the standard six Terragrunt globals
  and `assume_role` block, exactly like every other ADR-0020 read;
  the platform's DESIGN-0001 already reserves this shape from its
  side.

### Split-horizon pairs

One zone per instance (INV-0011 OQ 3a) makes split-horizon two
stacks:

```text
live/<account>/<region>/dns/public/     -> zone-lookup { zone_name = "example.com" }
live/<account>/<region>/dns/internal/   -> zone-lookup { zone_name = "example.com", private_zone = true }
```

Both discover the same domain; `private_zone` picks the half. The
folder names (`public` / `internal`) are the `<name>` key segments
consumers target. external-dns's two sides read the state matching
their side.

### The external-dns worked example

The consumer seam is `eks/pod-identity-access`'s
`inline_policies = map(string)` channel (DESIGN-0004 / IMPL-0001 Q3).
The caller — a live-repo pod-identity stack — reads the zone state
and composes the grant; nothing changes in either module:

```hcl
data "terraform_remote_state" "dns_internal" {
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = "${var.account_name}/${var.region}/dns/internal/terraform.tfstate"
    region = var.remote_state_bucket_region
    assume_role = {
      role_arn     = "arn:aws:iam::${var.account_id}:role/${var.deploy_role_name}"
      session_name = "Deploy-Tf"
    }
  }
}

# inline_policies entry on the external-dns identity:
external-dns = jsonencode({
  Version = "2012-10-17"
  Statement = [
    {
      Effect   = "Allow"
      Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
      Resource = data.terraform_remote_state.dns_internal.outputs.zone_arn
    },
    {
      Effect   = "Allow"
      Action   = ["route53:ListHostedZones", "route53:ListHostedZonesByName"]
      Resource = "*"
    },
  ]
})
```

The unscoped `ListHostedZones` pair is the external-dns operational
minimum (list is not resource-scopable); the change/read grant is
scoped to exactly the composed zone ARN. Where this example lives and
how far the test suites prove it is OQ 4.

### CI mechanics

Nothing bespoke: `scripts/changed-modules.sh` discovers leaf modules
by `*.tf` presence and derives tiers from test-directory existence,
so the new `dns/` service enters the plan matrix and Community apply
tier automatically. Phase 1 verifies with `just changed` from a
seeded diff rather than assuming it (the DESIGN-0020 discipline). The
internal-module fan-out logic is s3-specific and unaffected.

## Testing Strategy

Both tiers follow vpc-lookup's recipe (INV-0011 F3: it transfers
unchanged).

**Plan suite (`tests/`, the gate).** `mock_provider` +
`override_data` — no credentials, no network:

- Name-mode discovery: override the data source, assert all five
  outputs wire through (including `zone_name` dot-normalization and
  `name_servers` sorting).
- ID-mode: `zone_id` set, name args collapsed (assert the data
  source's `name` argument is null via the plan).
- XOR guard: both set and neither set each fail the precondition
  (`expect_failures`).
- Private-zone flag passthrough.

**Community apply suite (`tests-localstack/`).** Token-free
`localstack/localstack:4.4`, `SERVICES=route53,ec2,sts` (ec2 only for
the private-zone fixture's VPC):

- Fixture creates a public zone and a same-name private zone
  (associated to a fixture VPC), then the module discovers each:
  public by name, private by name + `private_zone = true`, and one
  by explicit `zone_id`.
- Assert the discovered `zone_id`s match the fixture's, `zone_arn`
  composes correctly, `private_zone` reports faithfully.
- FINDINGS.md records LocalStack parity notes (expected: Route53
  zone CRUD is solid in Community; private-zone VPC association
  fidelity is the probe-worthy edge).

No Pro tier: nothing here needs it.

## Phases

### Phase 1: Module core and plan suite

- [ ] Scaffold `modules/dns/zone-lookup` (versions.tf aws `~> 6.2`,
      `.tflint.hcl`, README skeleton)
- [ ] Data source + collapse locals + XOR precondition + validations
- [ ] Outputs (contract pair + additive facts, sorted/normalized)
- [ ] Plan suite per Testing Strategy
- [ ] `just changed` verification; `just tf docs`; conventional commit

Success criteria: `just tf validate|fmt|lint|test dns/zone-lookup`
green; `just static` green repo-wide.

### Phase 2: LocalStack Community apply suite

- [ ] Fixture (public + private pair, fixture VPC) and apply runs
- [ ] FINDINGS.md parity notes
- [ ] Run live against token-free 4.4 — suite passing

Success criteria: `just tf test-localstack dns/zone-lookup` green
against a live Community container.

### Phase 3: Contract and doc closure

- [ ] ADR-0020: add the `dns` shape row (+ the external-dns
      pod-identity consumer row per OQ 4's resolution)
- [ ] README "Remote-state key contract" section (folder-name
      coupling, split-horizon pairs, the worked example)
- [ ] CLAUDE.md: new `modules/dns/` section (lookup-first posture,
      the `dns/zone` sibling reservation)
- [ ] INV-0011: mark the dns leg delivered; `docz update` (+ restore
      the known TOC-mangle set)
- [ ] Conventional commits; PR labeled `minor` (new module)

Success criteria: `just static` + plan matrix green in CI; ADR-0020
and the module README agree on the key shape verbatim.

## Open Questions

> **All resolved 2026-08-27: 1a, 2a, 3a, 4a.** The Detailed Design
> above is already written to the recommended shapes — no amendments.

### 1. What are the discovery inputs?

- **a. (Recommended)** `zone_name` + `private_zone` (+ optional
  `vpc_id`, OQ 3) as the discovery path, with an explicit `zone_id`
  override that collapses the name arguments — the vpc-lookup donor
  pattern exactly (tag-vs-id becomes name-vs-id), XOR-guarded by a
  data-source precondition. Name-first matches how operators think
  about zones; the id override serves brownfield oddities (duplicate
  same-name zones from legacy imports).
- b. `zone_id` only — smallest surface and no ambiguity ever, but
  every live-repo folder must hard-code an opaque id, and
  split-horizon readability ("which half is this?") lives only in
  comments.
- c. Tag-based discovery (`tags` on the data source) mirroring
  vpc-lookup's `tag:Name` filter — but zones are rarely tagged
  today, and the domain name is already the natural unique-ish
  discriminator; tags add an adoption prerequisite for zero gain.
- Other: (your call)

### 2. Does the producer carry a state-key name input?

vpc-lookup's `var.name` does double duty: the `tag:Name` filter AND
the documented ADR-0020 `<name>` segment (three-legged coupling:
producer input == live-repo folder == consumer input). Here the
discovery input is the **domain name**, which cannot be the key
segment — split-horizon pairs share the domain, and folder names are
`public`/`internal` (INV-0011 OQ 3a resolution).

- **a. (Recommended)** No producer-side name input: the coupling for
  this producer is **two-legged** (live-repo folder == consumer
  input), documented prominently in the README's key-contract
  section. Nothing in the module would consume a logical name — a
  variable that exists only to be documentation invites drift from
  the real folder name it claims to mirror.
- b. A documentation-only `name` input preserving the three-legged
  shape for fleet uniformity (every producer declares its identity),
  emitted as an output so consumer suites can assert it. Uniform, but
  it is an unenforced echo — the actual key still comes from the
  folder, and a stale value would be misinformation with a green
  plan.
- Other: (your call)

### 3. Is private-zone VPC scoping in v1?

- **a. (Recommended)** Yes — optional `vpc_id` (default null, passed
  through only on the name path). It is one argument, it serves the
  real case of multiple private zones sharing a name across VPC
  associations, and the private-zone fixture exercises it nearly for
  free.
- b. Defer — `private_zone` alone disambiguates the common pair;
  add `vpc_id` when a consumer hits the multi-association case.
  Smaller v1, but retrofitting costs a release for one argument the
  data source already supports.
- Other: (your call)

### 4. How deep does the worked example go?

- **a. (Recommended)** README worked example (the composed
  remote-state read + `inline_policies` JSON above) plus an ADR-0020
  consumer-row entry; the **live** end-to-end proof (zone-lookup
  state → pod-identity-access apply) rides the external-dns
  pod-identity stack's suite when that wiring lands, not this
  module's. This module's apply suite proves discovery; the
  composition is the consumer's contract to prove — the same split
  every other producer/consumer pair uses (reference-vpc proves
  seeding, consumers prove reading).
- b. Add a composing apply fixture now: seed this module's state to
  the shared bucket, apply a real `eks/pod-identity-access` with the
  composed external-dns policy against LocalStack. Strongest proof,
  but it duplicates the consumer-side suite that must exist anyway
  and couples this module's CI to the eks module's fixtures.
- Other: (your call)

## References

- **INV-0011** — the parent investigation
  (`docs/investigation/0011-platform-hub-module-gaps-across-network-s3-secretsmanager-and.md`):
  F2 (provider probe), F3 (donor-pattern transfer), OQ 3/4/5
  resolutions (one zone per instance at `modules/dns/zone-lookup`,
  the `dns` segment, the two-output contract), F1 batches 3–4 (the
  platform rollup's `dns/zone` sibling and the reserved
  `dns/<zone>` key).
- INV-0004 — the lookup-module doctrine (contract-first,
  ship-read-only-first, path vs segment independence).
- ADR-0020 — remote-state key contract; gains the `dns` shape in
  Phase 3.
- DESIGN-0004 / IMPL-0004 / ADR-0002 — `eks/pod-identity-access`, the
  `inline_policies` JSON channel, and the external-dns future-consumer
  row this design serves.
- DESIGN-0002 — the abandoned `external_dns_zone_ids` heritage
  (IMPL-0001 Q3 moved the concern to the pod-identity domain).
- Platform DESIGN-0001 + IMPL-0001 (external, distilled in INV-0011
  F1 batches 3–4) — the hub baseline's external-dns
  ("both our internal DNS and external DNS") and the reserved
  `<account>/<region>/dns/<zone>` state key.
- `modules/network/vpc-lookup` — the donor module.
- `modules/dns/zone` — the queued create-mode sibling (own DESIGN
  when spoke-substrate work starts; INV-0011 Recommendation).
