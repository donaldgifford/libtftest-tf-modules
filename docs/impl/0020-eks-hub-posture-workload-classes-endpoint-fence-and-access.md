---
id: IMPL-0020
title: "EKS hub posture workload classes endpoint fence and access entries"
status: In Progress
author: Donald Gifford
created: 2026-08-28
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0020: EKS hub posture workload classes endpoint fence and access entries

**Status:** In Progress
**Author:** Donald Gifford
**Date:** 2026-08-28

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Sequencing gates and buildout order](#sequencing-gates-and-buildout-order)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Node group workload classes](#phase-1-node-group-workload-classes)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: gVisor toggle and user-data assertions](#phase-2-gvisor-toggle-and-user-data-assertions)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Cluster fence and bootstrap contract](#phase-3-cluster-fence-and-bootstrap-contract)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: The access entries module](#phase-4-the-access-entries-module)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: LocalStack applies and closure](#phase-5-localstack-applies-and-closure)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [1. What is the PR and release cadence?](#1-what-is-the-pr-and-release-cadence)
  - [2. How is rendered user data asserted?](#2-how-is-rendered-user-data-asserted)
  - [3. What shape is the access entries apply fixture?](#3-what-shape-is-the-access-entries-apply-fixture)
  - [4. What if Community lacks access entry parity?](#4-what-if-community-lacks-access-entry-parity)
- [References](#references)
<!--toc:end-->

## Objective

Implement the hub cluster posture across the eks module family — the
five-class `workload_class` parameterization of `managed-node-group`
(with the gVisor toggle and the fleet's first user-data assertions),
the `eks/cluster` endpoint fence plus the explicit bootstrap-creator
contract and additive `sso_principal_arn` output, and the NEW
`modules/eks/access-entries` module (the fourth eks-state consumer) —
in **hub-unblock order**: the node-group phases land first because they
are the one piece of this work the management-cluster buildout cannot
start without (see the gates below).

**Implements:** DESIGN-0024 (all six OQs resolved 2026-08-27 — 1a
[`analytics`], 2a amended [the access-entries surface moves to its own
module], 3a [map-of-maps, flattened association keys], 4 Other
[explicit `true` + the stable-creator operational contract], 5a
[40-CIDR plan guard], 6a [user-data assertions now]), from INV-0011
(F7/F8, OQ 11–13 as amended). These modules carry the platform
ADR-0011 change bar: zero-diff replans and plan-test invariants are
platform policy, not preferences.

## Scope

### In Scope

- `modules/eks/managed-node-group`: the `workload_class` enum (`core`
  default — the deliberate default-behavior change), per-class baked
  label/taint rules, the five F8 hardwired sites threaded together,
  the nullable `gvisor_enabled` override + effective-gVisor coalesce,
  the gated gVisor MIME part, class-derived outputs, the per-class
  plan matrix including rendered user-data assertions.
- `modules/eks/cluster`: the endpoint fence
  (`endpoint_public_access_cidrs` + prefix-list expansion + union →
  `public_access_cidrs`), its three guards, explicit
  `bootstrap_cluster_creator_admin_permissions = true` + the
  stable-creator README contract, and the additive
  `sso_principal_arn` output.
- `modules/eks/access-entries` (NEW): the generic entries map,
  flattened policy associations, validations, the cross-stack SSO
  collision guard, plan suite, Community apply suite + FINDINGS.md.
- LocalStack Community apply extensions for cluster (fence) and
  node group (class-parameterized runs); parity probes recorded.
- Doc closure: READMEs, CLAUDE.md eks section, the ADR-0020 consumer
  row, the INV-0011 delivery note, minor releases with the
  default-change note prominent.

### Out of Scope

- **The evidence bucket and everything DESIGN-0022** — its create-time
  Object Lock gate is *recorded* in the sequencing section below
  because the hub buildout order depends on it, but the S3 work rides
  its own IMPL.
- The subnet-tier rewire (`vpc_config` → `private_eks_subnet_ids`) —
  DESIGN-0015's scope, sequenced independently.
- Live prefix-list fence sync (the out-of-band syncer + ignored-fence
  posture decision) — the recorded follow-up, not a v1 knob;
  conditional `ignore_changes` is infeasible (static lifecycle args).
- Subsuming the SSO singleton into the generic map (rejected,
  INV-0011 OQ 11b) and flipping `endpoint_public_access` to false by
  default (a future major-bump decision if ever).
- Kubernetes-side objects (RuntimeClass, chart nodeSelectors and
  tolerations) — platform-chart-owned, never Terraform's.
- The queued `iam/role` and `network/security-group` DESIGNs and the
  `dns/zone-lookup` IMPL — parallel work, not dependencies (see the
  buildout order below).

## Sequencing gates and buildout order

This IMPL's phase order deliberately **inverts** DESIGN-0024's Phases
sketch (which listed the access-entries module first): the INV-0011
sequencing note (2026-08-28, operator-reviewed) established that the
node-group work is the hub's critical path and nothing else here is.

**Gate 1 — node-group workload classes gate hub day-0; not
deferrable.** A management cluster built on today's
`managed-node-group` gets **every node born secure-tainted**:
`workload-class=secure:NO_SCHEDULE` + gVisor are hardwired, the core
baseline (ArgoCD, ESO, ALB controller) tolerates nothing and expects
untainted `core` nodes — nothing schedules. `additional_labels`
cannot remove the hardwired taint, and tolerating it chart-side puts
the control plane under gVisor, exactly the posture the class split
exists to avoid. Phases 1–2 clear this gate; the **hub-unblock
milestone** is the Phase 2 merge + node-group release tag (OQ 1).
Recovery from building early would be a launch-template bump plus a
rolling node replacement — survivable on a young hub, but pointless
when sequencing the phases first avoids it entirely.

**Gate 2 — create-time Object Lock on the evidence bucket
(DESIGN-0022's scope, recorded here for the buildout order).**
`object_lock_enabled` is create-time: a Loki bucket created now can
never *become* the evidence bucket — that is a new bucket plus a data
copy. Either the S3 core + evidence work lands before the audit
stream matters, or the cutover window is accepted knowingly. The
Thanos/ClickHouse buckets are the opposite case: create with
`s3/bucket` at HEAD today and add tiering later as a pure additive
`lifecycle_rules` change.

**One create-time contract applies immediately, module change or
not:** the bootstrap admin entry binds to whatever principal creates
the hub cluster. The Phase 3 module change (explicit `true` + README
contract) trails the buildout, but the *operational* rule it records
applies at hub creation regardless — create via the stable automation
path (Atlantis pod-identity → per-account deploy role), never an
ad-hoc SSO session whose `AWSReservedSSO_*` suffix rotates. An
SSO-created bootstrap entry is disposable: superseded by the declared
entries stack and deletable out-of-band.

**Fastest buildout order** (closing the loop with INV-0011's
Recommendation): implement Phases 1–2 first — they do not depend on
the cluster-side phases — start the hub substrate + cluster stack
against that node-group tag, and let everything else land behind it
and adopt what was built by hand: Phases 3–5 here, the
`dns/zone-lookup` IMPL (zero-resource — nothing to import, ever; the
pod-identity stacks hardcode the zone ARN today and the later swap to
the remote-state read is a zero-diff plan), the `iam/role` and
`network/security-group` modules (manually-built roles and SGs adopt
via `import` blocks), external SM mode (import just the shell), and
the evidence bucket per Gate 2. This is the fleet's own doctrine:
**brownfield import-first was baked into the create-or-adopt thinking
from INV-0004**, so the trailing modules are designed to receive
exactly what the buildout creates manually.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all
its tasks are checked off and its success criteria are met.

---

### Phase 1: Node group workload classes

The enum and the class threading — F8 sites 1, 2, 3 (class half), and
5 in one change so no half-parameterized state exists. Site
numbering is DESIGN-0024 part 3's.

#### Tasks

- [x] 1.1 `workload_class` variable in
      `modules/eks/managed-node-group/variables.tf`: five-value closed
      enum (`core` / `observability` / `analytics` / `temporal` /
      `secure`), default `"core"`, `nullable = false`, validation
      message naming the platform taxonomy (DESIGN-0024 part 3
      verbatim); per-class rule locals in `locals.tf` (class label
      always; class taint iff `workload_class != "core"`).
- [x] 1.2 Site 1 (labels): `"workload-class" = var.workload_class` in
      the locals label map — always present. (The `runtime` label's
      conditionalization is Phase 2's, with the effective-gVisor
      coalesce it depends on.)
- [x] 1.3 Site 2 (taint block): the static `main.tf` taint becomes a
      `dynamic "taint"` gated on `workload_class != "core"`, emitting
      `workload-class=<class>:NO_SCHEDULE`; `additional_taints`
      layering unchanged.
- [x] 1.4 Site 3, class half (user-data template):
      `templates/user_data.sh.tftpl` gains `workload_class` and
      `taint_enabled` inputs — the kubelet node-label fragment always
      carries `workload-class=<class>`, and
      `--register-with-taints=workload-class=<class>:NoSchedule`
      renders only for tainted classes (kubelet spells it
      `NoSchedule`, the API side stays `NO_SCHEDULE` — the existing
      spelling split, now templated with a why-comment).
- [x] 1.5 Site 5 (outputs + descriptions): `outputs.node_taints`
      derives from the class rule (empty class taint for `core`);
      rewrite the two variable descriptions that bake
      "workload-class=secure" wording class-neutral.
- [x] 1.6 Per-class plan matrix in `tests/`: the **core default** run
      (untainted, no class taint in outputs, labels correct) AND the
      **explicit secure** run pinning today's full label+taint
      posture (the operator-required regression — "needs to be
      dialed"); one run per remaining class; enum rejection via
      `expect_failures`; `additional_taints` / `additional_labels`
      layering per class. Existing runs that pinned the secure
      default are rewritten into the matrix (the pin moves to the
      explicit-secure run).
- [x] 1.7 `just tf all eks/managed-node-group` + `terraform-docs`
      regen (USAGE.md).

#### Success Criteria

- The plan matrix is green; the explicit-secure run asserts the
  label + taint surface exactly as the pre-change hardwired posture;
  the core-default run produces no class taint.
- No literal secure-class strings remain outside the enum validation
  and the per-class locals (grep-verified).
- `just static` green for the module (fmt / validate / tflint /
  docs).
- **Deliberately NOT yet hub-ready:** the gVisor install part is
  still unconditional until Phase 2 — this intermediate is never
  released on its own (OQ 1).

---

### Phase 2: gVisor toggle and user-data assertions

The effective-gVisor rule, the last two threaded sites (1's runtime
label, 4's install part), and the fleet-first user-data assertions —
ending at the hub-unblock milestone.

#### Tasks

- [x] 2.1 `gvisor_enabled` nullable bool variable (default `null`) +
      `local.gvisor_effective = coalesce(var.gvisor_enabled,
      var.workload_class == "secure")`.
- [x] 2.2 Site 1 completion: the `runtime = "gvisor"` label rides
      effective gVisor (merged into the label map only when on) — on
      both the resource labels and the kubelet label fragment. A
      gVisor-enabled analytics pool advertises the runtime; a
      gVisor-disabled secure pool must not lie.
- [x] 2.3 Site 4: gate the gVisor install MIME part in `user_data.tf`
      (download + SHA-512 verify + containerd drop-in + restart +
      plugin assert) on effective gVisor — the whole part absent when
      off, via the same part-gating mechanism the ECR-mirror part
      uses; the template gains its `gvisor_enabled` input for the
      kubelet fragments.
- [x] 2.4 User-data assertions (DESIGN-0024 OQ 6a; mechanism per
      OQ 2 below): per-class decode of the launch template's
      `user_data` — the kubelet label fragment carries the class, the
      register-with-taints fragment present/absent per class, the
      gVisor MIME part present/absent per effective gVisor.
- [x] 2.5 Override-direction runs: `gvisor_enabled = true` on a
      non-secure class (part + runtime label present, class taint per
      class rule) and `false` on `secure` (part + runtime label
      absent, class taint intact).
- [x] 2.6 Module gates re-run; USAGE.md regen; README class table +
      default-change note.
- [ ] 2.7 **Hub-unblock milestone:** merge + tag the node-group
      release (minor, default-change note prominent) per the OQ 1
      resolution — the hub buildout pins this tag.

> **Implementation note (task 2.3) — the DESIGN's literal text would
> have shipped a bug.** DESIGN-0024 part 3 says to gate the gVisor
> shellscript part "the same part-gating mechanism the ECR-mirror part
> already uses," which assumes the mirror is its own MIME part. It is
> not: the mirror config is written *inside* the gVisor shellscript
> part, and both write containerd config that the part's single
> `systemctl restart containerd` picks up. Gating that whole part on
> effective gVisor would therefore have silently dropped the
> pull-through-cache mirror on every non-gVisor class — a bootstrap
> regression invisible until pods failed to pull. **What shipped
> instead:** the shellscript part renders when *either* gVisor or the
> mirror is on, with the two fragments gated independently inside it;
> the containerd restart is shared (both need it) and the runsc plugin
> assertion stays under the gVisor gate. The
> `mirror_renders_without_gvisor` run in `tests/user_data.tftest.hcl`
> is the permanent regression for exactly this.

#### Success Criteria

- The fleet's first user-data assertions are green for all five
  classes and both override directions.
- A default (`core`) invocation renders untainted nodes with NO
  gVisor MIME part and no `runtime` label — resource surface and
  rendered user-data both asserted. **Gate 1 clears here.**
- The explicit-secure run still renders the full pre-change posture:
  label, taint, and the complete gVisor part.
- `just static` green; the node-group release is tagged and
  consumable by the live repo.

---

### Phase 3: Cluster fence and bootstrap contract

All `eks/cluster` changes in one phase: one additive output, the
fence, its guards, and the explicit bootstrap posture. Every existing
consumer replans zero-diff.

#### Tasks

- [x] 3.1 `sso_principal_arn` additive output: the regex-resolved SSO
      role ARN when `sso_access_enabled`, else `null` — published
      into the eks state alongside the existing outputs (feeds the
      Phase 4 collision guard).
- [x] 3.2 Fence surface (DESIGN-0024 part 2 verbatim):
      `endpoint_public_access_cidrs` +
      `endpoint_public_access_prefix_list_ids` variables (both
      default `[]`), `data.aws_ec2_managed_prefix_list.fence`
      for_each, `local.fence_union` (distinct concat of literals +
      plan-time expansion), `local.public_access_cidrs` (empty union
      → `["0.0.0.0/0"]`), and `vpc_config.public_access_cidrs`
      wiring.
- [x] 3.3 Guards: at-least-one-endpoint precondition
      (`endpoint_private_access || endpoint_public_access`);
      fence-without-public fails at plan (either fence input
      non-empty while the public endpoint is off); the 40-CIDR
      precondition (`length(local.public_access_cidrs) <= 40`,
      message naming both fence inputs and prefix-list expansion as
      the usual culprit).
- [x] 3.4 Explicit `bootstrap_cluster_creator_admin_permissions =
      true` in `access_config` (zero diff — the current effective
      value) + the stable-creator README contract (OQ 4 resolution:
      create via the automation path; an SSO-created bootstrap entry
      is disposable; `false` + an explicit deploy-role entry is the
      recorded follow-up posture).
- [x] 3.5 Plan additions: the **default-fence zero-diff pin**
      (`public_access_cidrs == ["0.0.0.0/0"]` — the replan invariant
      in test form); literal-CIDR run; prefix-list run with
      `override_data` stubbing the expansion; union + dedup run; the
      three guard failures via `expect_failures`; the private-only
      spoke run; bootstrap pinned explicitly true;
      `sso_principal_arn` on and off (null when SSO disabled); the
      SSO singleton pinned **by address** unchanged.
- [x] 3.6 README warning callout (plan-time-only expansion vs an SG's
      live prefix-list reference; the 40-CIDR budget; the live-sync
      follow-up and why conditional `ignore_changes` cannot exist) +
      module gates re-run + USAGE.md regen.

#### Success Criteria

- Every pre-existing cluster plan run green **unchanged** — no
  default flips, no address churn; the default-fence pin proves the
  zero-diff contract.
- All three guards fail at plan with their named messages; the
  private-only spoke shape plans green.
- `just static` green; cluster release tagged (minor).

---

### Phase 4: The access entries module

The fourth eks-state consumer, built to the sibling pattern
(`addons` / `pod-identity-access`): remote-state read, typed map
surface, plan suite as the gate.

#### Tasks

- [x] 4.1 Scaffold `modules/eks/access-entries` per DESIGN-0024
      part 1's layout: `versions.tf` (aws `~> 6.2`), `.tflint.hcl` +
      `.terraform-docs.yml` from the sibling consumers, README
      skeleton, `variables.tf` with `cluster_name` + the six
      Terragrunt globals.
- [x] 4.2 `data.tf`: the eks remote-state read at the account-scoped
      ADR-0020 key
      (`<account_name>/<region>/eks/<cluster_name>/terraform.tfstate`)
      with the standard `assume_role` block; read at the use site per
      ADR-0001.
- [x] 4.3 `main.tf`: the `access_entries` map(object) (DESIGN-0024
      part 1 verbatim — principal ARN, type, groups, user_name,
      `policy_associations` map with `access_scope`), one
      `aws_eks_access_entry.this` per entry (`for_each` on the map),
      one `aws_eks_access_policy_association.this` per flattened
      `"<entry>:<association>"` key.
- [x] 4.4 Validations: non-STANDARD types reject
      groups/user_name/associations (the EKS API's rule, named in the
      message); `principal_arn` IAM role/user ARN shape, no
      wildcards; namespace scope requires a non-empty `namespaces`;
      `policy_arn` prefix-validated
      `arn:aws:eks::aws:cluster-access-policy/`.
- [x] 4.5 The cross-stack SSO collision guard: a precondition
      rejecting any entry whose principal equals the state's
      `sso_principal_arn`, `try()`-null-safe so a stale cluster state
      (predating the Phase 3 output) degrades to no-guard — the
      README carries the "re-apply the cluster stack to arm the
      guard" note.
- [x] 4.6 `outputs.tf` (`access_entry_arns`, `principal_arns` —
      pointer-only maps) + the README: the platform §4 worked-example
      trio (argocd-deployer assumed-role → deploy group; break-glass
      SSO → `AmazonEKSClusterAdminPolicy` cluster scope; the deploy
      role as the durable admin), the "Remote-state key contract"
      section, and the day-0 ordering note (entries stack applies
      after the cluster stack; the bootstrap admin is the floor in
      between).
- [x] 4.7 Plan suite (`tests/`, real-provider-fake-creds +
      `override_data` on the eks state read): the three-entry
      hub-shaped run pinning entry attributes, association scoping,
      and the flattened association addresses; the validation
      `expect_failures` set (4.4's four cases); the collision guard
      armed (state stub carrying `sso_principal_arn`) and the
      null-safe stale-state run; the ADR-0020 composed-key assertion.
- [x] 4.8 `just changed` pickup verification (the new module appears
      in the plan matrix for its diff) + `just tf all
      eks/access-entries`.

#### Success Criteria

- The plan suite is green and is the module's gate; the collision
  guard proves both the armed and stale-state paths.
- The ADR-0020 key assertion pins the composed account-scoped key.
- `scripts/changed-modules.sh` picks the module up; `just static`
  green fleet-wide with the new module included.

---

### Phase 5: LocalStack applies and closure

The live tier, the parity record, and every doc the fleet's
conventions require.

#### Tasks

- [x] 5.1 Access-entries Community apply suite
      (`tests-localstack/`): fixture per the OQ 3 resolution; probe
      access-entry API parity on token-free 4.4 first (OQ 4) and
      assert what round-trips; FINDINGS.md records the probe either
      way.
- [x] 5.2 Cluster Community apply extension: a fence apply run where
      4.4 supports `public_access_cidrs`; FINDINGS.md updated.
- [x] 5.3 Node-group Community apply extension: class-parameterized
      runs (core + secure); FINDINGS.md updated.
- [ ] 5.4 Run all touched Community applies live against the 4.4 pin
      (`just tf test-localstack ...` per module) — token-free, per
      the fleet constraint.
- [x] 5.5 Doc closure: CLAUDE.md eks section (the new module, the
      ADR-0011 load-bearing change bar, the class taxonomy, the
      default change); the ADR-0020 consumer-table row for
      `eks/access-entries`; the INV-0011 delivery note.
- [ ] 5.6 docz status flips (DESIGN-0024 → Implemented; this doc →
      Completed) + `docz update` + the 14-file mangle-set restore +
      `just docs lint`.
- [ ] 5.7 Conventional commits throughout; PRs labeled `minor` with
      the node-group default-change note prominent in README and
      CHANGELOG (per the OQ 1 cadence).

> **Phase 5 blocker (2026-08-30) — tasks 5.4, 5.6, 5.7 need the
> operator.** 5.1–5.3 and 5.5 are done: the suites are authored, the
> docs closed. **5.4 cannot be executed by the authoring session**:
> EKS is Pro-only in LocalStack (probed on token-free Community 4.4 —
> `eks` is absent from the health output and `list-clusters` returns
> "The API for service 'eks' is either not included in your current
> license plan"), and `LOCALSTACK_AUTH_TOKEN` is operator-held. Each
> touched `FINDINGS.md` carries a pending-re-run note naming the
> command. **5.6 is deliberately held** behind 5.4: flipping
> DESIGN-0024 to Implemented and this doc to Completed would assert a
> live-verified state that does not exist yet. **5.7's PR/merge/tag
> half** is likewise the operator's — the conventional-commit half is
> done. This also leaves IMPL-0020 OQ 4 resolved by evidence rather
> than by fallback: the Community-`plan_smoke` alternative is moot,
> since the APIs are wholly absent from that tier.
>
> To close the phase:
>
> ```sh
> just tf test-localstack eks/managed-node-group
> just tf test-localstack eks/cluster
> just tf test-localstack eks/access-entries
> ```

#### Success Criteria

- All live Community applies green; every FINDINGS.md records its
  parity outcome (assert-what-round-trips, record the rest).
- `just static` + all three modules' plan gates green; zero-diff
  replan demonstrated for a fence-default cluster (the default-fence
  pin + every pre-existing run unchanged).
- All docs merged; DESIGN-0024 reads Implemented; the INV-0011
  delivery note closes the loop.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/eks/managed-node-group/variables.tf` | Modify | `workload_class` enum + `gvisor_enabled`; two descriptions rewritten class-neutral |
| `modules/eks/managed-node-group/locals.tf` | Modify | Per-class rules; class label; conditional runtime label; effective-gVisor coalesce |
| `modules/eks/managed-node-group/main.tf` | Modify | Static taint → `dynamic "taint"` gated on non-core |
| `modules/eks/managed-node-group/user_data.tf` | Modify | gVisor MIME part gated on effective gVisor; template inputs threaded |
| `modules/eks/managed-node-group/templates/user_data.sh.tftpl` | Modify | Class label / conditional taint / gVisor kubelet fragments templated |
| `modules/eks/managed-node-group/outputs.tf` | Modify | `node_taints` / `node_labels` class-derived |
| `modules/eks/managed-node-group/tests/` | Modify | Per-class matrix + user-data assertions + override runs |
| `modules/eks/cluster/outputs.tf` | Modify | Additive `sso_principal_arn` |
| `modules/eks/cluster/variables.tf` | Modify | Two fence variables |
| `modules/eks/cluster/main.tf` | Modify | Fence data/locals/wiring; guards; explicit bootstrap `true` |
| `modules/eks/cluster/tests/` | Modify | Fence runs + guard failures + zero-diff pin + output runs |
| `modules/eks/access-entries/` | Create | The new module: full layout per DESIGN-0024 part 1 |
| `modules/eks/*/README.md`, `USAGE.md` | Modify | Warning callout, stable-creator contract, class table, key contract |
| `docs/adr/0020-*.md` | Modify | Consumer-table row for `eks/access-entries` |
| `CLAUDE.md` | Modify | eks section: new module, taxonomy, default change, change bar |
| `docs/investigation/0011-*.md` | Modify | Delivery note |

## Testing Plan

- [x] Node-group plan matrix: core default + explicit secure + the
      three remaining classes + enum rejection + layering runs.
- [x] User-data assertions per class and per override direction (the
      fleet's first rendered-template coverage).
- [x] Cluster plan additions: default-fence zero-diff pin, literal /
      prefix-list / union runs, three guard failures, private-only
      run, bootstrap pin, `sso_principal_arn` on/off, SSO singleton
      pinned by address.
- [x] Access-entries plan suite: hub-shaped trio, validation
      failures, collision guard armed + stale, ADR-0020 key.
- [ ] Community applies: access-entries fixture suite (parity
      probed), cluster fence run, node-group class runs — all live
      against token-free 4.4.

## Dependencies

- DESIGN-0024 with all six OQs resolved (done 2026-08-27) — no open
  design decisions remain; the four IMPL-level OQs below are new.
- In-repo ordering only: Phase 4's collision guard consumes Phase 3's
  `sso_principal_arn` output (`try()`-null-safe either way, but the
  order keeps the guard armed from the module's first apply).
- The existing eks-consumer test scaffolding (`override_data` state
  stubs, the shared `terragrunt-inputs.tfvars` six globals, the
  bespoke `fixtures/setup` pattern) — all in place since IMPL-0015.
- LocalStack Community stays the token-free 4.4 pin (fleet
  constraint; never wire a token into that tier).
- **Not** dependencies: DESIGN-0021/0022/0023 IMPLs and the queued
  `iam/role` / `network/security-group` DESIGNs — parallel tracks per
  the buildout order; DESIGN-0022's Gate 2 constrains the *hub
  buildout*, not this IMPL.

## Open Questions

> **All resolved 2026-08-28: 1a, 2a, 3a, 4a.** The phases above were
> written to the recommended shapes, so no task edits follow from the
> resolutions: the cadence is three PRs with the Phase-2 tag as the
> hub-unblock milestone (task 2.7), user data is asserted on the
> launch template attribute directly (task 2.4), the apply fixture is
> the bespoke addons-style setup (task 5.1), and Community parity is
> probe-first with a plan-smoke floor (tasks 5.1/5.4).

### 1. What is the PR and release cadence?

**Resolved: a.** Three PRs; Phases 1 + 2 ride one node-group PR and
release, and its tag at merge is the hub-unblock milestone.

- **a. (Recommended)** Three PRs: **PR 1 = Phases 1 + 2 together**
  (one node-group minor release — Phase 1 alone is a half-threaded
  intermediate where core groups are untainted but still
  unconditionally install gVisor and carry the runtime label; that
  state is never released on its own; the tag at merge is the
  hub-unblock milestone the live repo pins). **PR 2 = Phase 3** (the
  cluster minor). **PR 3 = Phases 4 + 5** (the new module's first
  release + the apply-suite extensions and doc closure; the
  test-only cluster/node-group apply extensions ride here without
  re-releasing those modules). Phases stay separate commit groups
  inside their PR.
- b. One PR per phase (five PRs) — smaller reviews, but it publishes
  the Phase-1 intermediate as a release and splits the closure from
  the module it closes.
- c. One PR for the whole IMPL — atomic, but it blocks the
  hub-unblock milestone behind the cluster and access-entries work,
  defeating the sequencing this doc exists to encode.
- Other: (your call)

### 2. How is rendered user data asserted?

**Resolved: a.** Direct resource-attribute assertions; no test-only
output enters the module contract.

- **a. (Recommended)** Assert the launch template resource's
  `user_data` attribute directly in run-block conditions —
  `base64decode` the planned value, then per-fragment `strcontains`
  checks. The value is plan-known (the template renders from
  plan-known variables), the fleet's suites already pin resource
  attributes directly, and no output surface widens: test needs never
  grow a module contract.
- b. Add a module output exposing the rendered user data for the
  suites — simpler assertion expressions, but it publishes an
  internal into USAGE.md and remote state, invites downstream
  coupling to bootstrap internals, and exists only for tests.
- Other: (your call)

### 3. What shape is the access entries apply fixture?

**Resolved: a.** The bespoke addons-style `fixtures/setup`, with the
second stale-state seed exercising the guard's degrade path.

- **a. (Recommended)** The bespoke addons-style `fixtures/setup`: a
  minimal real `aws_eks_cluster` plus a seeded account-scoped eks
  state key carrying the consumer set + `sso_principal_arn` — the
  pattern the three sibling eks consumers already use. Fast, and the
  suite can cheaply seed a second, stale state (no
  `sso_principal_arn`) to exercise the guard's degrade path live.
- b. Compose the real `eks/cluster` module (the read-replica
  precedent) — maximum state fidelity, but the slowest apply in the
  eks family and it couples the new module's suite to cluster-module
  churn; the state-content fidelity it buys is already proven by the
  four existing consumer suites.
- Other: (your call)

### 4. What if Community lacks access entry parity?

**Resolved: a.** Probe-first; assert what round-trips, keep a
plan-smoke floor if the APIs are wholly absent, record the outcome in
FINDINGS.md either way.

- **a. (Recommended)** Probe first, then assert what round-trips: if
  4.4 supports the access-entry APIs partially, the apply suite
  applies what works and FINDINGS.md records the gaps; if the APIs
  are wholly absent, the suite keeps a minimal `plan_smoke` run (the
  proxy/cluster Community precedent) so the tier stays wired and the
  plan suite remains the gate. Either way the probe outcome is a
  recorded FINDINGS.md fact, not a silent skip.
- b. Drop `tests-localstack/` entirely if the APIs are absent —
  less scaffolding, but it makes this the only eks consumer without
  the tier and loses the parity record the fleet discipline expects.
- Other: (your call)

## References

- **DESIGN-0024** — the design this doc implements (all OQs resolved;
  Detailed Design parts 1–3 are the source for every surface here).
- **INV-0011** — F7/F8 (the findings behind parts 2–3), OQ 11–13 as
  amended, and the Recommendation's sequencing note (2026-08-28) that
  fixes this doc's phase order and buildout-order section.
- **INV-0004** — the create-or-adopt / brownfield import-first
  doctrine the buildout order leans on.
- **DESIGN-0022** — Gate 2's owner (the evidence bucket's create-time
  Object Lock); implemented separately.
- Platform ADR-0011 / DESIGN-0001 (external, cited by ID) — the
  cluster path + change bar; §2 node groups and §4 IAM principals.
- **ADR-0020** — the remote-state key contract; gains the
  access-entries consumer row.
- **IMPL-0001 / IMPL-0002 / IMPL-0004** — the cluster, node-group,
  and pod-identity-access heritage (the per-cluster-surface-as-module
  precedent the new module follows).
- **DESIGN-0015** — the subnet-tier rewire, sequenced independently.
