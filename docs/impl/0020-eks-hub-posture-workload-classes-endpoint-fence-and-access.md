---
id: IMPL-0020
title: "EKS hub posture workload classes endpoint fence and access entries"
status: Completed
author: Donald Gifford
created: 2026-08-28
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0020: EKS hub posture workload classes endpoint fence and access entries

**Status:** Completed
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
- [Security review (2026-08-30)](#security-review-2026-08-30)
- [Design-conformance audit (2026-08-30)](#design-conformance-audit-2026-08-30)
  - [Verifying the fail-closed tests fail for the right reason](#verifying-the-fail-closed-tests-fail-for-the-right-reason)
  - [The Go libtftest suite this work broke](#the-go-libtftest-suite-this-work-broke)
  - [Open — the CHANGELOG task 5.7 names does not exist](#open--the-changelog-task-57-names-does-not-exist)
  - [Live-coverage sweep the review prompted](#live-coverage-sweep-the-review-prompted)
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
  and the per-class locals (grep-verified — but see the correction
  below: the original grep was scoped too narrowly and this criterion
  read as met while one site was still hardwired).
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
- [x] 2.7 **Hub-unblock milestone: `v0.21.0` (2026-09-01).** PR #106
      merged; `pr-semver-bump` cut the minor tag with the
      default-change note leading the release notes. The cadence
      collapsed from OQ 1a's three PRs to one (recorded at 5.7), so
      this tag carries all three modules — **the hub buildout pins
      `v0.21.0`**.

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
- [ ] 5.4 **DEFERRED by operator decision (2026-09-01)** — the release
      does not block on the live applies; they run as a follow-up when
      a Pro container is available (either closure path below). The
      suites stay authored, each `FINDINGS.md` keeps its
      pending-re-run note, and this task stays unchecked until the
      runs happen. Original task: run all three touched apply suites
      live (`just tf test-localstack ...` per module). **Corrected
      from the original wording** ("against the 4.4 pin — token-free"):
      that is not achievable and never was. EKS is Pro-only, so these
      suites need a **Pro** container despite living in the
      `tests-localstack/` directory. The directory name is a fleet
      convention, not a statement about the container tier — CI's
      `test-localstack` job launches `localstack/localstack-pro` with
      the auth token for *both* apply tiers. The token-free 4.4
      constraint binds the suites that can genuinely honour it (s3,
      secretsmanager, network/vpc-lookup), not this one.
- [x] 5.5 Doc closure: CLAUDE.md eks section (the new module, the
      ADR-0011 load-bearing change bar, the class taxonomy, the
      default change); the ADR-0020 consumer-table row for
      `eks/access-entries`; the INV-0011 delivery note.
- [x] 5.6 docz status flips + `docz update` + the mangle-set restore +
      `just docs lint`. **Resolved under the 5.4 deferral (2026-09-01):**
      DESIGN-0024 → Implemented (the design *is* implemented — every
      surface it specifies is in code, plan-gated, and
      conformance-audited; live-apply verification is 5.4's concern,
      not the design's). This doc stays **In Progress**, not Completed:
      it tracks delivery, and 5.4 (deferred) + 5.7's PR/tag half remain
      open. Completed flips when the release lands.
- [x] 5.7 Conventional commits throughout; PRs labeled `minor` with
      the node-group default-change note prominent in README and
      CHANGELOG (per the OQ 1 cadence). **Done (2026-09-01):**
      [#106](https://github.com/donaldgifford/libtftest-tf-modules/pull/106)
      merged, `v0.21.0` cut, and the `refresh-readme` job updated the
      module table (all three eks modules read `v0.21.0`). The
      default-change note led both the PR body and the
      `### RELEASE NOTES` block (the repo's changelog mechanism — no
      CHANGELOG file exists; see the audit note). **Cadence deviation:**
      OQ 1a's three sequential PRs collapsed to one — the phases landed
      on one branch with cross-cutting security-review/audit commits,
      so this one tag is the hub-unblock milestone (closes task 2.7).

> **Phase 5 blocker (2026-08-30) — tasks 5.4, 5.6, 5.7 need the
> operator.** 5.1–5.3 and 5.5 are done: the suites are authored, the
> docs closed. **5.4 cannot be executed by the authoring session**:
> EKS is Pro-only in LocalStack (probed on token-free Community 4.4 —
> `eks` is absent from the health output and `list-clusters` returns
> "The API for service 'eks' is either not included in your current
> license plan"), and `LOCALSTACK_AUTH_TOKEN` is operator-held.
> Re-verified in the environment before this note was finalized:
> Docker is running but has no LocalStack container,
> `LOCALSTACK_AUTH_TOKEN` is unset, and `lstk` has no stored
> credentials (no config at `~/.config/lstk/config.toml`) — `lstk
> login` is interactive. Each touched `FINDINGS.md` carries a
> pending-re-run note naming the command. **Update (2026-09-01): the
> operator deferred 5.4** — the release proceeds without the live
> applies, which run as a follow-up. That resolved 5.6 (see the task
> note): DESIGN-0024 flipped to Implemented; this doc stays In
> Progress until the release lands. **5.7's PR/merge/tag half** is
> the operator's — the conventional-commit half is done. This also leaves IMPL-0020 OQ 4 resolved by evidence rather
> than by fallback: the Community-`plan_smoke` alternative is moot,
> since the APIs are wholly absent from that tier.
>
> **Two closure paths, both operator-side.** (a) A local Pro container
> — the commands below, against a running Pro instance. (b) **CI**: the
> `test-localstack` job already launches
> `localstack/localstack-pro:2026.07.2` with `secrets.
> LOCALSTACK_AUTH_TOKEN` for the tier these suites sit in, and `just
> changed` confirms all three are in the matrix (the brand-new module
> included), so flipping `CI_RUN_LOCALSTACK_APPLY` to `true` would run
> them. Path (b) is blocked on the separate, repo-external LocalStack
> subscription issue that keeps the token from activating headless —
> the same reason both apply tiers are off by default (IMPL-0016
> Phase 6). Whichever path runs first, record the result and the Pro
> version in each `FINDINGS.md`.
>
> To close the phase:
>
> ```sh
> just tf test-localstack eks/managed-node-group
> just tf test-localstack eks/cluster
> just tf test-localstack eks/access-entries
> ```

#### Success Criteria

- All three live apply suites green (**Pro** container — the original
  "Community" wording repeated task 5.4's error; EKS is Pro-only);
  every FINDINGS.md records its parity outcome
  (assert-what-round-trips, record the rest). **Deferred with 5.4
  (operator, 2026-09-01)** — this criterion is met when the follow-up
  runs, not by the release.
- `just static` + all three modules' plan gates green; zero-diff
  replan demonstrated for a fence-default cluster (the default-fence
  pin + every pre-existing run unchanged). ✅
- All docs merged; DESIGN-0024 reads Implemented; the INV-0011
  delivery note closes the loop. DESIGN flip + delivery note done;
  "merged" lands with PR #106.

---

## Security review (2026-08-30)

An adversarial review of the access-control and network-fence surfaces
(the `iac-security` agent, one finding verified by standalone apply)
found five real holes in the as-built code, spanning Phases 1–4. All
are fixed with a regression run each; the three plan suites went
22 / 12 / 12 → 24 / 13 / 15.

1. **Silent cluster-wide grant (HIGH).** `access_scope.type` defaults
   to `"cluster"`, so the namespaces-only form
   `access_scope = { namespaces = ["team-a"] }` read as a scoped grant
   but discarded the list and granted cluster-wide. The module
   validated the *inverse* mistake only. Now rejected at plan.
2. **Fence expanding to nothing fell through to world-open (HIGH).**
   `fence_union` empty → `["0.0.0.0/0"]`. That fallback is correct for
   *no fence requested*, but a fence built only from prefix lists that
   expand empty (emptied out-of-band by anyone holding
   `ec2:ModifyManagedPrefixList`, or simply not yet populated) reached
   it too — converting a corp-only endpoint to world-open on the next
   routine apply. The existing guard tested the raw inputs, not the
   union, so it stayed quiet. A new fourth precondition closes it.
3. **`additional_labels` could forge `runtime=gvisor` (MEDIUM).** The
   merge wins on collision and only the EKS-API label path sees it, so
   a caller could advertise a sandbox the bootstrap never installed —
   the exact lie `local.gvisor_effective` exists to prevent, and a
   direct contradiction of the "cannot drift" comment. The three
   module-managed keys are now reserved.
4. **Collision guard evaded by ARN spelling (MEDIUM).**
   `data.aws_iam_roles` returns reserved SSO roles *path-bearing*,
   while access-entry configs conventionally use the path-stripped
   form — same principal, different string, raw compare missed it.
   Now normalized to `<account>/<name>`, lowercased. The plan suite's
   stub was corrected to the realistic path-bearing form, which makes
   the existing guard run the evasion regression.
5. **No principal uniqueness across entries (MEDIUM-LOW).** Two keys
   could name one principal: collides at apply, and hides the true
   grant from review since effective access is the union. Rejected.

Deliberately **not** changed: the `try()` fail-open degrade path
(documented tradeoff — worst case is an apply-time
`ResourceInUseException`, never a privilege grant) and
`kubernetes_groups` accepting `system:masters` (the module's intended
RBAC capability — a validation-surface asymmetry, not a defect).

The two HIGH findings share a shape worth carrying forward: **a
permissive default plus a partially-specified input is a silent
widening.** Validate an input object's *coherence*, not just its
fields, and test a fallback against the resolved value rather than
against the raw inputs that feed it.

## Design-conformance audit (2026-08-30)

A second pass read DESIGN-0024 end to end against the shipped code,
asking only "what does the design specify that the code does not do?".
Every functional surface is present with the design's names, defaults
and validations — no missing or renamed variable, output, resource,
guard, or test; all six design OQs landed in code; every Non-Goal
honoured; every deferral explicit. Four gaps, all outside the
functional surface:

1. **A hardwired `secure` string survived Phase 1** (code).
   `launch_template.tf` described every node group as
   `"<name> secure node group"` regardless of class, so a `core` group
   was labelled "secure" in the EC2 console. The file predates
   DESIGN-0024 and was never swept — and this **falsified the Phase 1
   success criterion** above, which claims grep-verified removal of
   literal secure-class strings. The original grep covered
   `variables.tf` / `locals.tf` / `main.tf` / `outputs.tf` and missed
   `launch_template.tf` entirely. Now class-derived, with two
   assertions in `tests/workload_class.tftest.hcl` pinning it, and the
   sweep re-run across every `*.tf` and `*.tftpl` in the module.
2. **The cluster README documented three guards; there are four.** The
   fence-expands-to-nothing precondition from the security review was
   undocumented — and it is the one guard that can fail a plan that
   previously succeeded, so an operator hitting it had nothing to read.
   Documented with the reason and the fix.
3. **Two stale cluster-README claims.** "4 run blocks" (actual: 13
   across four files; the whole fence matrix was unlisted), and the
   EKS-state-consumer list omitted `access-entries` — the very module
   this IMPL adds. ADR-0020's table already carried the row.
4. **`additional_labels`' reserved keys were undocumented in prose.**
   Discoverable via the variable description and `USAGE.md`, but the
   node-group README never mentioned them. Added as a table.

The pattern across 1–4: **the functional surface was well covered by
tests, and everything that drifted was the part tests do not check.**
A grep scoped to the files a change "should" touch will confirm its own
assumption; a success criterion asserting "grep-verified" is only as
good as the grep's scope, and nothing re-ran it.

### Verifying the fail-closed tests fail for the *right* reason

`expect_failures` asserts only that a given checkable object errored —
**not which of its rules fired.** With eight validations on
`var.access_entries` and four preconditions on `aws_eks_cluster.this`,
every one of these runs could have been passing off a neighbouring
rule, and the suite would look identically green. That is not a
hypothetical: the security review's HIGH #2 existed precisely because a
guard that *looked* covered was testing the wrong thing.

Both surfaces were checked, and all pass honestly.

**The eight `var.access_entries` validations** — each offending input
was re-run without `expect_failures` so Terraform printed the actual
message. Eight distinct messages, each the intended rule; the two
security-review additions (namespaces-without-explicit-scope,
duplicate-principals) fire on their own rules rather than piggybacking:

| Run | Message that fired |
|---|---|
| wildcard principal | exact-ARN, no wildcards |
| malformed ARN | exact-ARN (same rule, second case) |
| groups on non-STANDARD | non-STANDARD types carry no groups |
| unknown type | type enum |
| IAM policy ARN | must be a cluster-access-policy ARN |
| namespace scope, no namespaces | must list ≥1 namespace |
| namespaces, no explicit scope | **would silently grant cluster-wide** |
| duplicate principals | one principal, one entry |

**The cluster's fourth precondition** was proven by **mutation**: with
that one condition neutered and the other three left armed,
`rejects_fence_that_expands_to_nothing` fails with *"Missing expected
failure"* — no other guard catches an emptied prefix list. Exactly one
test failed (11 passed / 1 failed / 1 skipped), so the guard is
exercised by that run alone and nothing else silently depends on it.

Worth reusing: **a passing `expect_failures` run is evidence the object
errored, not evidence your rule works.** Removing the rule and
confirming the test goes red is the cheap way to tell the difference.
(Terraform rejects a constant `condition`, so neuter with an
always-true expression that still references config —
`length(var.x) >= 0`.)

### The Go libtftest suite this work broke

`modules/eks/cluster/test/` is a **libtftest Go integration suite** —
the fleet's only one outside `tools/` — and nothing in this IMPL's plan
mentioned it. Its `outputs_contract` subtest asserts an **exact** output
count, so Phase 3's additive `sso_principal_arn` output broke it:
`output count = 9; want 8`.

Nothing caught this. The suite is `//go:build integration` tagged and
CI touches the module only through `security.yml`'s `govulncheck`
matrix — no job compiles or runs it, `just static` does not cover Go,
and it needs a LocalStack container besides. It would have failed the
next time anyone ran it and looked like an unrelated regression.

Fixed by adding the output to the expected list. **The exact-count
assertion is correct and was left exact** — the eks state shape is a
cross-module contract with five consumers (ADR-0020), so an output
appearing by accident should fail a test. The lesson is the inverse of
the usual one: the assertion did its job, and the gap was that no gate
runs it. Also cleaned two pre-existing lint failures in
`helpers_test.go` (gofmt alignment + `gci` import order) surfaced while
verifying the fix.

Two follow-ups worth considering, both fleet-scope rather than
IMPL-0020: whether the Go suite should be compiled (`go vet -tags
integration`) by a CI job that needs no container, and whether the
additive-output convention should extend to it — this work treated
"additive output" as automatically safe, and for this suite it was not.

### Open — the CHANGELOG task 5.7 names does not exist

DESIGN-0024 requires the node-group default-change note in "the README
**and CHANGELOG** both", and task 5.7 carries that forward. The README
half is done. **There is no CHANGELOG anywhere in this repo** — no
root or per-module file, no `cliff.toml`, and `release.yml` holds only
`bump-version`. Release notes today come from a `### RELEASE NOTES`
block in the PR body (`pr-semver-bump`, `require-release-notes:
false`). So 5.7 cannot be closed as written without first deciding
whether this repo gains a changelog convention — which is a fleet-wide
call (it interacts with the per-module semver tagging and the planned
Go release CLI), not an IMPL-0020 decision. Flagged for the operator;
the pragmatic close is to put the default-change note in the PR's
release-notes block and treat the design's "CHANGELOG" as satisfied by
that.

### Live-coverage sweep the review prompted

The Phase 5 apply suites were authored *before* these fixes, so each
was re-read against the question "would the live tier have caught
this?". Three gaps closed — all in suites that still await a Pro
container, so they are authored-not-run like the rest of Phase 5:

- **`eks/access-entries`** — the collision run named the SSO principal
  by the same string the stub state carried, so the live tier proved
  only the trivial identical-spelling case. The fixture's SSO-owned
  role now carries a `path`, giving it the two real spellings, and the
  run declares the path-stripped one.
- **`eks/cluster`** — `fenced_apply` passes literal CIDRs, so
  `data.aws_ec2_managed_prefix_list` was never resolved outside an
  `override_data` stub: the entire expansion path was unproven live.
  The fixture now creates two real managed prefix lists (one
  populated, one empty) behind two plan-only runs. This also asks the
  emulator a question nothing else in the fleet does — whether it
  serves managed prefix lists with `entries` populated.
- **`eks/managed-node-group`** — the pull-through mirror is opt-in and
  no apply run enabled it, so the mirror-on/gVisor-off combination
  (exactly what the DESIGN-0024 part-gating deviation would have
  broken, and invisibly: the nodes still boot) never reached EC2.
  `mirror_without_gvisor_apply` closes it.

The generalizable point: **a fix is not covered just because a
regression exists at the tier where the logic lives.** Each of these
had a green plan-suite regression while the live tier exercised a
degenerate case — identical strings, one input path, an off-by-default
feature.

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
      prefix-list / union runs, four guard failures, private-only
      run, bootstrap pin, `sso_principal_arn` on/off, SSO singleton
      pinned by address.
- [x] Access-entries plan suite: hub-shaped trio, validation
      failures, collision guard armed + stale, ADR-0020 key.
- [ ] Live applies: access-entries fixture suite (parity probed),
      cluster fence + prefix-list runs, node-group class + mirror
      runs. Needs a **Pro** container (the original "token-free 4.4"
      wording was task 5.4's error — EKS is absent from Community);
      deferred with 5.4 (operator, 2026-09-01).

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
