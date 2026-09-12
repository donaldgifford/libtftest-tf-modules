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
- [Phase 1 deviation from DESIGN-0026: `from_port` is optional](#phase-1-deviation-from-design-0026-from_port-is-optional)
- [Phase 1 guard verification (task 1.8)](#phase-1-guard-verification-task-18)
  - [The two runs that are passes, not rejections](#the-two-runs-that-are-passes-not-rejections)
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

- [x] 1.1 Scaffold `modules/network/security-group` per the
      design's layout (`main.tf`, `data.tf`, `variables.tf`,
      `outputs.tf`, `versions.tf`, `.tflint.hcl`, README/USAGE
      stubs, `tests/`, `tests-localstack/`). `versions.tf`: aws
      `~> 6.2`; `required_version = ">= 1.9"` (OQ 1a — the
      world-open guard is a cross-variable validation, a TF 1.9
      feature; the fleet's first 1.9 floor, beside the two
      existing 1.11 modules. Do not "simplify" it down: the guard
      silently stops compiling below 1.9).
- [x] 1.2 `data.tf`: the standard vpc remote-state read —
      `vpc_name` + the six Terragrunt globals compose the
      account-scoped ADR-0020 vpc key with the standard
      `assume_role` block (`role_arn` from
      `account_id`/`deploy_role_name`, `session_name =
      "Deploy-Tf"`, `region = remote_state_bucket_region`);
      `vpc_id` read at the use site (ADR-0001 — no aliasing
      locals).
- [x] 1.3 `main.tf`: `aws_security_group.this` — `name_prefix =
      "${var.name}-"`, `create_before_destroy = true`, `Name` tag
      = `var.name`, `description` defaulting from `var.name` with
      the ForceNew note in the variable description (name and
      description are create-time; CBD + prefix makes the rare
      replacement survivable — the README records what it does not
      fix: a new SG id still needs the chart-side value update).
- [x] 1.4 The rules surface: `ingress_rules` + `egress_rules` typed
      maps (required `description`, **`from_port` optional — see the
      deviation below**, optional `to_port` null-collapsing
      to `from_port`, `ip_protocol` default `"tcp"`, the four
      exclusive source fields) driving
      `aws_vpc_security_group_ingress_rule` / `_egress_rule`
      `for_each` by logical key; `allow_all_egress = true` default
      emitting one granular all-egress rule (byte-for-byte the
      `eks/cluster` `nodes_all` shape — the provider revokes AWS's
      default egress at create, so the default keeps ALB health
      checks working and the posture visible in every plan).
- [x] 1.5 Guards, all fail-closed at plan: **exactly-one-source**
      (zero or two-plus of the four source fields rejected, all
      four named in the message); **description non-empty** (the
      allowlist is an audit surface); **ports-with-`-1`** rejection
      (the API rejects ports with all-protocols); the **world-open
      guard** — `0.0.0.0/0` / `::/0` in any ingress rule fails
      unless `allow_world_open_ingress = true` — implemented as a
      cross-variable validation on `ingress_rules` naming the
      offending rule keys in its message (OQ 1a; the reason for
      the module's `>= 1.9` floor). The guard's boundary is
      deliberate: it inspects the
      literal CIDR fields only; a prefix list containing
      `0.0.0.0/0` is invisible **by design** (the reference is
      live — plan-time expansion would give false assurance), so
      the boundary is documented (task 2.2), not closed.
- [x] 1.6 `outputs.tf`: `security_group_id` (the operator's stated
      point), `security_group_arn`, `security_group_name` (the
      physical suffixed name), and `ingress_rule_ids` /
      `egress_rule_ids` maps (logical name → `sgr-…` id — the
      adoption and ops surface).
- [x] 1.7 Plan suite (`tests/`; `override_data` stubs the vpc read
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
- [x] 1.8 Per-rule verification of every `expect_failures` run
      (message-probe or mutation, per the CLAUDE.md recipe) —
      four-plus guards stack on the one `ingress_rules` variable,
      and a passing run proves only that the variable errored.
- [x] 1.9 `just tf all network/security-group`; conventional
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

- [x] 2.1 The scope guardrail **up top**: frontend-style standalone
      SGs only — resource-owning modules keep their own SGs, the
      LBC keeps backend + node-SG rules.
- [x] 2.2 The `gateway-frontend-public` worked example: 443 from
      the GitHub-webhooks prefix list with the **live-reference
      callout** (edits propagate without an apply — the contrast
      with the EKS fence's plan-time expansion stated explicitly)
      and the **world-open boundary note** beside it (prefix-list
      contents are the list owner's audit surface — the guard
      cannot and does not look inside); 443 from the corp egress
      CIDRs with the hairpin note; the consumption path (SG id →
      LBC frontend-SG annotation through live-repo chart values;
      backend stays the controller's).
- [x] 2.3 The adoption runbook: piecewise imports (the SG by
      `sg-…` id, each rule by `sgr-…` id, into the module's named
      addresses); match-reality-first, converge second; rule
      descriptions update in place but a source/port change
      **replaces** that one rule — sequence adds before removes
      when tightening on a live ALB SG.
- [x] 2.4 The fence cross-link pair: this README points at the
      `eks/cluster` fence README's plan-time warning; the cluster
      side already points here ("the live version of this
      pattern") — close the loop.
- [x] 2.5 The remote-state key contract section: the `sg` shape
      (`<account_name>/<region>/sg/<name>/terraform.tfstate`),
      triple coupling, foreseeable consumers (cross-stack
      `referenced_security_group_id`, `eks/cluster` additional
      SGs).
- [x] 2.6 `just tf docs network/security-group`; conventional
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

- [x] 3.1 Fixture: `run "setup"` sources the shared
      `test/fixtures/reference-vpc` (DESIGN-0016 — consumer apply
      tests never hand-roll VPCs; the ~1–2 min NAT cost is the
      accepted price) and creates a small populated
      `aws_ec2_managed_prefix_list` so a live prefix-list rule
      round-trips.
- [x] 3.2 Apply suite: the SG lands in the contract VPC; CIDR +
      prefix-list + referenced-SG rules round-trip; the all-egress
      rule exists.
- [x] 3.3 Run live (`just tf test-localstack
      network/security-group`, `SERVICES=ec2,sts`); FINDINGS.md
      records parity per the assert-what-round-trips discipline —
      including whether token-free 4.4 serves managed prefix lists
      at all (the fleet has proved prefix-list `entries` only under
      the **Pro** container, in the eks/cluster fence fixture; this
      is the first Community-tier probe of that surface).
- [x] 3.4 Conventional commit.

#### Success Criteria

- Live Community apply green (or any 4.4 parity gap recorded in
  FINDINGS.md with the suite narrowed to what round-trips).
- FINDINGS.md records the emulator version and the prefix-list
  parity answer.

---

### Phase 4: Closure

#### Tasks

- [x] 4.1 ADR-0020: join the vpc **consumer** table (the seventh
      vpc consumer) and add the NEW **`sg` shape row** (OQ 5a — a
      producer publishing into an undocumented shape is a CI
      failure, so the row is the only honest option).
- [x] 4.2 CLAUDE.md: the `modules/network/` section gains the
      module (idiom, guards, the world-open boundary, the
      live-vs-plan-time contrast); INV-0011 delivery note (F1
      batch 4 generalized and delivered).
- [x] 4.3 `just readme` — the module table row (the separate
      `readme-check` CI job); `docz update` + the mangle-set
      restore; `just docs lint`.
- [x] 4.4 PR labeled `minor`; `### RELEASE NOTES` names the module
      and the world-open guard posture.

#### Success Criteria

- Both ADR-0020 rows present; CLAUDE.md + module table current;
  all doc gates green; release tagged.

---

## Phase 1 deviation from DESIGN-0026: `from_port` is optional

The design's object spec (Detailed Design → The rules surface) writes
`from_port = number` — **required** — while the same section also
requires that `ip_protocol = "-1"` "requires no ports (validated — the
API rejects ports with all-protocols)."

**Those two cannot both hold.** A required `from_port` means every rule
carries a port, so an all-protocols rule would always trip the
ports-with-`-1` rejection and `"-1"` would be unrepresentable.

Checked against the fleet before deviating: **every** `"-1"` rule in
`eks/cluster`, `rds/cluster` and `rds/serverless` omits ports — and this
module's own `allow_all_egress` default emits exactly that shape, so the
design would have made the module's default posture illegal under its
own guard.

Resolution: `from_port` is `optional(number)`, and the coherence moves
into validation — ports **required** for tcp/udp, **rejected** for
`"-1"`. The guard the design asked for is fully present; only the type
that made it self-contradictory changed. Pinned by
`all_protocols_rule_omits_ports` and `tcp_rule_without_a_port_rejected`,
so reverting the deviation turns one of them red.

## Phase 1 guard verification (task 1.8)

`expect_failures` asserts that the named object errored — **never which
rule fired**. Four validations stack on `var.ingress_rules` alone, so
every rejection run could in principle pass off a neighbouring rule and
look identically green.

All ten rejection runs were therefore **message-probed in isolation**
(one scratch single-run file each, no `expect_failures`, the real error
read). Isolation matters: a failing run *skips* its siblings, so a
combined probe file reports only the first failure.

| Run | Rule that fired | `variables.tf` |
|---|---|---|
| `malformed_name_rejected` | name charset/length | 9 |
| `caller_supplied_name_tag_rejected` | tags must not set `Name` | 28 |
| `ingress_rule_with_no_source_rejected` | exactly-one-source | 78 |
| `ingress_rule_with_two_sources_rejected` | exactly-one-source | 78 |
| `ingress_rule_with_blank_description_rejected` | description non-empty | 86 |
| `ports_with_all_protocols_rejected` | port coherence | 91 |
| `tcp_rule_without_a_port_rejected` | port coherence | 91 |
| `world_open_ipv4_rejected` | world-open guard | 114 |
| `world_open_ipv6_rejected` | world-open guard | 114 |
| `egress_rule_with_two_destinations_rejected` | egress exactly-one-source | **154** |

Seven distinct rules across seven distinct lines, each naming **only**
its own offending map keys — the three-rule world-open probe listed
`public, six` and correctly excluded the legitimate corp rule.

Line 154 is load-bearing on its own: it proves the egress guards
reference `var.egress_rules` and are not a copy-paste of the ingress
ones, which is a defect a green suite would otherwise hide entirely.

> Line numbers above are **as of Phase 1**. The security review below
> grew the suite to 22 rejections and moved every rule; all 22 were
> re-probed in isolation against the shipped `variables.tf`, and that
> pass is what caught `unknown_ip_protocol_rejected` firing two rules.
> Re-probing after changing validations is not optional — the earlier
> table is evidence about the code as it stood, not a standing result.

### The two runs that are passes, not rejections

**`world_open_permitted_by_explicit_toggle`.** The world-open guard is
the cross-variable validation that sets the module's `>= 1.9` floor, and
a fail-case-only probe cannot distinguish a working cross-variable
reference from a rule that rejects *everything* — both satisfy
`expect_failures` identically. This is the same trap as IMPL-0024's RE2
bounded-repeat bug, where `can()` swallowed an invalid pattern into a
rule that would have rejected every value. The toggled-ON run passing is
what proves the `>= 1.9` mechanism actually resolves on this Terraform
rather than being assumed from the design.

**`world_open_egress_is_permitted_by_design`.** Egress deliberately has
no world-open guard (DESIGN-0026 OQ 2a). Pinned as a pass so that adding
a symmetric guard later is a deliberate, visible change rather than a
silent tightening.

The `name` regex is likewise proven to *discriminate* rather than reject
everything: every other run in the suite passes a valid name through it.

## Adversarial security review (pre-merge, `iac-security`)

Run against the as-built module before PR #116 merged. Both HIGH
findings were **independently reproduced before being fixed** — the
standing discipline, and in both cases the reproduction is what turned a
plausible-sounding claim into a defect with a regression run.

### HIGH-1 — the world-open guard was evaded by IPv6 spelling

The guard compared strings: `r.cidr_ipv6 != "::/0"`. IPv6 has many legal
spellings of the world, and the provider's CIDR validator accepts them
all. A scratch `.tftest.hcl` confirmed that **both** `0::/0` and
`0000:0000:0000:0000:0000:0000:0000:0000/0` planned **clean** with
`allow_world_open_ingress` at its `false` default. This is upstream
provider issue #15982 reproduced inside our own guard.

Fixed by testing the **suffix** instead:
`!endswith(coalesce(r.cidr_ipv4, r.cidr_ipv6, "unset/32"), "/0")`. `/0`
is the only prefix length whose literal text ends in `/0`, so the test
is exact across every spelling and both address families. The v4 side
was safe only by luck — the provider's network-address validator leaves
`0.0.0.0/0` as the sole accepted v4 `/0` spelling.

Regressions: `world_open_ipv6_compressed_zero_rejected` and
`world_open_ipv6_expanded_rejected`. The pre-existing `::/0` run was
**not** evidence of anything about the other spellings, which is the
reusable point: a fail-case run proves the rule rejects *that input*,
never that it rejects the class.

### HIGH-2 — the module's own default description could not apply

`description` defaulted to a string containing **U+2014 EM DASH**
(`hexdump`: `e2 80 94`). The EC2 `GroupDescription` charset is ASCII
only — `a-z A-Z 0-9`, spaces and `._-:/()#,@[]+=&;{}!$*` — so **every
invocation that did not override the default would have failed at
apply** against real AWS, after the create call.

Neither gate could catch it. The constraint is server-side, so no plan
sees it; and **LocalStack does not enforce AWS string-charset
constraints**, so the apply suite created the group happily and read the
em dash back byte-identical. The suite had *pinned the broken value as
expected*.

Fixed with charset validations on `var.description` and on both rule
maps' descriptions (rule descriptions are narrower — no `&`), plus the
em dashes removed from every AWS-submitted string in the module and its
suites. Regressions: `non_ascii_description_rejected`,
`non_ascii_rule_description_rejected`, and a FINDINGS.md NEGATIVE
recording the emulator gap.

**The lesson generalizes past this module:** an emulator proves shape
and wiring, never a provider's server-side string contracts. Charset,
length and format constraints must be validated at plan or they are not
validated at all — and a green apply tier is *actively misleading*
about them.

### MEDIUM findings fixed

| Finding | Fix | Regression |
|---|---|---|
| ICMP `to_port` collapsed to `from_port`, so `{ from_port = 8, ip_protocol = "icmp" }` read as "allow ping" and planned type 8 / **code 8** — echo requests carry code 0, so it matched nothing | three-way port coherence: tcp/udp require `from_port`; icmp/icmpv6 require **both** (type and code); everything else must have neither | `icmp_rule_without_explicit_code_rejected` **plus** `icmp_rule_with_explicit_code_accepted` — without the positive, the rejection would be satisfied by a rule that rejects all ICMP |
| `to_port < from_port` accepted (an inverted range) | `to_port >= from_port`, ICMP-exempt since there the pair is type/code, not a range | `inverted_port_range_rejected` |
| `ip_protocol` unvalidated — a typo like `"https"` reached the API | enum of `tcp`/`udp`/`icmp`/`icmpv6`/`-1` or a number 0-255 | `unknown_ip_protocol_rejected` |
| `allow_all_egress` + non-empty `egress_rules` was documented as "additive" — a silent widening, since the all-egress rule is wider than anything a restricting caller writes and appears in the plan only as an **unchanged** resource | rejected at plan | `additive_egress_posture_rejected` (a converted pass — the run that used to assert the additive behavior) |
| a caller rule keyed `all-egress` collides with the module's own `Name = "<name>-all-egress"` tag | key reserved | `reserved_all_egress_key_rejected` |
| typed egress rules' `tags` were asserted nowhere — a mutation dropping the attribute left the whole suite green | Name-tag assertion in `restricted_egress_replaces_the_default` | (that run) |
| four "sets X and nothing else" assertions checked **one** of the three other source fields | all three | (`rules.tftest.hcl`) |

### The probe caught a defect in the new tests themselves

Re-probing the additions found `unknown_ip_protocol_rejected` firing
**two** rules — the protocol enum it names *and* the port-coherence rule,
because the input carried a `from_port` and an unknown protocol must
have none. `expect_failures` cannot distinguish them. The run now omits
the port, leaving the enum as the only rule that input can violate.

This is the discipline paying for itself in the same session that
needed it: adding validations to a variable that already carried several
is exactly how `egress_rule_with_two_destinations_rejected` silently
started passing off the **new** coherence guard (fixed by pinning
`allow_all_egress = false` in every egress rejection run).

### Documented, not fixed — the guard's honest scope

The README claimed the guard means the SG cannot admit the world without
the toggle. That is false at the `/1` boundary: `0.0.0.0/1` plus
`128.0.0.0/1` is the entire IPv4 space in two rules, neither a `/0`.
Catching it means unioning CIDR arithmetic across the whole map, and any
threshold chosen there rejects legitimate large allowlists. A caller who
writes two half-internet rules has not slipped, so this is documented as
a known limit alongside the prefix-list hole — the module guards against
the **accident**, and says so.

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

> **All resolved 2026-09-04: 1a, 2a.** The world-open guard is a
> cross-variable validation on `ingress_rules` referencing
> `allow_world_open_ingress`, and the module ships with
> `required_version = ">= 1.9"` — the fleet's first 1.9 floor
> (tasks 1.1 and 1.5 updated). Egress carries no guard: world
> egress is the default posture. No other task edits follow.

### 1. What mechanism enforces the world-open guard?

**Resolved: a.** Cross-variable validation on `ingress_rules` +
`required_version = ">= 1.9"`.

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

**Resolved: a.** No — ingress only; world egress is the module's
default posture.

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
