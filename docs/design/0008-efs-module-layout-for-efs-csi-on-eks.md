---
id: DESIGN-0008
title: "EFS module layout for EFS CSI on EKS"
status: Draft
author: Donald Gifford
created: 2026-05-27
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0008: EFS module layout for EFS CSI on EKS

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-27

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Module decomposition](#module-decomposition)
  - [Shared scaffolding](#shared-scaffolding)
  - [Cross-module composition: remote state](#cross-module-composition-remote-state)
  - [Resources](#resources)
  - [Access points (var.access_points)](#access-points-varaccesspoints)
  - [Consumer integration (out-of-band Kubernetes manifests)](#consumer-integration-out-of-band-kubernetes-manifests)
- [API / Interface Changes](#api--interface-changes)
  - [Input surface](#input-surface)
  - [Output surface](#output-surface)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [Q1 — Cross-module composition: read both VPC + EKS remote state, or SG-source-list only? — RESOLVED (a)](#q1--cross-module-composition-read-both-vpc--eks-remote-state-or-sg-source-list-only--resolved-a)
  - [Q2 — Default performance_mode — RESOLVED (a, generalPurpose)](#q2--default-performancemode--resolved-a-generalpurpose)
  - [Q3 — Default throughput_mode — RESOLVED (a, elastic)](#q3--default-throughputmode--resolved-a-elastic)
  - [Q4 — Lifecycle policy default — RESOLVED (a, IA-30d + Archive-90d enabled)](#q4--lifecycle-policy-default--resolved-a-ia-30d--archive-90d-enabled)
  - [Q5 — Module-managed KMS or AWS-managed — RESOLVED (a, module-managed with gated BYO)](#q5--module-managed-kms-or-aws-managed--resolved-a-module-managed-with-gated-byo)
  - [Q6 — Access points — RESOLVED (a, declarative var.access_points map)](#q6--access-points--resolved-a-declarative-varaccesspoints-map)
  - [Q7 — Backup policy default — RESOLVED (a, disabled / opt-in)](#q7--backup-policy-default--resolved-a-disabled--opt-in)
  - [Q8 — Encryption-in-transit — RESOLVED (a, strictly K8s-manifest concern)](#q8--encryption-in-transit--resolved-a-strictly-k8s-manifest-concern)
  - [Q9 — Mount target placement — RESOLVED (a, one per VPC private subnet)](#q9--mount-target-placement--resolved-a-one-per-vpc-private-subnet)
  - [Q10 — creationtoken shape — RESOLVED (a, var.identifierprefix)](#q10--creationtoken-shape--resolved-a-varidentifierprefix)
  - [Q11 — Test scaffolding — RESOLVED (a, include tests-localstack/ from the start)](#q11--test-scaffolding--resolved-a-include-tests-localstack-from-the-start)
- [References](#references)
<!--toc:end-->

## Overview

A single Terraform module under `modules/efs/` provisioning the AWS-
side of EFS-on-EKS: an `aws_efs_file_system`, one
`aws_efs_mount_target` per VPC private subnet (one per AZ), a DB-tier
security group allowing NFS (TCP 2049) ingress from the EKS node
security group via remote state, optional declarative
`aws_efs_access_point`s for fine-grained per-volume mounts, and an
optional backup policy.

The module is the AWS-API companion to the EKS addons module's
already-installed `aws-efs-csi-driver` addon + Pod Identity role
(IMPL-0003, gated on `var.efs_csi_enabled`). This module provisions
the *filesystem* the CSI driver mounts; the CSI driver itself,
driver IAM, and the `efs-csi-controller-sa` Pod Identity Association
already live in `modules/eks/addons/`.

## Goals and Non-Goals

### Goals

- **One module, one EFS filesystem.** Mirrors the fleet's per-AWS-API-
  surface decomposition (`modules/eks/cluster` is one cluster,
  `modules/rds/serverless` is one cluster, etc.). Multiple
  filesystems = multiple module instantiations, each with its own
  remote-state key.
- **Compose with the EKS fleet via remote state.** Read
  `node_security_group_id` from the cluster module's S3 state file
  (per ADR-0001) so the EFS SG can grant NFS ingress without callers
  manually wiring SG IDs.
- **Compose with the VPC stack via remote state.** Read `vpc_id` +
  `private_subnet_ids` from the VPC remote state to place mount
  targets in every AZ where pods might run. Same convention used by
  the EKS modules and `modules/rds/serverless` (IMPL-0007 Q1).
- **Encryption-at-rest on by default.** Module-managed KMS key
  (BYO-able via `var.kms_key_arn`), matching every other module in
  the fleet that handles persistent data.
- **Declarative access points (opt-in).** A `var.access_points`
  typed-object map lets operators provision named access points
  (POSIX UID/GID + root directory) alongside the filesystem. Empty
  map (default) creates zero access points; consumers add them per
  PV need.
- **EFS-CSI-driver friendly outputs.** Emit `filesystem_id`,
  `dns_name`, and per-access-point IDs so consumers can drop them
  into PersistentVolume manifests directly. The PV / PVC manifests
  themselves are out-of-band per ADR-0011 (manifests delivered via
  kubectl or Argo CD).

### Non-Goals

- **Persistent volume / persistent volume claim manifests.** Per
  ADR-0011, the module manages AWS API resources only. PVs +
  PVCs are Kubernetes-API objects; consumers deliver them out-of-
  band (kubectl in dev, Argo CD + Kustomize in production).
- **Cross-region replication.** EFS supports replica filesystems
  (`aws_efs_replication_configuration`) for cross-region DR. Out
  of scope for v1; deferred until a concrete consumer materializes.
- **Cross-account filesystem sharing.** EFS Access Points only
  provide intra-account isolation; cross-account requires the
  `aws_efs_file_system_policy` resource with explicit principals.
  Out of scope for v1.
- **AWS Backup vault provisioning.** When `var.backup_policy_enabled
  = true`, the module enables the EFS backup policy
  (`aws_efs_backup_policy.this`) which routes to the default AWS
  Backup vault. Custom vault provisioning (lifecycle, encryption,
  cross-region copies) is a separate `modules/backup/` module if
  needed.
- **EFS CSI driver installation.** Already handled by
  `modules/eks/addons` (IMPL-0003) when `var.efs_csi_enabled =
  true`. This module does not duplicate that resource.
- **Driver IAM role + Pod Identity Association.** Already created
  by `modules/eks/addons` (`aws_iam_role.efs_csi`,
  `aws_eks_pod_identity_association` for `efs-csi-controller-sa`).
  This module does not duplicate.
- **Encryption-in-transit configuration.** EFS supports TLS encryption
  for mounts; toggle is set on the *mount* (kubelet flag /
  `MountOptions: tls`), not the filesystem. The module documents
  the recommended PV manifest snippet in `README.md`; the actual
  setting belongs in the K8s manifest layer.

## Background

The EKS fleet has end-to-end support for stateful workloads on EBS
today: the EBS CSI driver is installed by `modules/eks/addons` and
each pod that needs a volume gets a `gp3`-backed PV via the driver.
EBS works for single-pod, single-AZ volumes — but it doesn't fit
workloads that need:

- **`ReadWriteMany` (RWX)** — multiple pods reading + writing the
  same volume.
- **Cross-AZ access** — pods rescheduled across AZs need the same
  storage.
- **Persistent shared state** — CI caches, model registries,
  CMS uploads, log aggregation buffers, build artifacts.

EFS provides POSIX-compliant NFS storage that satisfies all three
properties. The EKS addons module already installs the
`aws-efs-csi-driver` addon + grants the controller's Pod Identity
role `AmazonEFSCSIDriverPolicy` when `var.efs_csi_enabled = true`.
What's missing is the actual filesystem — and that's what this
module provides.

The reference design pattern is the EKS cluster + addons + node-
group + pod-identity-access split: each module is one AWS API
surface; multiple surfaces compose via remote state. EFS fits the
same shape — one filesystem per module instantiation, network
composition via VPC remote state, EKS-side SG ingress via cluster
remote state.

## Detailed Design

### Module decomposition

```text
modules/
└── efs/
    └── filesystem/    — one aws_efs_file_system + mount targets +
                         SG + optional access points + optional
                         backup policy
```

A single `filesystem` sub-module. The directory layout
(`modules/efs/<name>/`) leaves room for future siblings (e.g.
`modules/efs/replica/` if cross-region replication ever lands, or
`modules/efs/access-point-only/` if a consumer needs to provision
access points against a shared filesystem).

### Shared scaffolding

- Pins `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`.
- Carries the usual scaffolding (`.terraform-docs.yml`,
  `.tflint.hcl`, `README.md` + generated `USAGE.md`).
- `terraform test` plan-only suite in `tests/` per ADR-0013.
- Opt-in `tests-localstack/` apply suite per RFC-0001.

### Cross-module composition: remote state

Per ADR-0001, this module reads **two** remote states:

```hcl
data "terraform_remote_state" "vpc" {
  backend = "s3"
  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/vpc/${var.vpc_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}

data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket         = var.remote_state_bucket
    key            = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region         = var.region
    use_path_style = true
  }
}
```

Consumed VPC outputs: `vpc_id`, `private_subnet_ids`.
Consumed EKS outputs: `node_security_group_id`.

The VPC stack is the source of truth for subnet topology (one mount
target per private subnet — typically one per AZ). The cluster
module is the source of truth for `node_security_group_id` — the SG
that node-attached pods inherit, and therefore the SG that needs
NFS ingress to reach the EFS mount targets.

**Why both?** Mount targets need `subnet_ids` + `vpc_security_group_ids`;
the subnets are VPC-stack-owned, the SG is best-defined relative
to the cluster's node SG. Composing both means callers don't pass
either explicitly — the module pulls them at apply time.

### Resources

- `aws_kms_key.this[0]` + `aws_kms_alias.this[0]` — count-gated on
  `var.kms_key_arn == null`. Same shape as the cluster /
  org-registry / rds-serverless modules: `enable_key_rotation =
  true`, 30-day deletion window, `lifecycle { prevent_destroy =
  true }`.
- `aws_efs_file_system.this`:
  - `creation_token = var.identifier_prefix` — idempotency token
    AWS uses to dedupe creation calls.
  - `encrypted = true`.
  - `kms_key_id = local.kms_key_arn`.
  - `performance_mode = var.performance_mode` (default per Q2).
  - `throughput_mode = var.throughput_mode` (default per Q3).
  - `provisioned_throughput_in_mibps = var.provisioned_throughput_in_mibps`
    — used only when `throughput_mode = "provisioned"`.
  - `lifecycle_policy` block — gated on Q4 resolution.
  - `tags = var.tags`.
- `aws_efs_mount_target.this` — `for_each` over the VPC's
  `private_subnet_ids` (one mount target per subnet → one per AZ):
  - `file_system_id = aws_efs_file_system.this.id`.
  - `subnet_id = each.value`.
  - `security_groups = [aws_security_group.this.id]`.
- `aws_security_group.this`:
  - `name = "${var.identifier_prefix}-efs"`.
  - `vpc_id = data.terraform_remote_state.vpc.outputs.vpc_id`.
- `aws_vpc_security_group_ingress_rule.from_nodes`:
  - `referenced_security_group_id = data.terraform_remote_state.eks.outputs.node_security_group_id`.
  - `from_port = 2049`, `to_port = 2049`, `ip_protocol = "tcp"`.
- `aws_vpc_security_group_ingress_rule.from_extra` — `for_each`
  over `var.additional_allowed_consumer_sg_ids` (the escape
  hatch — non-EKS consumers like EC2, batch jobs, etc.).
- `aws_vpc_security_group_egress_rule.all` — single all-outbound
  rule (mount targets need outbound to AWS endpoints).
- `aws_efs_backup_policy.this[0]` — count-gated on
  `var.backup_policy_enabled` (per Q7 default).
- `aws_efs_access_point.this` — `for_each` over `var.access_points`
  (per Q6 resolution shape).

### Access points (`var.access_points`)

EFS Access Points provide POSIX-level isolation per consumer:
they pin a root directory + POSIX UID/GID, so pods mounting via
the access point see only that root and operate as the configured
identity (regardless of in-container `runAsUser`).

Variable shape:

```hcl
variable "access_points" {
  description = "Map of EFS access points to provision alongside the filesystem. Key = access point logical name (becomes the access point's Name tag). Value = posix_user + root_directory specs."
  type = map(object({
    posix_user = object({
      uid = number
      gid = number
    })
    root_directory = object({
      path = string
      creation_info = optional(object({
        owner_uid   = number
        owner_gid   = number
        permissions = string
      }))
    })
  }))
  default = {}
}
```

Per Q6 resolution: declarative `var.access_points` map keyed by
logical name. Empty map (default) creates zero access points;
consumers add per-PV access points as their workloads need them.
`for_each` over a typed-object map preserves access point identity
across additions / removals (same pattern as DESIGN-0007's
read-replica module).

### Consumer integration (out-of-band Kubernetes manifests)

Per ADR-0011, the EFS module manages AWS API resources only. The
PV + PVC manifests live in the K8s manifest delivery layer (kubectl
in dev, Argo CD + Kustomize in production). The module's `README.md`
will document copy-paste manifest examples:

```yaml
# PersistentVolume backed by an EFS access point (RWX, statically provisioned)
apiVersion: v1
kind: PersistentVolume
metadata:
  name: example-pv
spec:
  capacity:
    storage: 5Gi
  accessModes: [ReadWriteMany]
  storageClassName: efs-sc
  persistentVolumeReclaimPolicy: Retain
  csi:
    driver: efs.csi.aws.com
    volumeHandle: <module output: filesystem_id>::<module output: access_points["example"].id>
    volumeAttributes:
      encryptInTransit: "true"
```

The `volumeHandle` shape `<filesystem_id>::<access_point_id>` is the
EFS CSI driver's static-provisioning contract. Dynamic provisioning
via `StorageClass + EFS-CSI parameters` is also supported but is
out-of-scope for this module (the StorageClass is a K8s manifest).

## API / Interface Changes

This is a greenfield module. Every consumer is new.

### Input surface

| Input | Type | Required? | Default |
|-------|------|-----------|---------|
| `region` | string | yes | — |
| `remote_state_bucket` | string | yes | — |
| `vpc_name` | string | yes | — |
| `cluster_name` | string | yes | — |
| `identifier_prefix` | string | yes | — |
| `kms_key_arn` | string | no | null (module-managed) |
| `performance_mode` | string | no | per Q2 |
| `throughput_mode` | string | no | per Q3 |
| `provisioned_throughput_in_mibps` | number | no | null |
| `lifecycle_policy` | object | no | per Q4 |
| `additional_allowed_consumer_sg_ids` | list(string) | no | [] |
| `backup_policy_enabled` | bool | no | per Q7 |
| `access_points` | map(object) | no | {} |
| `tags` | map(string) | no | {} |

### Output surface

| Output | Type | Description |
|--------|------|-------------|
| `filesystem_id` | string | Plugs into `volumeHandle` in PV manifests |
| `filesystem_arn` | string | For IAM policies scoped to this filesystem |
| `dns_name` | string | `<fs-id>.efs.<region>.amazonaws.com` for non-CSI mounts |
| `mount_target_ids` | map(string) | Keyed by subnet ID |
| `mount_target_dns_names` | map(string) | Keyed by subnet ID |
| `security_group_id` | string | The EFS SG (in case consumers add their own ingress) |
| `kms_key_arn` | string | BYO or module-managed transparently via `local.kms_key_arn` |
| `access_point_ids` | map(string) | Keyed by `var.access_points` map key |
| `access_point_arns` | map(string) | Same shape |

## Data Model

No application schema. The "data" being modeled is the EFS API
surface (filesystem + mount targets + access points) plus its
network dependencies (VPC subnets, EKS node SG, KMS).

Filesystem-level encryption uses the module's KMS key (BYO or
managed). Per-access-point POSIX identities are caller-supplied and
documented as the unit of multi-tenancy on a shared filesystem.

## Testing Strategy

Per RFC-0001:

- **`terraform test` plan-only suite** (`tests/`):
  - Default-shape resource counts (one filesystem, N mount targets
    where N = `length(private_subnet_ids)`, one SG, one ingress
    rule from the node SG + one ingress rule per
    `additional_allowed_consumer_sg_ids` entry, one egress rule).
  - BYO KMS shape — zero module-managed KMS resources.
  - Lifecycle policy resolution.
  - Access point map resolution — zero entries → zero access points;
    two-entry map → two access points with the expected POSIX UIDs.
  - Validation negatives — invalid `performance_mode`, invalid
    `throughput_mode`, `provisioned_throughput_in_mibps` set when
    throughput_mode != "provisioned" (cross-var precondition).
  - Backup policy gate.
- **`tests-localstack/` apply suite** (opt-in):
  - Default tier: LocalStack Community (matches DESIGN-0007 Q7).
  - VPC + EKS fixtures (handcrafted state files in S3, same pattern
    as the rds-serverless suite — though this needs a more
    complete EKS state stub since it consumes `node_security_group_id`).
  - Probe LocalStack EFS coverage at implementation time
    (`aws_efs_file_system`, `aws_efs_mount_target`,
    `aws_efs_access_point`, `aws_efs_backup_policy`).
  - Fall back to `plan_smoke` per IMPL-0005 Phase 9 if any APIs
    501.

## Migration / Rollout Plan

Greenfield module; no existing consumers.

1. **IMPL doc + feature branch + PR** for `modules/efs/filesystem`
   (single PR — single module, no per-module rollout order).
2. **Updates to documentation** — README.md links + CLAUDE.md
   module-shape section.
3. **Future cross-references** — when a consumer team needs EFS,
   they instantiate this module + reference `filesystem_id` in
   their PV manifests. The EKS addons module's
   `var.efs_csi_enabled = true` is the cluster-side prerequisite.

## Open Questions

All eleven questions resolved 2026-05-28 and folded into the
relevant sections above.

### Q1 — Cross-module composition: read both VPC + EKS remote state, or SG-source-list only? — RESOLVED (a)

**Resolved:** Read both VPC remote state (for `vpc_id` +
`private_subnet_ids`) and EKS remote state (for
`node_security_group_id`); no fallback variables. Matches the
fleet's existing EKS-composition pattern (the managed-node-group
and addons modules both read EKS remote state). Couples the module
explicitly to EKS-on-this-fleet — which is the named use case.
Detailed Design §Cross-module composition + §Resources sections
above reflect this.

### Q2 — Default `performance_mode` — RESOLVED (a, `generalPurpose`)

**Resolved:** Default `var.performance_mode = "generalPurpose"`.
Lower latency, matches the AWS console default, and fits the
common EFS-on-EKS use case (CI caches, build artifacts, shared
document stores). Operators override to `"maxIO"` for the rare
many-thousand-client highly parallel workload.

### Q3 — Default `throughput_mode` — RESOLVED (a, `elastic`)

**Resolved:** Default `var.throughput_mode = "elastic"`. The
AWS-recommended default since GA 2024; no credit-starvation
failure mode under load spikes; cost matches actual usage.
`provisioned_throughput_in_mibps` is conditional — used only when
the operator explicitly switches `throughput_mode` to
`"provisioned"`. Cross-variable invariant (`mibps` non-null IFF
`throughput_mode = "provisioned"`) enforced via a precondition on
the filesystem resource at IMPL time.

### Q4 — Lifecycle policy default — RESOLVED (a, IA-30d + Archive-90d enabled)

**Resolved:** Default lifecycle policy enabled with `IA after 30
days` and `Archive after 90 days`. Variable shape (object) carries
the defaults; `var.lifecycle_policy = null` disables. Aligns with
the AWS recommended-best-practice posture for tiered storage cost
savings. Operators override per workload (or set null) when the
IA-read latency hit + retrieval fee is unacceptable for the access
pattern.

### Q5 — Module-managed KMS or AWS-managed — RESOLVED (a, module-managed with gated BYO)

**Resolved:** Module-managed KMS key (gated BYO via
`var.kms_key_arn`) with `lifecycle { prevent_destroy = true }`.
Mirrors every other persistent-data module in the fleet
(`modules/eks/cluster`, `modules/ecr/org-registry`,
`modules/rds/serverless`). Same coalesce-with-`try()` pattern in
`locals.tf`: `kms_key_arn = coalesce(var.kms_key_arn,
try(aws_kms_key.this[0].arn, null))`.

### Q6 — Access points — RESOLVED (a, declarative `var.access_points` map)

**Resolved:** Declarative `var.access_points` map keyed by logical
name with typed-object values (`posix_user` + `root_directory`).
`for_each` over the map; empty map (default) creates zero access
points. Matches the `modules/rds/read-replica` `var.replicas`
pattern (DESIGN-0007 Q1) — `for_each` preserves access point
identity across additions / removals. Detailed Design §Access
points section reflects the variable shape.

### Q7 — Backup policy default — RESOLVED (a, disabled / opt-in)

**Resolved:** Default `var.backup_policy_enabled = false`. AWS
Backup vault provisioning + lifecycle is an organizational concern
(cross-account vault sharing, compliance retention) — a separate
`modules/backup/` module if/when needed. Operators flip the flag
per-filesystem when the default AWS Backup vault is acceptable.
Avoids surprise cross-cutting backup cost.

### Q8 — Encryption-in-transit — RESOLVED (a, strictly K8s-manifest concern)

**Resolved:** The module emits no in-transit attribute. EFS API
has no encryption-in-transit setting on the filesystem itself —
TLS is configured at mount time (PV manifest's
`encryptInTransit: "true"` volumeAttribute, or `MountOptions: tls`
for non-CSI mounts). Matches ADR-0011 — module manages AWS API
resources only. README documents the recommended PV manifest
snippet for static-provisioning consumers.

### Q9 — Mount target placement — RESOLVED (a, one per VPC private subnet)

**Resolved:** One `aws_efs_mount_target` per VPC `private_subnet_ids`
entry via `for_each`. Maximum availability — pods rescheduled
across AZs reach the closest mount target. Cross-AZ transfer cost
is the trade-off; operators who hit it materially can later add a
`var.mount_target_subnet_ids` override (additive variable surface
change, easy follow-up PR).

### Q10 — `creation_token` shape — RESOLVED (a, `var.identifier_prefix`)

**Resolved:** `creation_token = var.identifier_prefix`. Simple,
predictable, and matches the cluster module's
`cluster_identifier = var.identifier_prefix` pattern. Rename = new
filesystem (uncommon but intentional — RDS clusters behave the
same way).

### Q11 — Test scaffolding — RESOLVED (a, include `tests-localstack/` from the start)

**Resolved:** Both `tests/` (plan-only baseline per ADR-0013) and
`tests-localstack/` (apply gap-discovery per RFC-0001) ship with
the v1 IMPL. EFS is broadly implemented in LocalStack Community;
the apply suite catches LocalStack mount-target / access-point /
backup-policy gaps at module-authoring time + documents them in
`FINDINGS.md`. IMPL-0005 Phase 9 fall-back ready if any APIs 501.

## References

- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state`.
- [ADR-0003](../adr/0003-eks-pod-identity-agent-installed-by-addons-module.md) — Pod Identity Agent + EFS CSI driver installation lives in the addons module.
- [ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md) — Terraform manages AWS API resources only; K8s manifests (PV / PVC / StorageClass) delivered out-of-band.
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants.
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module testing strategy.
- [DESIGN-0003](0003-eks-addons-module.md) — EKS addons module (the home of `aws-efs-csi-driver` addon + IAM role + Pod Identity Association).
- [DESIGN-0007](0007-rds-module-layout-instance-aurora-cluster-aurora-read-replica.md) — RDS module layout (precedent for typed-object map inputs, gated KMS, VPC remote-state composition).
- [Amazon EFS CSI driver documentation](https://github.com/kubernetes-sigs/aws-efs-csi-driver).
- [`aws_efs_file_system` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_file_system).
- [`aws_efs_access_point` resource reference](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/efs_access_point).
- [EFS throughput modes documentation](https://docs.aws.amazon.com/efs/latest/ug/performance.html).
