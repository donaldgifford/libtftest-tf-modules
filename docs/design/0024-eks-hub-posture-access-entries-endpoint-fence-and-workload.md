---
id: DESIGN-0024
title: "EKS hub posture access entries endpoint fence and workload classes"
status: Implemented
author: Donald Gifford
created: 2026-08-27
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0024: EKS hub posture access entries endpoint fence and workload classes

**Status:** Implemented
**Author:** Donald Gifford
**Date:** 2026-08-27

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background: the platform context](#background-the-platform-context)
- [Detailed Design part 1: the access entries module](#detailed-design-part-1-the-access-entries-module)
  - [Module layout and remote-state read](#module-layout-and-remote-state-read)
  - [The entries surface](#the-entries-surface)
  - [Access entry validations](#access-entry-validations)
  - [Cross-stack SSO collision guard](#cross-stack-sso-collision-guard)
  - [Day-0 ordering](#day-0-ordering)
- [Detailed Design part 2: the cluster module](#detailed-design-part-2-the-cluster-module)
  - [Bootstrap creator admin made explicit](#bootstrap-creator-admin-made-explicit)
  - [The endpoint fence](#the-endpoint-fence)
  - [Fence guards](#fence-guards)
  - [The README warning callout](#the-readme-warning-callout)
- [Detailed Design part 3: the node group module](#detailed-design-part-3-the-node-group-module)
  - [The workload class input](#the-workload-class-input)
  - [Per-class baked rules](#per-class-baked-rules)
  - [Threading the five hardwired sites](#threading-the-five-hardwired-sites)
  - [Output changes](#output-changes)
  - [The default-behavior change](#the-default-behavior-change)
- [Testing Strategy](#testing-strategy)
- [Phases](#phases)
  - [Phase 1: The access entries module](#phase-1-the-access-entries-module)
  - [Phase 2: Cluster changes](#phase-2-cluster-changes)
  - [Phase 3: Workload classes](#phase-3-workload-classes)
  - [Phase 4: gVisor toggle and user-data assertions](#phase-4-gvisor-toggle-and-user-data-assertions)
  - [Phase 5: Closure](#phase-5-closure)
- [Open Questions](#open-questions)
  - [1. What is the fifth class named?](#1-what-is-the-fifth-class-named)
  - [2. What form do policy associations take?](#2-what-form-do-policy-associations-take)
  - [3. What collection shape do access entries use?](#3-what-collection-shape-do-access-entries-use)
  - [4. What happens to bootstrap creator admin?](#4-what-happens-to-bootstrap-creator-admin)
  - [5. Is the 40-CIDR union guarded at plan?](#5-is-the-40-cidr-union-guarded-at-plan)
  - [6. Do user-data assertions land now?](#6-do-user-data-assertions-land-now)
- [References](#references)
<!--toc:end-->

## Overview

One DESIGN, one new module plus two module changes — the hub cluster
posture (INV-0011 OQ 2a, amended at review):

- **`eks/access-entries` (NEW)** — the generic access-entry surface
  (arbitrary principal → policies/scope/groups) as its **own
  module**, an eks-state consumer beside `managed-node-group` /
  `addons` / `pod-identity-access`. Pulled out of the cluster module
  at review (OQ 2 amendment): access-entry churn — principals come
  and go — must never plan, lock, or risk the cluster stack. The
  SSO singleton stays in `eks/cluster`, untouched (INV-0011 OQ 11a,
  as amended).
- **`eks/cluster`** gains the **endpoint fence** —
  `public_access_cidrs` exposure with literal-CIDR and prefix-list
  inputs preserving today's `endpoint_public_access = true` +
  implicit `0.0.0.0/0` contract exactly (INV-0011 OQ 12 operator
  shape) — plus an explicit `bootstrap_cluster_creator_admin_permissions`
  and one additive `sso_principal_arn` output.
- **`eks/managed-node-group`** parameterizes the hardwired secure
  class into a five-value `workload_class` enum (`core` default)
  with baked per-class label/taint rules and a nullable gVisor
  override (INV-0011 OQ 13, as amended; `analytics` confirmed at
  this review).

These changes carry a raised bar: per the platform's ADR-0011,
per-cluster Terraform stacks composed from these modules **are the
long-term cluster path** — "the eks/\* modules become load-bearing
platform components … their change bar (zero-diff replans, plan-test
invariants) is now platform policy."

## Goals and Non-Goals

### Goals

- Hub and spoke principals (argocd-deployer via `sse-platform-access`,
  break-glass SSO, the deploy role) expressible as access entries
  with direct ARNs, per-entry policy associations, and full
  namespace-scoped `access_scope` — none of which the SSO path
  supports (INV-0011 F7) — in a stack whose plan/apply cadence is
  independent of the cluster's.
- Spoke clusters run **private-only** (`endpoint_public_access =
  false` — already mechanically possible, now guarded); the hub keeps
  private+public with a CIDR/prefix-list fence. Platform DESIGN-0001
  confirms the shape: "hub → spoke private EKS API endpoints."
- Zero-diff replans for every existing consumer of `eks/cluster`:
  no default flips, no address churn, the fence inputs default to
  exactly today's implicit behavior, and the cluster's only
  access-surface change is one additive output.
- The node group serves all five classes
  (`core` / `observability` / `analytics` / `temporal` / `secure`)
  with one input; `secure` remains fully expressible and explicitly
  tested (the operator: it "needs to be dialed").
- The five F8 hardwired sites thread one class variable together —
  no half-parameterized states.

### Non-Goals

- **Subsuming the SSO surface into the generic map.** Rejected
  (INV-0011 OQ 11b): breaking variable change + address migration for
  no hub-side gain. SSO stays in `eks/cluster` as-is; the new module
  owns only generic entries.
- **Flipping `endpoint_public_access` to false by default**
  (DESIGN-0002's original intent). Stays resolved-by-documentation
  (IMPL-0001 Q11 / DESIGN-0015 Non-Goals); a future major-bump
  decision if ever.
- **Live prefix-list sync.** The fence expansion is plan-time only;
  conditional `ignore_changes` is impossible (Terraform lifecycle
  arguments are static — INV-0011 OQ 12 records the infeasibility).
  An out-of-band syncer (EventBridge-on-prefix-list-change) plus a
  module-wide ignored-fence posture decision is the recorded
  follow-up, not a v1 knob.
- **The subnet-tier rewire** (`vpc_config` → `private_eks_subnet_ids`)
  — that is DESIGN-0015's scope, sequenced independently.
- **Node-group Kubernetes objects** (RuntimeClass, chart
  nodeSelectors/tolerations) — in-cluster, platform-chart-owned; the
  class-to-workload mapping never lives in Terraform.

## Background: the platform context

Distilled per INV-0011 OQ 1 (this section is the in-repo record; the
platform docs are external — cited by ID, full distillation in
INV-0011 F1):

- **Topology (platform topology ADR + RFC-0002):** a management
  cluster (hub) in `sse-mgmt` hosting GitOps + core platform
  services — applications never run there — with environment spokes
  (`sse-dev`/`sse-stg`/`sse-prd`), **each in its own AWS account**,
  and a sandbox in a separate AWS organization with no standing
  trust. The account boundary is the environment boundary.
- **The cluster path (platform ADR-0011):** clusters are Terraform
  stacks composed from this repo's eks modules (`cluster` +
  `managed-node-group`(s) + `addons`, Terragrunt-composed, VPC via
  `vpc-lookup`). The stack's boundary is the registration secret
  (written by the cluster stack in the live repo — never by these
  modules); ESO materializes ArgoCD cluster secrets from it and
  ApplicationSets deliver the baseline. Nothing in-cluster is ever
  Terraform's.
- **The access-entry consumers (platform DESIGN-0001 §4):** the hub
  argocd-deployer's pod identity assumes each spoke's
  `sse-platform-access` role; that assumed role binds to a deploy
  RBAC group via an access entry. Break-glass SSO binds to admin.
  Human access everywhere is SSO permission sets → access entries —
  no static kubeconfigs. Spokes being cross-account is exactly why
  the generic map takes direct principal ARNs instead of the SSO
  path's in-account regex resolution (INV-0011 F1 batch 2).
- **The node groups (platform DESIGN-0001 §2):** the hub runs
  `core` (untainted — ArgoCD, Kargo, ESO, ALB controller, Headlamp,
  operators), `observability` (tainted — kube-prometheus/Thanos,
  Alertmanager, Loki, Grafana, ClickHouse, Langfuse, Alloy), and
  reserved `temporal`. No `secure` group on the hub. The future
  split peels ClickHouse + Langfuse to `analytics` (OQ 1, resolved) —
  Loki stays with the o11y stack (operator resolution, 2026-08-14);
  pre-baking the class makes that split a live-repo + chart change
  with no module release.
- **In-repo state (INV-0011 F7/F8):** cluster access is a
  count-gated SSO singleton (regex-resolved principal, no
  namespaces support, `authentication_mode` hardcoded
  `API_AND_CONFIG_MAP`, `bootstrap_cluster_creator_admin_permissions`
  silently defaulting true); `public_access_cidrs` is absent from
  the module entirely; the node group hardwires the secure class in
  five sites including two string literals in the user-data template
  and an unconditional gVisor install part.

## Detailed Design part 1: the access entries module

### Module layout and remote-state read

```text
modules/eks/access-entries/
├── main.tf              # entries + flattened associations
├── data.tf              # data.terraform_remote_state.eks (ADR-0020)
├── variables.tf         # access_entries map + the six globals
├── outputs.tf
├── versions.tf
├── .tflint.hcl
├── README.md            # + "Remote-state key contract" section
├── USAGE.md
├── tests/               # plan suite (the gate)
└── tests-localstack/    # Community apply suite + FINDINGS.md
```

The module is the fourth eks-state consumer, identical in read shape
to `addons` / `pod-identity-access`: `cluster_name` + the six
Terragrunt globals compose the account-scoped key
`<account_name>/<region>/eks/<cluster_name>/terraform.tfstate` with
the standard `assume_role` block; `cluster_name` is read at the use
site per ADR-0001. ADR-0020's consumer table gains the row.

**Why its own module (the OQ 2 amendment):** access entries are the
highest-churn class of cluster-adjacent change — principals onboard,
scopes adjust, break-glass rotates. In the cluster module, every one
of those edits plans against (and locks) the stack that owns the
control plane, the KMS key, and the node SG; a mistake plans
alongside cluster-mutating changes. As its own stack, entry churn is
a small, fast, low-blast-radius plan — the same isolation logic as
`proxy`/`read-replica` against `cluster`, and the same seam
`pod-identity-access` already proves for per-cluster IAM surfaces.

### The entries surface

Per INV-0011 OQ 11a (shape) + OQ 3a (map-of-maps) + OQ 2a (full
ARNs):

```hcl
variable "access_entries" {
  description = "Generic EKS access entries: logical name -> entry. Direct principal ARNs — no resolution. policy_associations (map keyed by logical association name) grant EKS access policies with cluster or namespace scope; kubernetes_groups binds RBAC groups instead of (or alongside) policies."
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string), [])
    user_name         = optional(string)
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = optional(object({
        type       = optional(string, "cluster")
        namespaces = optional(list(string), [])
      }), {})
    })), {})
  }))
  default = {}
}
```

- One `aws_eks_access_entry.this` per map entry (`for_each` on the
  map — logical names are the stable addresses).
- One `aws_eks_access_policy_association.this` per (entry ×
  association), `for_each` over a flattened map keyed
  `"<entry>:<association>"` so adding an association never churns a
  sibling's address (OQ 3a).
- `policy_arn` is the full ARN, prefix-validated against
  `arn:aws:eks::aws:cluster-access-policy/` (OQ 2a) — AWS grows the
  policy catalog without a module release; the validation still
  catches a pasted IAM-policy ARN.
- Full `access_scope { type, namespaces }` — the namespace scoping
  the SSO path lacks.
- Outputs: `access_entry_arns` (map, logical name → entry ARN) and
  `principal_arns` (map, logical name → principal) — operator/
  consumer visibility, pointer-only.
- The README worked example is the platform §4 trio:
  argocd-deployer (assumed `sse-platform-access` role → deploy
  group), break-glass SSO (→ `AmazonEKSClusterAdminPolicy`, cluster
  scope), and the deploy role (see OQ 4's resolution — declared
  here as the durable admin once day-0 completes).

### Access entry validations

- Non-STANDARD entry types (`EC2_LINUX`, `EC2_WINDOWS`, `FARGATE_*`,
  `HYBRID_LINUX`) reject `kubernetes_groups`, `user_name`, and
  `policy_associations` — the EKS API refuses them (INV-0011 F7);
  the validation fails at plan with the API's rule named.
- `principal_arn` must match the IAM role/user ARN shape (the
  fleet's regex conventions; no wildcards).
- Namespace scope requires namespaces: `access_scope.type =
  "namespace"` with an empty `namespaces` list fails at plan.

### Cross-stack SSO collision guard

The SSO singleton lives in the cluster stack; the generic entries
live here — a duplicated principal is now a **cross-stack** conflict
(two owners of one principal's entry fails at apply). The guard:

- `eks/cluster` gains one additive output, `sso_principal_arn` — the
  regex-resolved SSO role ARN when `sso_access_enabled`, else null —
  published into the eks state alongside the existing outputs.
- This module's precondition rejects any `access_entries` entry whose
  `principal_arn` equals the state's `sso_principal_arn`. The read
  is `try()`-null-safe so a cluster state predating the output (the
  stale-state case) degrades to no-guard rather than an error —
  documented in the README with the "re-apply the cluster stack to
  pick up the output" note.

### Day-0 ordering

The entries stack applies **after** the cluster stack (it reads the
eks state). The access floor during that window is the cluster
creator's bootstrap admin entry (part 2, OQ 4): the stable
automation principal that applied the cluster stack retains implicit
admin, so a wrong or absent entries stack can never lock the fleet
out of a fresh cluster. Once the entries stack applies, the declared
map is the durable access surface.

## Detailed Design part 2: the cluster module

### Bootstrap creator admin made explicit

`access_config.bootstrap_cluster_creator_admin_permissions` is
currently unset — the provider default (`true`) applies silently
(INV-0011 F7). Resolved (OQ 4): the argument becomes **explicitly
`true`** (zero diff — the current effective value), paired with an
operational contract the README states plainly:

- The bootstrap admin entry binds to **whatever principal creates
  the cluster** — so cluster applies must run through the **stable
  automation path** (today: Atlantis on the primary cluster under
  its pod-identity role, assuming the per-account deploy role; the
  platform DESIGN-0001 §4 deploy-role path), NOT an ad-hoc operator
  SSO session. An `AWSReservedSSO_*` creator is a rotating
  principal — permission-set changes re-mint the role suffix — and
  its bootstrap entry silently goes stale.
- If a day-0 bring-up does happen from an SSO workstation, the
  resulting bootstrap entry is **disposable**: superseded by the
  declared `eks/access-entries` map and deletable out-of-band once
  the entries stack is green.
- Moving to `false` + an explicit deploy-role entry is the recorded
  follow-up posture decision once the hub pattern burns in
  (feasible per-cluster at create time; the flag forces replacement
  after).

### The endpoint fence

The INV-0011 OQ 12 operator shape, verbatim — the
`endpoint_public_access = true` default and its implicit
`["0.0.0.0/0"]` fence are the unbroken contract:

```hcl
variable "endpoint_public_access_cidrs" {
  description = "Literal CIDR allowlist for the public API endpoint. Default [] — combined with endpoint_public_access_prefix_list_ids into the effective fence; an empty union means the EKS default 0.0.0.0/0 (exactly today's behavior)."
  type        = list(string)
  default     = []
}

variable "endpoint_public_access_prefix_list_ids" {
  description = "Managed prefix lists whose entries are expanded into the public-endpoint fence AT PLAN TIME (the EKS API accepts literal CIDRs only — see the README warning: this is not a live reference like an SG rule; prefix-list edits land on the NEXT apply of this stack)."
  type        = list(string)
  default     = []
}
```

```hcl
data "aws_ec2_managed_prefix_list" "fence" {
  for_each = toset(var.endpoint_public_access_prefix_list_ids)
  id       = each.value
}

locals {
  fence_union = distinct(concat(
    var.endpoint_public_access_cidrs,
    flatten([
      for pl in data.aws_ec2_managed_prefix_list.fence :
      [for e in pl.entries : e.cidr]
    ]),
  ))

  public_access_cidrs = length(local.fence_union) > 0 ? local.fence_union : ["0.0.0.0/0"]
}
```

`vpc_config` gains `public_access_cidrs = local.public_access_cidrs`.
Nothing set → `["0.0.0.0/0"]` → a zero diff for every existing
cluster (the explicit value equals the provider/API default already
in state).

### Fence guards

- **At least one endpoint:** precondition —
  `endpoint_private_access || endpoint_public_access` (a cluster
  with neither is unreachable; the API allows the misconfiguration,
  the module does not).
- **Fence-without-public fails:** either fence input non-empty while
  `endpoint_public_access = false` fails at plan — a fence on a
  disabled endpoint is a misconfiguration, not a silent no-op.
- **The 40-CIDR limit (OQ 5a):** precondition
  `length(local.public_access_cidrs) <= 40`, message naming both
  fence inputs and prefix-list expansion as the usual culprit.
- Spoke posture needs no new mechanics: `endpoint_public_access =
  false` (+ private true) is the private-only shape; the guards make
  it coherent.

### The README warning callout

A prominent callout (the OQ 12 resolution requires it):

- Prefix-list expansion is **plan-time only** — the fence is a
  snapshot of the list at plan; edits to the list do NOT propagate
  until the cluster stack's next apply (unlike an SG
  `prefix_list_id` rule, which is a live reference — the Gateway
  frontend-SG module gets the live version of this pattern).
- The expanded union counts against the EKS 40-CIDR
  public-endpoint limit (guarded at plan, OQ 5a).
- The recorded follow-up for live sync (out-of-band syncer + the
  ignored-fence posture decision) and why conditional
  `ignore_changes` cannot exist (static lifecycle arguments).

## Detailed Design part 3: the node group module

### The workload class input

INV-0011 OQ 13 as amended (core default confirmed; `analytics`
confirmed at this review, OQ 1a):

```hcl
variable "workload_class" {
  description = "Platform workload class for this node group. Drives the workload-class label (always), the workload-class=<class>:NO_SCHEDULE taint (every class EXCEPT core — core is the untainted default landing zone), and the gVisor default (secure only). The class taxonomy is the platform's (DESIGN-0001 section 2); new classes are deliberate one-line enum additions here, never free-form."
  type        = string
  default     = "core"
  nullable    = false

  validation {
    condition     = contains(["core", "observability", "analytics", "temporal", "secure"], var.workload_class)
    error_message = "workload_class must be one of core, observability, analytics, temporal, secure (the platform class taxonomy; adding a class is a module change, not a caller string)."
  }
}

variable "gvisor_enabled" {
  description = "Nullable override for the gVisor runtime install + runtime=gvisor labeling + kubelet fragments. Null (default) = the class rule: enabled iff workload_class == \"secure\". Set true/false to override for the odd case (e.g. a sandboxed analytics pool)."
  type        = bool
  default     = null
}
```

The closed enum is deliberate: typos fail at plan, the platform
opinion of which classes exist lives here, and the enum is
deliberately cheap to extend — one value + its baked rule, no
structural change (the recorded answer to DESIGN-0001's "a label
change, not a redesign" split promise).

### Per-class baked rules

```text
class          label workload-class=   taint <class>:NO_SCHEDULE   gVisor default
core           core                    NO (default landing zone)   off
observability  observability           yes                         off
analytics      analytics               yes                         off
temporal       temporal                yes                         off
secure         secure                  yes                         on
```

Effective gVisor: `coalesce(var.gvisor_enabled, var.workload_class ==
"secure")`. The `runtime = "gvisor"` label rides the effective gVisor
state, not the class (a gVisor-enabled analytics pool advertises the
runtime; a gVisor-disabled secure pool must not lie).

### Threading the five hardwired sites

The F8 sites, threaded together in one change:

1. **`locals.tf` labels:** `"workload-class" = var.workload_class`
   always; `"runtime" = "gvisor"` becomes conditional on effective
   gVisor (merged in only when on).
2. **`main.tf` taint block:** the static block becomes a
   `dynamic "taint"` gated on `workload_class != "core"`, emitting
   `workload-class=<class>:NO_SCHEDULE`. `additional_taints` layering
   is unchanged.
3. **The user-data template kubelet flags:** the label list and
   `--register-with-taints` are string literals today — the template
   gains `workload_class`, `taint_enabled`, and `gvisor_enabled`
   inputs: the node-label fragment always carries
   `workload-class=<class>` (+ `runtime=gvisor` only when effective),
   and the `--register-with-taints=workload-class=<class>:NoSchedule`
   fragment renders only for tainted classes (kubelet spells it
   `NoSchedule`; the API side stays `NO_SCHEDULE` — the existing
   spelling split, now templated).
4. **The gVisor install MIME part:** the unconditional shellscript
   part (download + SHA-512 verify + containerd drop-in + restart +
   plugin assert) gates on effective gVisor — the whole part is
   absent when off (no dead install on core nodes), the same
   part-gating mechanism the ECR-mirror part already uses.
5. **`outputs.node_taints`** derives from the same rule (empty
   class-taint for core), and the two variable descriptions that bake
   "workload-class=secure" wording are rewritten class-neutral.

### Output changes

`node_labels` and `node_taints` become class-derived (same names, no
contract break — their values were always the group's actual
labels/taints). Downstream chart tooling reading them via remote
state sees the truth per class.

### The default-behavior change

`workload_class = "core"` is a **deliberate default-behavior change**
from the hardwired secure posture (INV-0011 OQ 13, operator-confirmed
2026-08-14): there are zero live consumers built from this module
that cannot be rebuilt, so the lower-entry default lands now. A
default invocation produces an untainted, gVisor-less core group —
NOT today's secure posture. Consequences, recorded honestly:

- Existing plan suites asserting the secure label/taint literally are
  **rewritten** into the per-class matrix (they pinned the old
  default; the pin moves to the explicit-secure run).
- The platform rollup's "default remains secure" line and its
  zero-diff success criterion are amended platform-side (INV-0011 F1
  batch 3, conflict 1 — already flagged to the operator).
- The release is a **minor** bump with a prominent
  default-change note (pre-1.0 semver; the README and CHANGELOG both
  carry it), since nothing consumes the old default.

## Testing Strategy

**Access entries module (`tests/` + `tests-localstack/`):**

- Plan suite (the established eks-consumer pattern:
  real-provider-fake-creds with `override_data` stubbing the eks
  state read): a three-entry hub-shaped run (the §4 trio) pinning
  entry attributes, association scoping, and the flattened
  association addresses; validation failures via `expect_failures`
  (non-STANDARD with groups, namespace scope without namespaces, bad
  ARN, bad policy-ARN prefix); the SSO-collision precondition (state
  stub carrying `sso_principal_arn`) plus its null-safe stale-state
  run; the ADR-0020 key assertion.
- Community apply: `fixtures/setup` seeds an eks state (the
  addons-style bespoke fixture) or composes the real cluster module;
  applies entries + associations where 4.4 supports the API —
  access-entry parity on Community is the probe-worthy edge,
  FINDINGS.md records it either way.

**Cluster plan suite additions (`tests/`):**

- Endpoint fence: default run pins `public_access_cidrs ==
  ["0.0.0.0/0"]` (the unbroken contract — this is the zero-diff
  replan invariant in test form); literal-CIDR run; prefix-list run
  with `override_data` stubbing the expansion; union + dedup run;
  the three guard failures (no-endpoint, fence-without-public,
  over-40); private-only spoke run.
- `bootstrap_cluster_creator_admin_permissions` pinned explicitly
  true; `sso_principal_arn` output on and off (null when SSO
  disabled); the SSO singleton pinned **by address** unchanged.

**Node group plan suite (`tests/`):** the per-class matrix —

- The **core default** run (untainted, no gVisor part, labels
  correct) AND the **explicit secure** run (the full current posture:
  label + taint + gVisor — the operator-required regression, "needs
  to be dialed").
- One run per remaining class (tainted, no gVisor), the
  `gvisor_enabled` override in both directions, enum rejection,
  `additional_taints`/`additional_labels` layering per class.
- User-data assertions (OQ 6a): decode the launch template's
  `user_data` per class — the kubelet label fragment carries the
  class, the register-with-taints fragment present/absent per class,
  the gVisor MIME part present/absent per effective-gVisor. First
  user-data coverage in the fleet, landing exactly when the template
  becomes conditional.

**LocalStack apply (Community 4.4):** the existing EKS Community
applies extend — a fence apply run where 4.4 supports
`public_access_cidrs`; class-parameterized node-group apply (core +
secure). FINDINGS.md records parity gaps (the fleet discipline is
assert-what-round-trips, record the rest).

## Phases

### Phase 1: The access entries module

- [ ] Scaffold `modules/eks/access-entries` (versions, tflint,
      README skeleton, the six globals + `cluster_name`)
- [ ] eks remote-state read (account-scoped key + `assume_role`)
- [ ] `access_entries` map + flattened associations + validations
- [ ] SSO-collision precondition (null-safe `try()` read)
- [ ] Plan suite; `just changed` pickup verification; README §4
      worked example (argocd-deployer / break-glass / deploy role)

### Phase 2: Cluster changes

- [ ] `sso_principal_arn` additive output
- [ ] Fence variables + prefix-list data + union locals +
      `public_access_cidrs` wiring
- [ ] Guards (at-least-one-endpoint, fence-without-public, 40-CIDR)
- [ ] Explicit `bootstrap_cluster_creator_admin_permissions = true`
      + the stable-creator README contract (OQ 4)
- [ ] Plan additions incl. the default-fence zero-diff pin; README
      warning callout

### Phase 3: Workload classes

- [ ] `workload_class` enum + per-class locals; thread sites 1/2/5
      (labels, taint block, outputs, descriptions)
- [ ] Template threading for site 3 (labels + register-with-taints)
- [ ] Per-class plan matrix (core default + explicit secure + the
      rest)

### Phase 4: gVisor toggle and user-data assertions

- [ ] `gvisor_enabled` + effective-gVisor coalesce; gate site 4 (the
      install MIME part) + the runtime label + kubelet fragments
- [ ] User-data assertions (OQ 6a)
- [ ] Override-direction plan runs

### Phase 5: Closure

- [ ] LocalStack apply suites (new module fixture + extensions) +
      FINDINGS.md probes, run live
- [ ] READMEs; CLAUDE.md eks section updates (the new module, the
      load-bearing change-bar note, the class taxonomy, the default
      change); ADR-0020 consumer row for the new module
- [ ] INV-0011 delivery note; `docz update` (+ mangle-set restore)
- [ ] Conventional commits; PRs labeled `minor` with the
      default-change note prominent

Success criteria: `just static` + all three modules' plan gates
green; every existing cluster-module run green unchanged; the
node-group matrix green with the secure run asserting today's full
posture byte-for-byte; live Community applies green; zero-diff
replan demonstrated for a fence-default cluster.

## Open Questions

> **All resolved 2026-08-27: 1a, 2a (amended — own module), 3a,
> 4 (Other — explicit true + the stable-creator contract), 5a, 6a.**
> The Detailed Design above is written to the resolved shapes,
> including the OQ 2 amendment (the `eks/access-entries` module) and
> the OQ 4 operational contract.

### 1. What is the fifth class named?

**Resolved: a.** `analytics` is final (also recorded in INV-0011
OQ 13).

- **a. (Recommended)** `analytics` — the split peels ClickHouse +
  Langfuse off `observability` (Loki stays with the o11y stack, the
  operator's cut line), so the new class names what moves. Minimal
  relabel churn at split time; `observability` keeps meaning the
  o11y stack throughout.
- b. `monitoring` (platform DESIGN-0001's wording) — but under the
  resolved cut line it would relabel the entire o11y stack at split
  time while analytics inherited the `observability` name: maximum
  churn, inverted semantics. Requires the platform doc amendment
  either way (its cut line puts Loki on the wrong side).
- Other: (your call)

### 2. What form do policy associations take?

**Resolved: a, amended — the generic entries surface moves to a NEW
`eks/access-entries` module** (operator direction at review:
"any access entry updates dont touch the whole cluster"). Entry
churn gets its own state, plan cadence, and blast radius; the
cluster module's only access-surface change is the additive
`sso_principal_arn` output feeding the cross-stack collision guard.
Detailed Design part 1 carries the module; INV-0011 OQ 11 records
the amendment.

- **a. (Recommended)** Full policy ARN with a prefix validation
  (`arn:aws:eks::aws:cluster-access-policy/`). AWS grows the policy
  catalog independently of this module (Edit, AutoNode, and future
  policies beyond the SSO path's three-policy allowlist); an ARN
  passthrough never needs a module release to use a new policy, and
  the prefix validation still catches pasting an IAM policy ARN by
  mistake. The SSO path's short-name allowlist stays as-is — its
  three-policy scope is its feature.
- b. Short policy names composed + allowlist-validated (SSO parity) —
  friendlier call sites, but the allowlist rots as AWS adds
  policies, and every addition is a module release for a string.
- Other: (your call)

### 3. What collection shape do access entries use?

**Resolved: a.**

- **a. (Recommended)** Map-of-maps: `access_entries` keyed by logical
  entry name, `policy_associations` keyed by logical association
  name, flattened to `"<entry>:<assoc>"` keys for the association
  `for_each`. Stable addresses under every add/remove (the fleet's
  `for_each`-over-typed-map convention — the `read-replica` replicas
  map precedent); plan diffs read as named intentions.
- b. `policy_associations` as a list — matches the INV sketch and
  reads slightly leaner at call sites, but list-index addressing
  churns sibling associations on removal (the exact `count`/index
  pathology the fleet convention exists to avoid).
- Other: (your call)

### 4. What happens to bootstrap creator admin?

**Resolved: Other — explicit `true` plus the stable-creator
operational contract.** The operator's analysis: option a's
"break-glass floor" only holds if the creating principal is stable.
A cluster created from an operator workstation under an AWS SSO
session binds the bootstrap admin entry to an `AWSReservedSSO_*`
role — a rotating principal (permission-set changes re-mint the
suffix), and admin tied to a person's session besides. The
sanctioned path is therefore the **automation principal**: Atlantis
(running on the existing primary cluster) under its pod-identity
role — "which we can then just make sure to keep" — assuming the
per-account deploy role (the platform DESIGN-0001 §4 path). The
argument becomes explicitly `true`; the README states the contract
(create via the stable path; an SSO-created bootstrap entry is
disposable — superseded by the declared entries and deletable
out-of-band); moving to `false` + an explicit deploy-role entry
stays the recorded follow-up once the hub pattern burns in.

- a. Set it explicitly `true` (the current effective value — zero
  diff), documented as the deliberate floor. *(Adopted, with the
  contract above.)*
- b. Flip to `false` + an explicit deploy-role entry in
  `access_entries` — fully declarative, but makes day-0 depend on
  the newest surface in the fleet, and a wrong entry strands a fresh
  cluster.
- c. Expose it as a variable defaulting `true` — a
  replacement-forcing knob with a silent-footgun default; postures,
  not knobs.
- Other: (your call)

### 5. Is the 40-CIDR union guarded at plan?

**Resolved: a.**

- **a. (Recommended)** Yes — a precondition:
  `length(local.public_access_cidrs) <= 40`, message naming both
  fence inputs and the prefix-list expansion as the usual culprit.
  The union is plan-known (literal CIDRs + plan-time expansion), the
  API failure it preempts arrives only at apply with a vaguer
  message, and fat prefix lists (a corporate egress list) hit 40
  faster than operators expect.
- b. Let the EKS API reject it at apply — one less precondition, but
  a plan-knowable failure deferred to apply is the exact class of
  gap the fleet's plan-test discipline exists to close.
- Other: (your call)

### 6. Do user-data assertions land now?

**Resolved: a.**

- **a. (Recommended)** Yes — the per-class plan matrix asserts the
  rendered template (decode the launch template's `user_data`):
  the kubelet label fragment carries the class, the
  register-with-taints fragment present/absent per class, the gVisor
  MIME part present/absent per effective-gVisor. First user-data
  coverage in the fleet, arriving exactly when the template becomes
  conditional — regressions here are silent node-bootstrap breakage,
  the worst failure class to discover at apply.
- b. Defer — keep the matrix to resource attributes (labels/taints
  on the node group resource) and trust the template by review.
  Cheaper, but the two kubelet literals were F8's most-buried sites;
  leaving them untested after making them conditional repeats the
  original mistake with more moving parts.
- Other: (your call)

## References

- **INV-0011** — the parent investigation: F7 (the SSO singleton,
  the missing CIDR hook, the silent bootstrap default), F8 (the five
  hardwired sites), F2 (provider probe: access entries,
  `public_access_cidrs` set-of-strings, `access_config`), OQ 11a as
  amended (the `eks/access-entries` module) / OQ 12 (operator shape,
  incl. the ignore-changes infeasibility) / OQ 13 as amended (core
  default confirmed, the five-class enum with `analytics` final,
  the split-seam cut line), F1 batches 1–4 (the platform
  distillations this Background section summarizes).
- Platform ADR-0011 (external) — Terraform + ArgoCD bootstrap as the
  cluster path; the load-bearing change bar.
- Platform DESIGN-0001 (external) — §2 node groups, §4 IAM
  principals, the private-spoke endpoint assumption, the
  registration-secret boundary.
- DESIGN-0001 / IMPL-0002, ADR-0005..0012 — the secure node posture
  this module generalizes (gVisor, taints, AL2023, IMDS, ON_DEMAND).
- DESIGN-0002 / IMPL-0001 (Q3, Q7, Q8, Q11), DESIGN-0015 — the
  cluster access surface heritage, the endpoint-default drift
  record, the subnet-tier rewire (sequenced separately).
- DESIGN-0004 / IMPL-0004 — `eks/pod-identity-access`: the
  per-cluster-surface-as-own-module precedent the access-entries
  module follows; ADR-0020 — the eks consumer table it joins.
- INV-0011 F1 batch 4 — the Gateway frontend-SG module (the LIVE
  prefix-list counterpart to this design's plan-time fence; queued
  separately).
