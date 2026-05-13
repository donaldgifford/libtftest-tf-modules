---
id: DESIGN-0001
title: "Secure EKS Managed Node Group with gVisor"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0001: Secure EKS Managed Node Group with gVisor

**Status:** Accepted
**Author:** Donald Gifford
**Date:** 2026-05-13

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Cross-module wiring (remote state)](#cross-module-wiring-remote-state)
  - [Module layout](#module-layout)
  - [Architecture-driven inputs (hoisted to Boilerplate)](#architecture-driven-inputs-hoisted-to-boilerplate)
  - [Minimal node IAM](#minimal-node-iam)
  - [Launch template hardening](#launch-template-hardening)
  - [User data (multipart MIME)](#user-data-multipart-mime)
  - [EKS node group](#eks-node-group)
  - [RuntimeClass (out-of-band, consumer responsibility)](#runtimeclass-out-of-band-consumer-responsibility)
- [API / Interface Changes](#api--interface-changes)
  - [Required inputs](#required-inputs)
  - [Key optional inputs](#key-optional-inputs)
  - [Outputs](#outputs)
- [Data Model](#data-model)
  - [Resource inventory](#resource-inventory)
  - [Required providers](#required-providers)
- [Testing Strategy](#testing-strategy)
  - [Static validation (libtftest, LocalStack-backed)](#static-validation-libtftest-localstack-backed)
  - [Integration validation (post-deploy on a dev cluster)](#integration-validation-post-deploy-on-a-dev-cluster)
  - [Workload compatibility evaluation procedure](#workload-compatibility-evaluation-procedure)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [Resolved by ADRs](#resolved-by-adrs)
  - [Still open / deferred](#still-open--deferred)
- [References](#references)
  - [ADRs that constrain this module](#adrs-that-constrain-this-module)
  - [Sibling designs](#sibling-designs)
  - [Module-level docs](#module-level-docs)
  - [External](#external)
<!--toc:end-->

## Overview

A reusable Terraform module that provisions an EKS managed node group hardened
for security-aware workloads: minimal node IAM, IMDSv2-only with hop limit 2,
gVisor (`runsc`) as the opt-in container runtime, and architecture-pinned
scheduling (ARM64/Graviton or x86_64). The decision set this design implements
is in ADR-0001..0012; the IAM posture specifically is captured in ADR-0002
and the gVisor runtime in ADR-0005.

## Goals and Non-Goals

### Goals

- Provision an EKS managed node group with a single `architecture` input
  driving AMI type, instance families, gVisor binary, and arch labels.
  ARM64/Graviton is the default (ADR-0006); AL2023 is the only supported
  AMI family (ADR-0008).
- Enforce four security properties at the node-group level: minimal node
  IAM (ADR-0002), IMDSv2-required with hop-limit 2 (ADR-0007), gVisor
  runtime (`runsc`) for opt-in workloads (ADR-0005), and
  architecture-pinned scheduling via labels and taints.
- Default to `ON_DEMAND` capacity to match the workload class's reliability
  expectations and amortize the per-node gVisor bootstrap (ADR-0009).
- Pin `gvisor_release` in production via Renovate-managed bumps in the live
  repo (ADR-0010).
- Route workloads onto the node group exclusively via an opt-in
  `RuntimeClass` (`gvisor`) and a `workload-class=secure:NoSchedule` taint.
  The `RuntimeClass` itself is **not created by this module** — see
  ADR-0011; delivered out-of-band via kubectl or Argo+Kustomize.
- Support both ARM64 (Graviton, recommended default) and x86_64 in mixed
  clusters by instantiating the module twice; the cluster receives one
  shared `RuntimeClass` via the out-of-band delivery path.

### Non-Goals

- Managing the EKS cluster itself — handled by the cluster module
  (DESIGN-0002).
- Provisioning Pod Identity Associations for managed addons or workload
  controllers — handled by the addons module (DESIGN-0003) and the pod-identity
  access module (DESIGN-0004).
- Creating Kubernetes-API objects — Terraform manages AWS API resources
  only; the `RuntimeClass` (and any future cluster-scoped K8s objects)
  is delivered out-of-band (ADR-0011).
- Hosting workloads that require `hostNetwork: true` — sandboxing and host
  networking are mutually exclusive; use a different node group.
- GPU passthrough, Bottlerocket AMI variants, or AL2 fallback — AL2023 only
  (ADR-0008).

## Background

This is the secure-workload node pool for clusters that already host general
workloads. The hardening properties combine published EKS best practices
(IMDSv2, KMS-encrypted EBS, minimal IAM) with syscall-level sandboxing via
gVisor to defend multi-tenant or untrusted code paths.

The minimum node IAM set is defined in ADR-0002:
`AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly`, with
`AmazonSSMManagedInstanceCore` as an opt-in third policy (ADR-0012).
Crucially, `AmazonEKSWorkerNodePolicy` already includes
`eks-auth:AssumeRoleForPodIdentity` — that is what the Pod Identity Agent uses
to vend tokens to pods, and it is why **the agent itself needs no
addon-level IAM role** (ADR-0003).

This minimal property only holds once cluster addons and workload controllers
have been migrated to Pod Identity Associations on their service accounts.
This module does not provision those associations itself (see DESIGN-0003 and
DESIGN-0004); it depends on them existing on the cluster it joins.

Hop limit 2 is a **hard requirement** of the Pod Identity credential
model — pod-network pods reach the Pod Identity Agent at
`169.254.170.23` by crossing two hops out of their pod netns. ADR-0007
covers this in full: `hop_limit = 1` is not a valid value while Pod
Identity is the credential model, and the residual IMDS-exposure
concern is neutralized by the minimal node role from ADR-0002, not by
the hop limit.

## Detailed Design

### Cross-module wiring (remote state)

The node group module does *not* take the cluster's identifying outputs as
direct inputs. All cluster-side data (cluster name, endpoint, CA, node
security group, KMS key) is read from the cluster module's remote state in
S3, using the convention documented in DESIGN-0002:

```hcl
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region = var.region
  }
}

data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region = var.region
  }
}
```

Reads happen at the use site (ADR-0001) — e.g., in `aws_eks_node_group.this`:

```hcl
resource "aws_eks_node_group" "this" {
  cluster_name = data.terraform_remote_state.eks.outputs.cluster_name
  subnet_ids   = data.terraform_remote_state.vpc.outputs.private_subnet_ids
  # …
}

resource "aws_launch_template" "node" {
  vpc_security_group_ids = [data.terraform_remote_state.eks.outputs.node_security_group_id]
  block_device_mappings {
    ebs {
      kms_key_id = data.terraform_remote_state.eks.outputs.kms_key_arn
      # …
    }
  }
  # …
}
```

No aliasing locals — every cluster/VPC value is read where it's used.

### Module layout

```
modules/eks/managed-node-group/
├── main.tf              # node group
├── iam.tf               # minimal node role + instance profile
├── launch_template.tf   # IMDSv2, encryption, user data, monitoring
├── locals.tf            # arch-derived locals (ami_type, gvisor_arch, defaults)
├── user_data.tf         # user data template rendering
├── variables.tf
├── outputs.tf
├── versions.tf
└── templates/
    └── user_data.sh.tftpl
```

### Architecture-driven inputs (hoisted to Boilerplate)

Per ADR-0001, arch-derived values are **not** computed inside the module
via `locals`. The Boilerplate-generated Terragrunt config that consumes
this module computes them once and passes them in as a fully-formed
`architecture` input object (or a flat set of vars — caller's choice):

```hcl
# Example shape, generated by Boilerplate from a single `architecture = "arm64"`
# input in the live-repo Terragrunt config:
architecture = {
  name                   = "arm64"           # "arm64" | "amd64"
  ami_type               = "AL2023_ARM_64_STANDARD"
  gvisor_arch            = "aarch64"         # "aarch64" | "x86_64"
  k8s_arch               = "arm64"           # "arm64" | "amd64"
  default_instance_types = ["m7g.large", "m7g.xlarge", "c7g.large", "c7g.xlarge"]
}
```

| Field | `arm64` | `amd64` |
|---|---|---|
| `ami_type` | `AL2023_ARM_64_STANDARD` | `AL2023_x86_64_STANDARD` |
| `gvisor_arch` | `aarch64` | `x86_64` |
| `k8s_arch` | `arm64` | `amd64` |
| `default_instance_types` | `m7g/c7g` family | `m7i/c7i` family |

Instance-type validation against the chosen architecture lives in the
module's `variable` block (so a malformed Boilerplate object is rejected
at plan time):

```hcl
variable "architecture" {
  type = object({
    name                   = string
    ami_type               = string
    gvisor_arch            = string
    k8s_arch               = string
    default_instance_types = list(string)
  })
  validation {
    condition     = contains(["arm64", "amd64"], var.architecture.name)
    error_message = "architecture.name must be 'arm64' or 'amd64'."
  }
}
```

This keeps the module a thin shell around the EKS resource and pushes the
arch table into the live repo where operators can review it.

### Minimal node IAM

Per ADR-0002, the node instance role carries only
`AmazonEKSWorkerNodePolicy` and `AmazonEC2ContainerRegistryPullOnly`.
Optional `AmazonSSMManagedInstanceCore` toggles via `var.enable_ssm`
(off by default per ADR-0012). The agent's
`eks-auth:AssumeRoleForPodIdentity` permission comes *for free* with
`AmazonEKSWorkerNodePolicy` — no addon-level role required (ADR-0003).
Explicitly **not** attached:

- `AmazonEKS_CNI_Policy` — moves to the `aws-node` SA via Pod Identity (addons
  module).
- `AmazonEBSCSIDriverPolicy` / `AmazonEFSCSIDriverPolicy` / `AmazonFSxFullAccess`
  — move to CSI controller SAs via Pod Identity (addons module).
- `CloudWatchAgentServerPolicy`, GuardDuty agent policies — move to their SAs
  via Pod Identity (addons module).
- Any inline policies for cert-manager, external-dns, ALB controller,
  cluster-autoscaler, external-secrets, Velero, etc. — move to workload SAs
  via Pod Identity (pod-identity-access module).

End state (ADR-0002): two managed policies on the node role, no inline
policies, every controller and addon on its own narrowly-scoped Pod Identity
role.

### Launch template hardening

- `metadata_options` (ADR-0007): `http_tokens = required`,
  `http_put_response_hop_limit = 2`, `instance_metadata_tags = enabled`.
- EBS root volume: `gp3`, `encrypted = true`, KMS key from the cluster
  module's remote state (`data.terraform_remote_state.eks.outputs.kms_key_arn`),
  `delete_on_termination = true`.
- `monitoring.enabled = true`.
- `vpc_security_group_ids` from the cluster module's remote state
  (`data.terraform_remote_state.eks.outputs.node_security_group_id`).
- `lifecycle.create_before_destroy = true`.

### User data (multipart MIME)

Per ADR-0005 (gVisor as the syscall sandboxing runtime) and ADR-0008
(AL2023 only), the user data is AL2023-shaped: AL2023 nodeadm bootstrap,
containerd 1.7+ drop-in at `/etc/containerd/config.d/`, `/usr/local/bin/`
binary placement.

Renders `templates/user_data.sh.tftpl` with `gvisor_arch`, `gvisor_release`,
cluster name/endpoint/CA, and `extra_kubelet_args`. The script:

1. Downloads `runsc` and `containerd-shim-runsc-v1` for `gvisor_arch` from
   `https://storage.googleapis.com/gvisor/releases/<release>/<arch>` and
   verifies SHA-512. `gvisor_release` is pinned to a dated immutable tag
   in production per ADR-0010 (Renovate-managed bumps).
2. Writes a containerd drop-in at `/etc/containerd/config.d/runsc.toml`
   registering the `runsc` runtime handler. This drop-in path requires
   containerd 1.6+ with `imports` support — AL2023 ships 1.7+.
3. Writes `/etc/containerd/runsc.toml` with `platform = "systrap"`,
   `network = "sandbox"`.
4. Restarts containerd and asserts the `runsc` plugin is loaded.

`systrap` is chosen over `kvm` (needs nested virt, unsupported on most EC2
instance types) and `ptrace` (legacy). `network = "sandbox"` keeps the
netstack isolated from the host kernel — `network = "host"` would
negate much of the isolation value of running gVisor.

### EKS node group

- `ami_type = var.architecture.ami_type` — derived from
  `var.architecture` (ADR-0006 / ADR-0008); arm64 default,
  `AL2023_*_STANDARD` only.
- `instance_types = length(var.instance_types) > 0 ? var.instance_types : var.architecture.default_instance_types`.
  Burstable families (`t4g`, `t3`) are excluded from the per-arch
  defaults (ADR-0006); consumers can still override for dev.
- `capacity_type = var.capacity_type` — defaults to `ON_DEMAND`
  (ADR-0009); `SPOT` is a per-workload opt-in via Terragrunt override.
- `taint = workload-class=secure:NO_SCHEDULE` (always); plus
  `var.additional_taints`. The taint is matched by the cluster's
  out-of-band `RuntimeClass` (ADR-0011).
- `labels = var.node_labels` — fully-formed by Boilerplate (the
  `workload-class=secure` / `runtime=gvisor` standard pair merged with
  any per-instantiation additions before the module receives the input).
- `update_config.max_unavailable_percentage` configurable.
- `lifecycle.ignore_changes = [scaling_config[0].desired_size]` — defer
  to autoscaler.

### RuntimeClass (out-of-band, consumer responsibility)

Per **ADR-0011**, this module does **not** create the gVisor
`RuntimeClass`. There is no `kubernetes_manifest` resource, no
`kubernetes` provider, and no `var.create_runtime_class` toggle. The
module's responsibility ends at the AWS-side contract: provision the
node group, install gVisor via user data, register the `runsc`
containerd handler, apply the labels and taints the `RuntimeClass`
will match.

Consumers apply the `RuntimeClass` once per cluster via kubectl
(one-shot bootstrap) or Argo CD + Kustomize (production GitOps). The
module's `README.md` documents the manifest and provides copy-paste
examples for both delivery mechanisms.

The values the consumer's manifest must use are stable constants
exposed by this module:

- `handler: runsc` — matches the containerd handler the user data
  registers (ADR-0005, ADR-0008).
- `scheduling.nodeSelector` — `workload-class: secure`,
  `runtime: gvisor` (both applied by `aws_eks_node_group.labels`).
- `scheduling.tolerations` — `workload-class=secure:NoSchedule`
  (applied by `aws_eks_node_group.taint`).

The `RuntimeClass` is intentionally arch-agnostic — multi-arch clusters
running both `arm64` and `amd64` instantiations of this module need
exactly one `RuntimeClass` applied per cluster.

## API / Interface Changes

### Required inputs

| Input | Notes |
|---|---|
| `remote_state_bucket` | S3 bucket holding the cluster module's state. |
| `region` | AWS region; also used in the remote state key. |
| `cluster_name` | Cluster name; used as the remote state key fragment and as `aws_eks_node_group.cluster_name`. |
| `nodegroup_name` | This node group's name. |

Everything else previously listed as "required" — `cluster_endpoint`,
`cluster_ca_data`, `node_security_group_id`, `subnet_ids`, `ebs_kms_key_arn`
— is read from the cluster (and VPC) remote state via
`data.terraform_remote_state` rather than passed in. See *Cross-module
wiring* above.

### Key optional inputs

| Input | Default | Notes |
|---|---|---|
| `architecture` | `arm64` | Validated to `arm64` or `amd64`. |
| `instance_types` | `[]` → defaults by arch | Validated against arch via regex. |
| `capacity_type` | `ON_DEMAND` | `SPOT` allowed; ON_DEMAND for prod recommended. |
| `desired_size` / `min_size` / `max_size` | `1` / `0` / `10` | Desired ignored after create. |
| `disk_size_gib` | `100` | `gp3` only. |
| `enable_ssm` | `false` | Off by default; opt in for clusters that want Session Manager break-glass (ADR-0002). |
| `gvisor_release` | `release/latest` | Pin to dated release in prod. |
| `additional_labels` / `additional_taints` / `tags` | empty | Merged with module-managed values. |
| `extra_kubelet_args` | `""` | Appended at bootstrap. |

### Outputs

`nodegroup_name`, `architecture`, `ami_type`, `node_role_arn`,
`launch_template_id`, `launch_template_latest_version`, `node_labels`,
`node_taints`.

## Data Model

### Resource inventory

- `aws_iam_role.node` + `aws_iam_instance_profile.node`
- `aws_iam_role_policy_attachment.{worker_node, ecr_pull_only, ssm[0]}`
- `aws_launch_template.node`
- `aws_eks_node_group.this`

### Required providers

`hashicorp/aws ~> 6.x`. **No `kubernetes` provider** — per ADR-0011,
the `RuntimeClass` is delivered out-of-band via kubectl or
Argo+Kustomize and is not a Terraform resource.

## Testing Strategy

### Static validation (libtftest, LocalStack-backed)

- `terraform validate` and `tflint` per module.
- Plan-time assertions:
  - `instance_types` validation rejects `m7i.*` when `architecture = arm64`.
  - `instance_types` validation rejects `m7g.*` when `architecture = amd64`.
  - `architecture` outside `{arm64, amd64}` is rejected.
  - `capacity_type` outside `{ON_DEMAND, SPOT}` is rejected.
- Apply-time assertions against LocalStack:
  - Launch template `metadata_options` has `http_tokens=required`,
    `http_put_response_hop_limit=2`.
  - Node role has exactly `AmazonEKSWorkerNodePolicy` +
    `AmazonEC2ContainerRegistryPullOnly` (+ SSM if enabled) and **no** CNI/CSI
    policies.
  - EBS `block_device_mappings[0].ebs` has `encrypted=true` and the passed KMS
    key ARN.
  - Node group taint contains `workload-class=secure:NO_SCHEDULE`.
  - `ami_type` matches arch.

### Integration validation (post-deploy on a dev cluster)

- `kubectl get nodes -l workload-class=secure` shows expected arch label and taint.
- `kubectl get runtimeclass gvisor` registered exactly once per cluster.
- Validation pod with `runtimeClassName: gvisor` lands on a secure node and
  `dmesg` output includes a gVisor banner; `uname -m` matches arch.
- IMDS smoke test from an in-pod shell: IMDSv1 returns 401; IMDSv2 returns the
  instance ID.

### Workload compatibility evaluation procedure

Before any production workload migrates onto the secure node group, run
the four-step procedure:

1. **Static check.** Review the workload's runtime/language for known
   gVisor-incompatible patterns: Linux AIO or `io_uring` (expect
   performance regression, benchmark required); loading BPF programs
   inside the pod (will fail — use a different node group); NUMA
   pinning (will lose tuning — validate behavior); real-time
   scheduling (will lose timing guarantees); `mlock` for secrets
   (stub — review the security model). The upstream gVisor
   compatibility tables (linked in References) are the authority for
   per-syscall support level.
2. **Runtime test.** Deploy the workload to a dev gVisor node and run
   for a representative period. Check process startup logs for
   `ENOSYS`, `EPERM`, "Operation not permitted" errors;
   application-level error rates vs baseline; p95/p99 latency vs
   baseline (syscall overhead typically adds 5–15%); unexpected
   sandboxed-process crashes or restarts.
3. **Compatibility sweep.** Run `strace -c` (or equivalent) against
   the workload on a non-gVisor node to inventory the syscalls
   actually used, then cross-reference against the gVisor compatibility
   tables.
4. **Document the result.** Workload compatibility is per-workload and
   per-gVisor-release. Capture the evaluation in the workload's
   documentation so future changes can be re-validated.

The high-risk workload categories — flag for compatibility evaluation
before opting into the secure node group — are heavy async I/O
(databases targeting `io_uring`), eBPF-internal workloads, NUMA-tuned
applications, and real-time scheduling.

## Migration / Rollout Plan

Three phases (each will become an IMPL doc):

1. **Phase 1 — Module scaffold and homelab validation.** Land the Terraform,
   libtftest plan-time tests, and a single-node dev cluster validation.
2. **Phase 2 — Single dev cluster, both arches.** Deploy `arm64` and
   `amd64` instantiations to one dev cluster; apply the `gvisor`
   `RuntimeClass` once via kubectl or Argo+Kustomize per ADR-0011; run
   the compatibility procedure against a representative set of internal
   workloads.
3. **Phase 3 — Per-cluster production rollout.** One cluster at a time,
   workload-by-workload migration gated by compatibility evaluation.

Rollback at each phase is `terraform destroy` of the node group; the
cluster and addons modules are unaffected. The `RuntimeClass` is removed
separately by the consumer (kubectl delete or Argo Application removal).

## Open Questions

### Resolved by ADRs

| Question | Resolution |
|---|---|
| Cross-module composition mechanism | ADR-0001 — `terraform_remote_state` (S3 backend), pure-function modules, minimal locals, hoist derivation to Boilerplate. |
| Node IAM posture | ADR-0002 — `AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly`; all workload AWS credentials via Pod Identity. |
| Syscall sandboxing runtime | ADR-0005 — gVisor (`runsc`) with `systrap` platform + `network = sandbox`. |
| Default architecture | ADR-0006 — ARM64/Graviton default; x86_64 first-class for vendor-x86 / x86-specific workloads. |
| IMDS hop limit | ADR-0007 — hop=2 is required by the Pod Identity credential model; not a tunable. |
| AMI family | ADR-0008 — AL2023 only. No AL2, no Bottlerocket (deferred to a future variant module), no Custom AMI. |
| Spot capacity strategy | ADR-0009 — `ON_DEMAND` default; `SPOT` is a per-workload Terragrunt override. |
| gVisor release pinning | ADR-0010 — dated immutable tag (`release/YYYYMMDD.N`) in production; org-wide pin, Renovate-managed bumps. |
| RuntimeClass ownership | ADR-0011 — out-of-band delivery via kubectl or Argo+Kustomize; not a Terraform resource. |
| SSM access on the node role | ADR-0012 — `AmazonSSMManagedInstanceCore` off by default, opt-in via `var.enable_ssm`. |
| Where per-workload compatibility evaluations live | In the workload's own repository (DESIGN-0001 §"Workload compatibility evaluation procedure" step 4). |

### Still open / deferred

- **Bottlerocket as a future AMI variant.** Real posture upside
  (read-only root, dm-verity, A/B updates), but a separate module's
  worth of work (different bootstrap model, no `/usr/local/bin/`).
  Deferred until a workload class justifies the investment (ADR-0008
  Alternatives Considered).
- **GuardDuty Runtime Monitoring + gVisor interaction.** GuardDuty's
  runtime agent uses eBPF; gVisor's syscall interception may interfere
  with findings on sandboxed workloads. Needs validation in dev before
  declaring full coverage on secure-workload pods.
- **Wiz ARM64 sensor compatibility.** Confirm Wiz Kubernetes sensor's
  ARM64 build is available and behaves correctly on Graviton nodes
  running gVisor pods.

## References

### ADRs that constrain this module

- ADR-0001 — Cross-module composition via `terraform_remote_state`.
- ADR-0002 — Node IAM minimization via Pod Identity.
- ADR-0005 — gVisor as the syscall sandboxing runtime.
- ADR-0006 — ARM64 Graviton as default for secure workloads.
- ADR-0007 — IMDS hop limit 2 with minimal node IAM.
- ADR-0008 — AL2023 only for secure node groups.
- ADR-0009 — ON_DEMAND default for secure workloads.
- ADR-0010 — gVisor release pinning via Renovate.
- ADR-0011 — RuntimeClass delivered out-of-band, not by Terraform.
- ADR-0012 — SSM access on the node role.

### Sibling designs

- DESIGN-0002 — EKS Cluster Module (publishes `cluster_name`,
  `cluster_endpoint`, `cluster_ca_data`, `node_security_group_id`,
  KMS key ARN through its remote state).
- DESIGN-0003 — EKS Addons Module (installs Pod Identity Agent first;
  the agent that this module's pods depend on).
- DESIGN-0004 — EKS Pod Identity Access Module (workload-level Pod
  Identity Associations that depend on the empty node role).

### Module-level docs

- [`modules/eks/managed-node-group/README.md`](../../modules/eks/managed-node-group/README.md)
  — `RuntimeClass` out-of-band delivery (kubectl + Argo+Kustomize
  examples).

### External

- gVisor docs: <https://gvisor.dev/docs/>
- gVisor syscall compatibility (arm64):
  <https://gvisor.dev/docs/user_guide/compatibility/linux/arm64/>
- gVisor syscall compatibility (amd64):
  <https://gvisor.dev/docs/user_guide/compatibility/linux/amd64/>
- Kubernetes RuntimeClass:
  <https://kubernetes.io/docs/concepts/containers/runtime-class/>
- EKS managed node groups with launch templates:
  <https://docs.aws.amazon.com/eks/latest/userguide/launch-templates.html>
- EC2 IMDS options:
  <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- AL2023 nodeadm bootstrap:
  <https://awslabs.github.io/amazon-eks-ami/nodeadm/>
