---
id: DESIGN-0002
title: "EKS Cluster Module"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---

<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0002: EKS Cluster Module

**Status:** Accepted **Author:** Donald Gifford **Date:** 2026-05-13

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Module layout](#module-layout)
  - [Cluster resource](#cluster-resource)
  - [EKS Access Entries (SSO)](#eks-access-entries-sso)
  - [No managed addons here (incl. Pod Identity Agent)](#no-managed-addons-here-incl-pod-identity-agent)
  - [Shared node security group](#shared-node-security-group)
  - [Controller IAM roles](#controller-iam-roles)
  - [Tags (hoisted to Boilerplate)](#tags-hoisted-to-boilerplate)
  - [Remote-state contract](#remote-state-contract)
- [API / Interface Changes](#api--interface-changes)
  - [Required inputs](#required-inputs)
  - [New optional inputs](#new-optional-inputs)
  - [Outputs](#outputs)
- [Data Model](#data-model)
  - [Resource inventory](#resource-inventory)
  - [Required providers](#required-providers)
  - [Discovered (read-only) data](#discovered-read-only-data)
- [Testing Strategy](#testing-strategy)
  - [Static validation](#static-validation)
  - [libtftest plan-time / apply-time (LocalStack)](#libtftest-plan-time--apply-time-localstack)
  - [Integration (post-deploy)](#integration-post-deploy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [Resolved by ADRs](#resolved-by-adrs)
  - [Still open](#still-open)
- [References](#references)
  - [ADRs that constrain this module](#adrs-that-constrain-this-module)
  - [Sibling designs](#sibling-designs)
  - [External](#external)
<!--toc:end-->

## Overview

A reusable Terraform module that provisions a single EKS control plane plus the
cluster-level scaffolding every downstream module (managed-node-group, addons,
pod-identity-access) consumes: KMS envelope encryption, EKS Access Entries for
SSO, a shared node security group, and a small set of IAM roles for cluster-wide
controllers. The cluster module does not install any EKS managed addons —
including the Pod Identity Agent — per ADR-0003.

## Goals and Non-Goals

### Goals

- Produce a working EKS cluster with secure defaults (envelope encryption,
  private endpoint preferred, control-plane logging).
- Provide a single, shared **node security group** that node-group modules
  attach to via `var.node_security_group_id`.
- Wire **EKS Access Entries** for AWS SSO (Identity Center) so the platform team
  and developers can reach the cluster API without manual `aws-auth` config-map
  edits.
- Pre-create the IAM roles for cluster-wide controllers that are _not_
  workload-specific (cluster-autoscaler, AWS Load Balancer Controller,
  external-dns, FluentD, CloudWatch agent) — these roles are already referenced
  by `modules/eks/cluster/outputs.tf` today.
- Discover VPC / subnets by tag, not hard-coded ID, to keep the module
  environment-portable.

### Non-Goals

- Provisioning node groups — see DESIGN-0001 (secure) and any future general
  node group module.
- Provisioning **any** EKS managed addons (Pod Identity Agent, VPC CNI,
  kube-proxy, CoreDNS, EBS/EFS CSI) — see DESIGN-0003. Per ADR-0003, the cluster
  module installs zero addons because the addons module applies after node
  groups and addon DaemonSets need nodes to schedule on.
- Creating workload-specific Pod Identity Associations — see DESIGN-0004.
- Owning the VPC, subnets, or KMS keys — these are inputs (or discovered).

## Background

The existing `modules/eks/cluster/variables.tf` already encodes several
decisions worth keeping:

- VPC is discovered by `tag:Account` against an alias derived from the AWS
  account alias (with `dev-` prefix stripped).
- Subnets are discovered by `Network = Private|Public` tags on the same VPC.
- SSO access via EKS Access Entries is opt-in (`sso_access_enabled`) with a
  validated `sso_cluster_policy` (one of `AmazonEKSClusterAdminPolicy`,
  `AmazonEKSAdminPolicy`, `AmazonEKSViewPolicy`).
- The current outputs already expose five IAM role ARNs
  (`cluster-autoscaler_arn`, `pod_cw_metrics_arn`, `pod_fluentd_logs_arn`,
  `alb_role_arn`, `external_dns_arn`) — `main.tf` is presently empty, so
  defining those resources is part of this design.

The downstream consumer of this module is the secure node group (DESIGN-0001),
which needs `cluster_name`, `cluster_endpoint`, `cluster_ca_data`, and
`node_security_group_id` as outputs. Those are the non-negotiable interface
points.

## Detailed Design

### Module layout

```sh
modules/eks/cluster/
├── main.tf            # aws_eks_cluster, cluster IAM role
├── kms.tf             # aws_kms_key for envelope encryption (optional)
├── access_entries.tf  # SSO access entry + policy association (gated)
├── controllers.tf     # IAM roles for ALB, cluster-autoscaler, external-dns,
│                      # FluentD, CW metrics (Pod Identity trust)
├── security_group.tf  # shared node SG referenced by node groups
├── variables.tf
├── outputs.tf
├── versions.tf
```

### Cluster resource

- `aws_eks_cluster.this` with `version = var.eks_version` (default `1.35`).
- `vpc_config.subnet_ids` from `data.aws_subnets.private` (re-uses existing
  discovery).
- `vpc_config.endpoint_private_access = true`, `endpoint_public_access = false`
  by default; toggleable for break-glass.
- `encryption_config.resources = ["secrets"]` with `provider.key_arn` from
  either `var.kms_key_arn` (passed in) or a module-managed
  `aws_kms_key.cluster[0]`.
- `enabled_cluster_log_types = ["api", "audit", "authenticator"]` by default
  (configurable).
- Cluster IAM role with `AmazonEKSClusterPolicy` attached.

### EKS Access Entries (SSO)

When `var.sso_access_enabled`:

- Resolve the SSO role ARN matching `var.sso_role_name`
  (`AWSReservedSSO_<permission-set>_*` pattern).
- Create `aws_eks_access_entry.sso` with `kubernetes_groups`, `user_name`, and
  `type` from `var.sso_eks_access_entry`.
- Attach `var.sso_cluster_policy` (validated to one of the three EKS-managed
  cluster policies) at `access_scope.type = var.sso_cluster_policy_access_scope`
  (default `cluster`).

Keep the existing `variables.tf` API verbatim — it's already part of the
module's contract.

### No managed addons here (incl. Pod Identity Agent)

Per ADR-0003, the cluster module installs zero EKS managed addons — the Pod
Identity Agent, VPC CNI, kube-proxy, CoreDNS, and EBS/EFS CSI all live in the
addons module (DESIGN-0003). The standing fleet operational order is cluster →
nodes → addons → pod-identity, and every DaemonSet-backed addon (including the
agent) needs a node to schedule on before `aws_eks_addon` can reach ACTIVE.
Installing any addon in the cluster module would invert that order.

The PrivateLink endpoint for the EKS Auth API
(`com.amazonaws.<region>.eks-auth`) is still required for the Pod Identity Agent
to function in private subnets — but the requirement is on the **VPC stack**,
not on this module. Documented in the addons module's README, since that's where
the agent install lives.

### Shared node security group

A single `aws_security_group.nodes` for node ENIs:

- Ingress from the cluster SG (cluster → kubelet, webhook traffic).
- Ingress from self (node ↔ node pod networking).
- Egress all (workloads need outbound).

Exported as `node_security_group_id`. Each node group module passes this into
its launch template.

### Controller IAM roles

The five roles already referenced in `outputs.tf` are Pod Identity-trusting (no
IRSA / OIDC trust). Each role has an assume-role policy trusting the Pod
Identity service principal:

```hcl
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}
```

Roles, each scoped to a single controller:

| Output                   | Controller                   | Permissions                                                            |
| ------------------------ | ---------------------------- | ---------------------------------------------------------------------- |
| `cluster-autoscaler_arn` | cluster-autoscaler           | ASG describe / SetDesiredCapacity, EC2 describe                        |
| `pod_cw_metrics_arn`     | CloudWatch agent             | `cloudwatch:PutMetricData`, logs scoped                                |
| `pod_fluentd_logs_arn`   | FluentD / Fluent Bit         | `logs:CreateLogStream`/`PutLogEvents` on `/aws/eks/<cluster>/*`        |
| `alb_role_arn`           | AWS Load Balancer Controller | per AWS LBC IAM policy reference                                       |
| `external_dns_arn`       | external-dns                 | Route 53 zone list + record CRUD scoped by `var.external_dns_zone_ids` |

The matching Pod Identity _Associations_ themselves are **not** created here —
the addons module (DESIGN-0003) creates them for `aws-node` and CSI controllers,
and the pod-identity-access module (DESIGN-0004) creates them for `alb` /
`external-dns` / etc. Keeping the _role_ on the cluster module and the
_association_ on the consumer keeps trust auditable.

### Tags (hoisted to Boilerplate)

Per ADR-0001, the `local.tags` aggregation block currently in `locals.tf` gets
removed. Tags arrive as a fully-formed input object generated by the live-repo
Terragrunt config:

```hcl
variable "tags" {
  description = "Standard tag set. Generated by Boilerplate from the live-repo Terragrunt config."
  type = object({
    Account     = string
    ClusterName = string
    ClusterType = string
    Environment = string
    Region      = string
  })
}
```

Boilerplate's templates compute `Account = trimprefix(account_alias, "dev-")`
etc. once, in the live repo, where an operator can review the derivation. The
module then references `var.tags` at the use site — no `local.tags` block, no
internal aggregation. The `data.aws_iam_account_alias`, `data.aws_region`, and
`data.aws_caller_identity` data sources are removed along with the local (they
exist today only to feed the local).

### Remote-state contract

This module is the source-of-truth state file for the cluster. Downstream
modules (managed-node-group, addons, pod-identity-access) read from it via
`data.terraform_remote_state` rather than via direct Terraform module
composition:

```hcl
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"
    region = var.region
  }
}
```

The cluster module is therefore expected to be configured with an S3 backend
that lands its state at exactly
`${region}/eks/${cluster_name}/terraform.tfstate`. That is a Terragrunt-level
(or backend-config) responsibility, not a module input — but the design
_assumes_ this convention. Outputs are a stable contract; renaming or removing
one is a breaking change to every downstream consumer.

The required outputs in this contract:

| Output                                                                                                     | Consumer module(s)                                     |
| ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| `cluster_name`                                                                                             | all                                                    |
| `cluster_endpoint`                                                                                         | managed-node-group (user data)                         |
| `cluster_ca_data`                                                                                          | managed-node-group (user data)                         |
| `cluster_oidc_issuer_url`                                                                                  | escape hatch for non-Pod-Identity tooling              |
| `node_security_group_id`                                                                                   | managed-node-group (launch template SG)                |
| `kms_key_arn`                                                                                              | managed-node-group (EBS encryption)                    |
| `cluster-autoscaler_arn`, `pod_cw_metrics_arn`, `pod_fluentd_logs_arn`, `alb_role_arn`, `external_dns_arn` | pod-identity-access (Mode B existing-role passthrough) |

## API / Interface Changes

### Required inputs

`name` (cluster name), `account_alias` (when
`aws_account_alias_enabled = false`), `sso_cluster_policy` (validated even when
SSO is disabled — keep current behavior).

### New optional inputs

| Input                       | Default                           | Notes                                      |
| --------------------------- | --------------------------------- | ------------------------------------------ |
| `eks_version`               | `1.35`                            | Existing.                                  |
| `kms_key_arn`               | `null`                            | If null, module creates a KMS key.         |
| `endpoint_private_access`   | `true`                            |                                            |
| `endpoint_public_access`    | `false`                           | Set true only for break-glass.             |
| `enabled_cluster_log_types` | `["api","audit","authenticator"]` |                                            |
| `external_dns_zone_ids`     | `[]`                              | Scopes external-dns role's Route 53 perms. |
| `tags`                      | `{}`                              | Merged with `locals.tags`.                 |

Existing inputs (`aws_account_alias_enabled`, `sso_access_enabled`,
`sso_role_name`, `sso_eks_access_entry`, `sso_cluster_policy`,
`sso_cluster_policy_access_scope`) are preserved verbatim.

### Outputs

Already declared in `outputs.tf` (controller role ARNs) plus the cluster
interface the node group and addons modules need:

| Output                                                                                                     | Consumer                                  |
| ---------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| `cluster_name`                                                                                             | node group, addons                        |
| `cluster_endpoint`                                                                                         | node group user data                      |
| `cluster_ca_data`                                                                                          | node group user data                      |
| `cluster_oidc_issuer_url`                                                                                  | escape hatch for non-Pod-Identity tooling |
| `node_security_group_id`                                                                                   | node group launch template                |
| `kms_key_arn`                                                                                              | passed to node group `ebs_kms_key_arn`    |
| `cluster-autoscaler_arn`, `pod_cw_metrics_arn`, `pod_fluentd_logs_arn`, `alb_role_arn`, `external_dns_arn` | pod-identity-access consumers             |

## Data Model

### Resource inventory

- `aws_eks_cluster.this`
- `aws_iam_role.cluster` + `aws_iam_role_policy_attachment.cluster_policy`
- `aws_kms_key.cluster[0]` + `aws_kms_alias.cluster[0]` (gated on
  `var.kms_key_arn == null`)
- `aws_security_group.nodes`
- `aws_eks_access_entry.sso[0]` + `aws_eks_access_policy_association.sso[0]`
- 5 × `aws_iam_role` for controllers + assume-role policies

### Required providers

`hashicorp/aws ~> 6.2` (matches existing `versions.tf`). Terraform `>= 1.1`.

### Discovered (read-only) data

The current `variables.tf` uses live AWS data sources for VPC / subnet
discovery. **Per ADR-0001, this is a transition state.** TODO comments are
already in place in `modules/eks/cluster/variables.tf` flagging each block for
replacement:

- `data.aws_vpc.this` (tag `Account = ...`) →
  `data.terraform_remote_state.vpc.outputs.vpc_id`
- `data.aws_subnets.private` (tag `Network = Private`) →
  `data.terraform_remote_state.vpc.outputs.private_subnet_ids`
- `data.aws_subnets.public` (tag `Network = Public`) →
  `data.terraform_remote_state.vpc.outputs.public_subnet_ids`

The replacement drives off three new variables (`var.remote_state_bucket`,
`var.region`, `var.vpc_name`) parallel to the EKS remote-state convention.

`data.aws_region` and `data.aws_iam_account_alias` are removed when the tags
hoist lands — they exist today only to feed the `local.tags` aggregation.
`region` becomes `var.region` (already required for the remote-state key),
account alias becomes `var.account_alias` (already present as a fallback input
today).

**`data.aws_caller_identity.current` is the deliberate carve-out.** Per
ADR-0001's identity-class exception, it stays. The account ID it returns is used
to construct the KMS key resource policy (`arn:aws:iam::${account_id}:root` as
the management principal) and any IAM ARN construction in the SSO access entry
block. It is identity, not resource state — it does not drift, the call is
effectively free, and hoisting it as `var.account_id` would only add variable
plumbing to every consumer stack without any determinism gain (Boilerplate would
resolve it via the same `sts:GetCallerIdentity` API call).

After the migration the only `data.aws_*` blocks remaining in the module are
`data.aws_caller_identity.current` (identity carve-out) and
`data.aws_eks_addon_version.*` (a catalog query, not a resource read).

## Testing Strategy

### Static validation

- `terraform validate` and `tflint` clean against existing per-module configs.
- Variable validation: `sso_cluster_policy` already validates to the
  three-policy allowlist — keep.

### libtftest plan-time / apply-time (LocalStack)

- **VPC discovery.** Seed a tagged VPC + subnets; assert data sources resolve
  and `subnet_ids` contains the seeded private subnet IDs.
- **No addons in the cluster module.** Assert the plan contains zero
  `aws_eks_addon` resources (ADR-0003 — addons live in DESIGN-0003).
- **KMS.** Assert `encryption_config.resources` includes `secrets` and
  `provider.key_arn` is set.
- **Endpoint config.** Assert default `endpoint_public_access = false`.
- **SSO.** With `sso_access_enabled = false` no access entry is created; with
  `true` exactly one `aws_eks_access_entry` and one
  `aws_eks_access_policy_association` exist.
- **Controller IAM.** Each role's trust policy includes `pods.eks.amazonaws.com`
  and _not_ `oidc.eks.<region>.amazonaws.com` — we are not on IRSA.

### Integration (post-deploy)

- `aws eks describe-cluster --name <name>` returns `ACTIVE`.
- `kubectl auth can-i ...` from the SSO role matches the chosen cluster policy's
  scope.
- (Pod Identity Agent ACTIVE check is asserted by DESIGN-0003, not here.)

## Migration / Rollout Plan

This module is greenfield in this repo — `main.tf` is currently a stub. The
implementation order matches the dependency graph:

1. Define the cluster resource + KMS + cluster IAM role; existing `variables.tf`
   and `locals.tf` already cover the discovery surface.
2. Add the shared node security group and the five controller IAM roles (these
   are referenced by the existing `outputs.tf`, so wiring them is required for
   `terraform validate` to pass).
3. Add the SSO access entry block, keeping the existing variables verbatim.
4. Run the libtftest suite per the Testing Strategy above.

Rollback is `terraform destroy` of the module; given this is a new cluster,
there is no migration burden.

## Open Questions

### Resolved by ADRs

| Question                              | Resolution                                                                                                                                                                                                                                                                          |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cross-module composition mechanism    | ADR-0001 — `terraform_remote_state` (S3 backend); cluster module is the source-of-truth state file. Identity-class data sources (`aws_caller_identity`) get a documented carve-out; tags / region / account_alias / VPC discovery hoist to Boilerplate-generated Terragrunt inputs. |
| Cluster module installs no addons     | ADR-0003 — the Pod Identity Agent and all other managed addons live in the addons module (DESIGN-0003), driven by the operational order `cluster → nodes → addons → pod-identity`.                                                                                                  |
| Controller IAM trust policy           | ADR-0002 — the five controller roles (cluster-autoscaler, ALB, external-dns, FluentD, CW metrics) use the universal Pod Identity trust policy (`pods.eks.amazonaws.com`).                                                                                                           |
| Kubernetes-API objects in this module | ADR-0011 — none. The cluster module manages AWS API resources only; cluster-scoped Kubernetes manifests are delivered out-of-band.                                                                                                                                                  |

### Still open

- **Where does the KMS key live?** Module-managed (this design's default when
  `var.kms_key_arn` is null) vs always-external. Recommendation: module-managed
  for dev, external for prod.
- **OIDC issuer output.** Exposed as `cluster_oidc_issuer_url` for third-party
  tooling that doesn't yet support Pod Identity. Pod Identity is the primary
  credential model (ADR-0002); OIDC stays as an escape hatch.
- **Controller IAM role scope.** Are the five hard-coded controller roles the
  right set, or should controller IAM be fully delegated to the
  pod-identity-access module (DESIGN-0004) and removed from the cluster module?
  Recommendation: keep on the cluster module while consumers depend on them, but
  reconsider once DESIGN-0004 lands.
- **Endpoint access default.** `endpoint_public_access = false` is the secure
  default but breaks `kubectl` from outside the VPC unless a bastion or VPN is
  in place. Confirm target environments have that connectivity.

## References

### ADRs that constrain this module

- ADR-0001 — Cross-module composition via `terraform_remote_state` (this module
  is the source-of-truth state file; tags/region/account/ VPC discovery hoisted
  to Boilerplate; `aws_caller_identity` carve-out documented).
- ADR-0002 — Node IAM minimization via Pod Identity (the cluster module's five
  controller roles use the Pod Identity trust policy; the node role's two-policy
  posture lives in DESIGN-0001 but the cluster's policies enable it).
- ADR-0003 — Pod Identity Agent installed on the addons module (the cluster
  module installs zero addons).
- ADR-0011 — RuntimeClass delivered out-of-band (the AWS-only-Terraform
  principle that applies to every module in this repo; no `kubernetes` provider
  here).

### Sibling designs

- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (downstream consumer
  of `cluster_name`, `cluster_endpoint`, `cluster_ca_data`,
  `node_security_group_id`, `kms_key_arn`).
- DESIGN-0003 — EKS Addons Module (installs the Pod Identity Agent and the rest
  of the AWS-credentialed addons; ordering enforced intra-module per ADR-0003).
- DESIGN-0004 — EKS Pod Identity Access Module (creates Associations against the
  cluster this module produces; reads the five controller role ARNs from this
  module's remote state).

### External

- EKS Access Entries:
  <https://docs.aws.amazon.com/eks/latest/userguide/access-entries.html>
- EKS Pod Identity:
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>
- `AmazonEKSWorkerNodePolicy` reference (contains
  `eks-auth:AssumeRoleForPodIdentity`):
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonEKSWorkerNodePolicy.html>
- AWS Load Balancer Controller IAM policy:
  <https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/>
