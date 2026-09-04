---
id: IMPL-0023
title: "Generic security group module"
status: Draft
author: Donald Gifford
created: 2026-09-04
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0023: Generic security group module

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
  - [1. What mechanism enforces the world-open guard?](#1-what-mechanism-enforces-the-world-open-guard)
  - [2. Does egress get the world-open guard too?](#2-does-egress-get-the-world-open-guard-too)
- [References](#references)
<!--toc:end-->

## Objective

Implement DESIGN-0026: `modules/network/security-group` — the
standalone ingress-allowlist SG producer with standard outputs.
Typed granular rules keyed by logical name (CIDR / prefix-list /
referenced-SG, one resource per rule — the fleet's `eks/cluster`
idiom productized), **live** prefix-list references (the counterpart
to the EKS endpoint fence's plan-time expansion), `name_prefix` +
create-before-destroy, a visible all-egress default, and the
fail-closed world-open guard. First consumer: the per-Gateway-class
frontend SGs (GitHub webhook prefix lists, corp CIDRs under the
hairpin posture).

**Implements:** DESIGN-0026 (all five OQs resolved 2026-08-29 — 1a
[standard vpc remote-state read; joins the ADR-0020 consumer
table], 2a [`name_prefix` + CBD, friendly `Name` tag], 3a
[`allow_all_egress = true` default + typed `egress_rules` map], 4a
[world-open guard + explicit `allow_world_open_ingress` override],
5a [the `sg` shape row lands in ADR-0020 at IMPL time]).

## Scope

### In Scope

- `modules/network/security-group` (NEW, sibling to `vpc-lookup`):
  SG + granular rule maps + posture toggles + guards, the vpc
  remote-state read, plan suite, Community apply on the shared
  reference-vpc fixture + a real prefix list, FINDINGS.md.
- README: the scope guardrail, the `gateway-frontend-public` worked
  example, the adoption runbook, the fence cross-link pair, the key
  contract section, the world-open boundary note.
- ADR-0020: the vpc consumer row + the NEW `sg` shape row;
  CLAUDE.md `network/` section; INV-0011 delivery note; minor
  release.

### Out of Scope

The design's Non-Goals:

- SGs for resource-owning modules (cluster/node/RDS/EFS SGs stay in
  their modules — this module must never become the fleet's
  SG-of-everything).
- Backend rules — the AWS Load Balancer Controller owns backend and
  node-SG rules.
- Prefix-list management — a future `network/prefix-list` sibling;
  this module consumes IDs only.
- Kubernetes objects (Gateway/Ingress annotations) — chart-side,
  live-repo values.
- Egress policy enforcement beyond the OQ 3a posture.
- Actually importing the manually-built hub SGs — live-repo work;
  this repo ships the runbook.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all
its tasks are checked off and its success criteria are met.

---

### Phase 1: Module core and plan suite

#### Tasks

- [ ] 1.1 Scaffold `modules/network/security-group` per the
      design's layout (`main.tf`, `data.tf`, `variables.tf`,
      `outputs.tf`, `versions.tf`, `.tflint.hcl`, README/USAGE
      stubs, `tests/`, `tests-localstack/`). `versions.tf`: aws
      `~> 6.2`; `required_version` per OQ 1's resolution (the
      world-open guard mechanism decides the floor).
- [ ] 1.2 `data.tf`: the standard vpc remote-state read —
      `vpc_name` + the six Terragrunt globals compose the
      account-scoped ADR-0020 vpc key with the standard
      `assume_role` block (`role_arn` from
      `account_id`/`deploy_role_name`, `session_name =
      "Deploy-Tf"`, `region = remote_state_bucket_region`);
      `vpc_id` read at the use site (ADR-0001 — no aliasing
      locals).
- [ ] 1.3 `main.tf`: `aws_security_group.this` — `name_prefix =
      "${var.name}-"`, `create_before_destroy = true`, `Name` tag
      = `var.name`, `description` defaulting from `var.name` with
      the ForceNew note in the variable description (name and
      description are create-time; CBD + prefix makes the rare
      replacement survivable — the README records what it does not
      fix: a new SG id still needs the chart-side value update).
- [ ] 1.4 The rules surface: `ingress_rules` + `egress_rules` typed
      maps (the design's object spec verbatim — required
      `description`, `from_port`, optional `to_port` null-collapsing
      to `from_port`, `ip_protocol` default `"tcp"`, the four
      exclusive source fields) driving
      `aws_vpc_security_group_ingress_rule` / `_egress_rule`
      `for_each` by logical key; `allow_all_egress = true` default
      emitting one granular all-egress rule (byte-for-byte the
      `eks/cluster` `nodes_all` shape — the provider revokes AWS's
      default egress at create, so the default keeps ALB health
      checks working and the posture visible in every plan).
- [ ] 1.5 Guards, all fail-closed at plan: **exactly-one-source**
      (zero or two-plus of the four source fields rejected, all
      four named in the message); **description non-empty** (the
      allowlist is an audit surface); **ports-with-`-1`** rejection
      (the API rejects ports with all-protocols); the **world-open
      guard** — `0.0.0.0/0` / `::/0` in any ingress rule fails
      unless `allow_world_open_ingress = true` — mechanism per
      OQ 1. The guard's boundary is deliberate: it inspects the
      literal CIDR fields only; a prefix list containing
      `0.0.0.0/0` is invisible **by design** (the reference is
      live — plan-time expansion would give false assurance), so
      the boundary is documented (task 2.2), not closed.
- [ ] 1.6 `outputs.tf`: `security_group_id` (the operator's stated
      point), `security_group_arn`, `security_group_name` (the
      physical suffixed name), and `ingress_rule_ids` /
      `egress_rule_ids` maps (logical name → `sgr-…` id — the
      adoption and ops surface).
- [ ] 1.7 Plan suite (`tests/`; `override_data` stubs the vpc read
      with the full nine-key contract — the IMPL-0014 Phase 4
      convention): a Gateway-shaped rule map pinning per-rule
      attributes and stable addresses across **all four source
      types**; `to_port` null-collapse + protocol behavior; the
      `expect_failures` set — zero sources, two sources, empty
      description, ports with `-1`, the world-open rejection — plus
      the explicit-toggle **pass** run; the egress posture runs
      (default all-egress rule present; `allow_all_egress = false`
      + typed egress map); the ADR-0020 composed-key assertion; the
      `name_prefix` + CBD pin.
- [ ] 1.8 Per-rule verification of every `expect_failures` run
      (message-probe or mutation, per the CLAUDE.md recipe) —
      four-plus guards stack on the one `ingress_rules` variable,
      and a passing run proves only that the variable errored.
- [ ] 1.9 `just tf all network/security-group`; conventional
      commit.

#### Success Criteria

- The Gateway-shaped run pins all four source types with stable
  per-rule addresses; removals never churn siblings.
- Every guard proven to fail on its own rule.
- The default plan shows the all-egress rule explicitly; the
  restricted run shows none.
- `just static` green with the new module included.

---

### Phase 2: README

#### Tasks

- [ ] 2.1 The scope guardrail **up top**: frontend-style standalone
      SGs only — resource-owning modules keep their own SGs, the
      LBC keeps backend + node-SG rules.
- [ ] 2.2 The `gateway-frontend-public` worked example: 443 from
      the GitHub-webhooks prefix list with the **live-reference
      callout** (edits propagate without an apply — the contrast
      with the EKS fence's plan-time expansion stated explicitly)
      and the **world-open boundary note** beside it (prefix-list
      contents are the list owner's audit surface — the guard
      cannot and does not look inside); 443 from the corp egress
      CIDRs with the hairpin note; the consumption path (SG id →
      LBC frontend-SG annotation through live-repo chart values;
      backend stays the controller's).
- [ ] 2.3 The adoption runbook: piecewise imports (the SG by
      `sg-…` id, each rule by `sgr-…` id, into the module's named
      addresses); match-reality-first, converge second; rule
      descriptions update in place but a source/port change
      **replaces** that one rule — sequence adds before removes
      when tightening on a live ALB SG.
- [ ] 2.4 The fence cross-link pair: this README points at the
      `eks/cluster` fence README's plan-time warning; the cluster
      side already points here ("the live version of this
      pattern") — close the loop.
- [ ] 2.5 The remote-state key contract section: the `sg` shape
      (`<account_name>/<region>/sg/<name>/terraform.tfstate`),
      triple coupling, foreseeable consumers (cross-stack
      `referenced_security_group_id`, `eks/cluster` additional
      SGs).
- [ ] 2.6 `just tf docs network/security-group`; conventional
      commit.

#### Success Criteria

- The worked example is a complete call site with all three
  callouts (live reference, world-open boundary, hairpin).
- The runbook covers both import shapes and the tightening
  sequence.
- `just static` green.

---

### Phase 3: Community apply

Pure EC2 API — token-free Community 4.4, no Pro, no named volume
(the `vpc-lookup` precedent).

#### Tasks

- [ ] 3.1 Fixture: `run "setup"` sources the shared
      `test/fixtures/reference-vpc` (DESIGN-0016 — consumer apply
      tests never hand-roll VPCs; the ~1–2 min NAT cost is the
      accepted price) and creates a small populated
      `aws_ec2_managed_prefix_list` so a live prefix-list rule
      round-trips.
- [ ] 3.2 Apply suite: the SG lands in the contract VPC; CIDR +
      prefix-list + referenced-SG rules round-trip; the all-egress
      rule exists.
- [ ] 3.3 Run live (`just tf test-localstack
      network/security-group`, `SERVICES=ec2,sts`); FINDINGS.md
      records parity per the assert-what-round-trips discipline —
      including whether token-free 4.4 serves managed prefix lists
      at all (the fleet has proved prefix-list `entries` only under
      the **Pro** container, in the eks/cluster fence fixture; this
      is the first Community-tier probe of that surface).
- [ ] 3.4 Conventional commit.

#### Success Criteria

- Live Community apply green (or any 4.4 parity gap recorded in
  FINDINGS.md with the suite narrowed to what round-trips).
- FINDINGS.md records the emulator version and the prefix-list
  parity answer.

---

### Phase 4: Closure

#### Tasks

- [ ] 4.1 ADR-0020: join the vpc **consumer** table (the seventh
      vpc consumer) and add the NEW **`sg` shape row** (OQ 5a — a
      producer publishing into an undocumented shape is a CI
      failure, so the row is the only honest option).
- [ ] 4.2 CLAUDE.md: the `modules/network/` section gains the
      module (idiom, guards, the world-open boundary, the
      live-vs-plan-time contrast); INV-0011 delivery note (F1
      batch 4 generalized and delivered).
- [ ] 4.3 `just readme` — the module table row (the separate
      `readme-check` CI job); `docz update` + the mangle-set
      restore; `just docs lint`.
- [ ] 4.4 PR labeled `minor`; `### RELEASE NOTES` names the module
      and the world-open guard posture.

#### Success Criteria

- Both ADR-0020 rows present; CLAUDE.md + module table current;
  all doc gates green; release tagged.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/network/security-group/{main,data,variables,outputs,versions}.tf` | Create | the module |
| `modules/network/security-group/{.tflint.hcl,README.md,USAGE.md}` | Create | lint config + docs |
| `modules/network/security-group/tests/` | Create | plan suite (the gate) |
| `modules/network/security-group/tests-localstack/` | Create | Community apply + prefix-list fixture + FINDINGS.md |
| `docs/adr/0020-*.md` | Modify | vpc consumer row + `sg` shape row |
| `CLAUDE.md` | Modify | `network/` section |
| `docs/investigation/` (INV-0011) | Modify | delivery note |

## Testing Plan

The design's Testing Strategy is the authority. Fleet mechanics:

- Plan suite stubs the vpc read with the full nine-key
  `override_data` contract (IMPL-0014 Phase 4 convention) and pins
  the composed ADR-0020 key.
- Per-rule `expect_failures` verification carried as task 1.8.
- Community apply sources the shared reference-vpc fixture via
  `run "setup"`; token-free 4.4, `SERVICES=ec2,sts` — no token is
  ever wired into the Community tier.
- New module → `scripts/changed-modules.sh` picks it up
  automatically; verify with `just changed`.

## Dependencies

- `test/fixtures/reference-vpc` (exists, DESIGN-0016/IMPL-0014) —
  the apply fixture substrate.
- The vpc remote-state contract (exists — `vpc-lookup` /
  reference-vpc publish it); in any live buildout the vpc stack
  precedes SG stacks.
- None on IMPL-0021 / IMPL-0022 — parallel work.
- The hub buildout does **not** wait on it: SGs are built manually
  now and adopted later via the Phase 2 runbook (the INV-0011
  sequencing tier).

## Open Questions

### 1. What mechanism enforces the world-open guard?

The guard reads **two** variables — a rule in `ingress_rules` plus
the `allow_world_open_ingress` toggle — and a `validation` block
may reference other variables only on Terraform **>= 1.9**. The
fleet floor is `>= 1.1` almost everywhere, with a `>= 1.11`
precedent in two modules (`secretsmanager/secret`,
`ecr/pull-through-cache`). The other three guards are
single-variable and sit at validation regardless; this OQ decides
only the world-open guard's home and the module's floor.

- **a. (Recommended)** Cross-variable validation on
  `ingress_rules` + `required_version = ">= 1.9"`. The error lands
  on the variable the caller is editing and can name the offending
  rule keys in one message; it fires at the earliest possible gate
  (before any plan graph), and all five guards live in one place
  (`variables.tf`) instead of splitting across validation and
  resource preconditions. A 1.9 floor is unremarkable beside the
  fleet's existing 1.11 modules, and every environment that runs
  the fleet already satisfies it.
- b. A precondition on `aws_vpc_security_group_ingress_rule.this`,
  keeping `required_version = ">= 1.1"`. Works on every fleet
  Terraform, but the error attaches to a planned resource address
  instead of the input the caller wrote, fires once per world-open
  rule instead of once with all keys named, and splits the guard
  set across two mechanisms.
- Other: (your call)

### 2. Does egress get the world-open guard too?

The typed `egress_rules` map accepts the same CIDR fields, so
`0.0.0.0/0` can appear there when `allow_all_egress = false`.

- **a. (Recommended)** No — ingress only. World egress **is** the
  module's default posture (`allow_all_egress = true` emits
  exactly that rule), so guarding the typed map against a shape
  the default already grants would be incoherent: a
  restricted-egress caller writing `0.0.0.0/0` has simply
  re-created the default they turned off, visibly, in a reviewed
  plan. The guard exists for ingress blast radius — the
  pasted-wide-open classic the design names.
- b. A symmetric guard on `egress_rules` (active only when
  `allow_all_egress = false`) — catches a contradiction between
  "restricted egress" intent and a world-open entry, at the cost
  of a second toggle or an asymmetric override story.
- Other: (your call)

## References

- **DESIGN-0026** — the parent design (all five OQs resolved; the
  2026-09-01 amendments: the world-open boundary blockquote, the
  verification-discipline requirement).
- **INV-0011** — F1 batch 4 (the Gateway frontend-SG proposal:
  prefix-list webhooks, hairpin posture, LBC keeps backend); the
  2026-08-28 queue revision; the sequencing note's import-later
  tier.
- **DESIGN-0024 / IMPL-0020** — the EKS endpoint fence (the
  plan-time counterpart; the cross-link pair; the guard-boundary
  lesson — a guard testing raw inputs while the resolved value
  differs, here left open by design); the per-rule verification
  recipe.
- **`eks/cluster` `security_group.tf`** — the granular-rule idiom
  and the `nodes_all` all-egress shape this module productizes.
- **ADR-0020** — the key contract: the vpc consumer row joined,
  the `sg` shape row added.
- **DESIGN-0016 / IMPL-0014** — the shared reference-vpc fixture.
- **INV-0004** — the create-or-adopt doctrine; the `network/`
  sibling-room convention.
