---
id: ADR-0011
title: "RuntimeClass delivered out-of-band, not by Terraform"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0011. RuntimeClass delivered out-of-band, not by Terraform

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
- [Consequences](#consequences)
  - [Positive](#positive)
  - [Negative](#negative)
  - [Neutral](#neutral)
- [Alternatives Considered](#alternatives-considered)
- [References](#references)
<!--toc:end-->

## Status

Accepted

## Context

The gVisor `RuntimeClass` is the Kubernetes object workloads reference
to opt into the sandboxed runtime:

```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
scheduling:
  nodeSelector:
    workload-class: secure
    runtime: gvisor
  tolerations:
    - key: workload-class
      value: secure
      operator: Equal
      effect: NoSchedule
```

The `handler: runsc` field binds to the containerd runtime handler
that the node-group module's user data registers via
`/etc/containerd/config.d/runsc.toml` (ADR-0005, ADR-0008). The
`scheduling` block injects the node-group's label selector and
toleration into any pod that sets `spec.runtimeClassName: gvisor`.

The question is *who creates this object* and *via which control
plane*.

A draft of this ADR placed creation inside the node-group Terraform
module using `kubernetes_manifest`, gated by `var.create_runtime_class`.
That shape was rejected on review because it would have introduced
the first Kubernetes provider into an otherwise AWS-API-only Terraform
fleet:

- The `kubernetes` provider needs cluster credentials at apply time
  (`host`/`cluster_ca_certificate`/`exec` plugin to `aws eks
  get-token`).
- The Terraform runner's IAM principal must be mapped to a Kubernetes
  RBAC subject via an EKS Access Entry — a new requirement on CI
  runners and operator workstations.
- Cluster recreation invalidates the Terraform state row for the
  `RuntimeClass`; a torn-down-and-rebuilt cluster leaves stale state.
- The cluster apply must precede the node-group apply (already true),
  *and* the access entry must exist *and* be propagated before the
  node-group module's `kubernetes_manifest` resource can plan
  cleanly.

The fleet's standing principle is: **Terraform modules manage AWS API
resources only. Kubernetes-API objects are delivered out-of-band.**
Pod Identity Associations look Kubernetes-y but are AWS API objects
(`aws_eks_pod_identity_association`) — they stay in Terraform. EKS
managed addons are also AWS API objects (`aws_eks_addon`) — they
stay in Terraform. The boundary is "is this an AWS API call or a
Kubernetes API call?", not "does this conceptually relate to
Kubernetes?"

`RuntimeClass` is a Kubernetes API object with no AWS-side
counterpart. By that boundary it does not belong in Terraform.

## Decision

The secure managed-node-group module **does not** create the
`RuntimeClass`. There is no `kubernetes_manifest` resource, no
`var.create_runtime_class` toggle, and no `kubernetes` provider
configured for this module. The module's responsibility ends at the
AWS-side contract: provision the node group, install gVisor, register
the `runsc` containerd handler, apply the labels and taints the
`RuntimeClass` will match.

`RuntimeClass` delivery is a **consumer responsibility**, applied
out-of-band via one of:

- `kubectl apply -f` (one-shot during cluster bootstrap; suitable for
  homelab / dev clusters and for environments without a GitOps tool).
- An Argo CD `Application` rendering a Kustomize overlay (the
  recommended production posture; matches how other cluster-scoped
  Kubernetes manifests — NetworkPolicies, admission webhooks,
  Gatekeeper templates — flow into clusters).

The module's `README.md` documents the requirement with copy-paste
examples for both delivery mechanisms. The `RuntimeClass` manifest
itself lives in the consumer's repository (Argo's `applications/`
tree, a bootstrap repo, or whatever the consumer's manifest layout
calls for), not in this module.

The `RuntimeClass` is cluster-scoped — one object named `gvisor` per
cluster, regardless of how many secure-node-group instantiations the
cluster runs. Mixed-architecture clusters (`arm64` + `amd64` both
instantiating this module) still need exactly one `RuntimeClass`
applied. The out-of-band delivery handles this naturally: kubectl /
Argo applies it once per cluster, not once per node group. The
Terraform-coordination problem the rejected `var.create_runtime_class`
toggle was solving doesn't exist in the out-of-band shape.

The labels the `RuntimeClass.scheduling.nodeSelector` matches
(`workload-class=secure`, `runtime=gvisor`) and the taint it tolerates
(`workload-class=secure:NoSchedule`) are both applied by the
node-group module's `aws_eks_node_group` resource. The
`RuntimeClass`'s `handler: runsc` matches the containerd handler the
user data registers. None of these values are Terraform outputs of
the module — they are stable constants documented in the module's
README so the consumer's manifest can reference them verbatim.

## Consequences

### Positive

- **Terraform stays AWS-only.** No `kubernetes` provider, no
  cluster-API auth coupling, no cross-API state in any module. The
  AWS-only-Terraform principle from ADR-0001 stays clean across the
  fleet.
- **No EKS Access Entry needed for the Terraform runner.** Operator
  workstations and CI runners that apply Terraform don't need
  cluster RBAC. Cluster access is for cluster-manifest delivery
  (kubectl / Argo), and that's a separately-scoped set of
  principals.
- **Cluster recreation doesn't leave stale Terraform state.** The
  `RuntimeClass` row that would have lived in this module's state
  file isn't there; tearing down and rebuilding a cluster doesn't
  drift the node-group module's state.
- **Single delivery mechanism for cluster-scoped manifests.** When
  the next cluster-scoped Kubernetes object appears (a
  `NetworkPolicy` gating egress from secure pods, an admission
  webhook, a Gatekeeper constraint template), it flows through the
  same kubectl / Argo path. One place to look for "what cluster-
  scoped manifests apply to this cluster."
- **No `var.create_runtime_class` footgun.** The toggle in the
  rejected shape failed open in messy ways (multiple instantiations
  both creating, both destroying, etc.). The out-of-band shape has
  no toggle to forget.

### Negative

- **The secure node group isn't fully self-contained in Terraform.**
  A consumer who applies the module without separately applying the
  `RuntimeClass` gets a working node group with no way for workloads
  to opt into gVisor. The pods schedule, but `runtimeClassName:
  gvisor` references a non-existent object. Mitigated by the module
  README documenting the requirement explicitly; not eliminated.
- **Coordination across Terraform + manifest tooling becomes the
  consumer's responsibility.** The "apply the cluster, then apply
  the node group, then apply the manifests" ordering is now a
  consumer-side runbook (or an Argo sync wave), not Terraform's
  `depends_on` graph.
- **Module README has to stay correct.** The label values, taint
  values, and handler name in the module's user data and labels
  must match what the consumer's manifest expects. Module-side
  changes to any of those are README updates the consumer has to
  catch. libtftest can assert *that the module applies the expected
  labels / taints*; it can't assert that the consumer's manifest
  uses the matching values.

### Neutral

- **The decision is per-fleet, not per-cluster.** Every cluster in
  the fleet receives its `RuntimeClass` via kubectl or Argo+Kustomize;
  there is no "some clusters use Terraform, some don't" split.
- **Argo + Kustomize is the recommended production path.** kubectl
  is documented for completeness but production clusters get the
  manifest via GitOps, in line with the broader fleet direction for
  cluster-scoped Kubernetes state.
- **The example manifest in the module README is *the* manifest.**
  No generation, no templating from Terraform outputs — the values
  are constants. The module README contains the YAML; the consumer
  pastes it into their manifest repo.

## Alternatives Considered

**Have the node-group Terraform module create the `RuntimeClass` via
`kubernetes_manifest`.** Was the working draft of this ADR until
review. Rejected on the AWS-only-Terraform principle described in
Context. The full set of objections:

- Introduces a Kubernetes provider into a single module in an
  otherwise AWS-API-only fleet.
- Couples the Terraform runner's IAM to cluster RBAC via EKS Access
  Entries.
- Stale Terraform state on cluster recreation.
- Creates a `var.create_runtime_class` coordination problem for
  multi-instantiation clusters that the out-of-band shape doesn't
  have.

**Have the cluster Terraform module create the `RuntimeClass`.** Same
provider problem, plus a different module's cross-coupling: the
cluster module would need to know the node-group's labels, taints,
and handler name. Wrong direction of dependency. Rejected.

**Have the addons Terraform module create the `RuntimeClass`.** Same
provider problem. Additionally violates the addons module's
constraint that every resource in it is an `aws_eks_addon` + its IAM
scaffolding (ADR-0003, ADR-0004). Rejected.

**Use a `local-exec` provisioner shelling out to `kubectl apply`.**
Technically keeps the Terraform module list-of-providers clean. In
practice it's worse: same auth coupling, same cluster-recreation
state-staleness, less Terraform-native dependency-graph behavior, no
clean drift detection. The `kubernetes_manifest` path is at least
honest about what it's doing. Rejected.

**Helm chart owned by the module via `helm_release`.** Wraps the
manifest in a chart for one resource — same provider problem, plus a
chart to maintain for a single object. Rejected as both
over-engineered and on principle.

**Bake the `RuntimeClass` into a cluster-bootstrap Terraform module
that owns *only* Kubernetes provider operations.** Decomposes the
provider boundary onto a single module. Rejected because it still
introduces the Kubernetes provider to this Terraform fleet for one
object, which is the wall we're trying to keep clean. If the fleet
ever has enough cluster-scoped Kubernetes state that GitOps becomes
heavyweight overkill, this becomes worth revisiting; not now.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state`
  (the AWS-only-Terraform / pure-functions principle this ADR
  upholds).
- ADR-0005 — gVisor as the syscall sandboxing runtime (the
  `handler: runsc` value the consumer's manifest matches comes from
  the user-data containerd registration).
- ADR-0006 — ARM64 Graviton as default (the `RuntimeClass` is
  intentionally arch-agnostic; multi-arch clusters apply one
  `RuntimeClass`).
- ADR-0008 — AL2023 only (the containerd handler the
  `RuntimeClass.handler` field references is registered by the
  AL2023-shaped user data).
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (the
  `RuntimeClass` shape + handler / nodeSelector / toleration constants
  live in §"RuntimeClass (out-of-band, consumer responsibility)"; the
  module README provides the kubectl and Argo+Kustomize examples).
- Kubernetes RuntimeClass:
  <https://kubernetes.io/docs/concepts/containers/runtime-class/>
- Argo CD Application + Kustomize:
  <https://argo-cd.readthedocs.io/en/stable/user-guide/kustomize/>
