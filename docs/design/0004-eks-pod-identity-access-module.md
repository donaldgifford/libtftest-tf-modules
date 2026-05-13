---
id: DESIGN-0004
title: "EKS Pod Identity Access Module"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---

<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0004: EKS Pod Identity Access Module

**Status:** Accepted **Author:** Donald Gifford **Date:** 2026-05-13

<!--toc:start-->

- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Module layout](#module-layout)
  - [Cross-module references](#cross-module-references)
  - [Two modes of operation](#two-modes-of-operation)
  - [Trust policy](#trust-policy)
  - [Inline policy support](#inline-policy-support)
  - [Naming convention](#naming-convention)
- [API / Interface Changes](#api--interface-changes)
  - [Required inputs](#required-inputs)
  - [Optional inputs](#optional-inputs)
  - [Validation](#validation)
  - [Outputs](#outputs)
- [Data Model](#data-model)
  - [Resource inventory](#resource-inventory)
  - [Required providers](#required-providers)
- [Testing Strategy](#testing-strategy)
  - [Static validation](#static-validation)
  - [libtftest plan-time / apply-time (LocalStack)](#libtftest-plan-time--apply-time-localstack)
  - [Integration (post-deploy)](#integration-post-deploy)
  - [Module-instantiation tests](#module-instantiation-tests)
- [Caveats](#caveats)
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

A small, single-purpose Terraform module that grants a Kubernetes service
account AWS credentials via an EKS Pod Identity Association. Callers supply the
cluster, namespace, service account, and either an existing role ARN or a set of
IAM policy attachments, and the module returns a wired-up association. This is
the building block that lets every workload controller (AWS LBC, external-dns,
cert-manager, FluentD, application workloads) drop its dependency on the node
IAM role.

## Goals and Non-Goals

### Goals

- Encapsulate the four moving pieces of a Pod Identity grant into one module:
  trust policy → IAM role → policy attachments →
  `aws_eks_pod_identity_association`.
- Be instantiated many times per cluster — one per
  `(namespace, service_account)` pair — with cheap, predictable inputs.
- Support both "module creates the role" and "caller passes an existing role
  ARN" (the latter is how the five cluster-module-owned roles —
  cluster-autoscaler, ALB, external-dns, FluentD, CW metrics — get bound).
- Allow attaching any combination of: AWS-managed policy ARNs, customer- managed
  policy ARNs, and inline JSON policy documents.
- Produce a `role_arn` output that workloads can reference via labels /
  annotations in their downstream manifests.

### Non-Goals

- Installing the Pod Identity Agent — that's DESIGN-0003 (per ADR-0003, the
  agent lives on the addons module).
- Creating the service account itself — Helm charts / kustomizations / workload
  manifests own the SA. This module only **binds** AWS credentials to an SA that
  exists (or will exist) in the cluster.
- Managing the workload's Kubernetes manifests — out of scope; this is an
  AWS-side module only.
- Provisioning the _addon_ Pod Identity Associations (CNI, CSI) — those have
  fixed SA names and live in the addons module (DESIGN-0003).

## Background

The minimal-IAM property in DESIGN-0001 is only possible because every
non-trivial AWS-credentialed component on the cluster gets its credentials via
Pod Identity instead of the node role. Each grant is structurally identical: an
IAM role that trusts `pods.eks.amazonaws.com`, some policies attached, and an
`aws_eks_pod_identity_association` linking the role to a
`(namespace, service_account)` pair.

Without a dedicated module, every consumer reimplements the same four resources,
with subtle drift in trust policies and naming conventions. This module
normalizes that.

The cluster module (DESIGN-0002) already pre-creates _roles_ for cluster- wide
controllers (ALB, autoscaler, external-dns, FluentD, CW metrics). Those roles
still need a Pod Identity Association to come live. This module is the _right_
place to create those associations, because the SA names live with the workload
(its Helm chart), not the cluster.

## Detailed Design

### Module layout

```sh
modules/eks/pod-identity-access/
├── main.tf      # aws_eks_pod_identity_association (always)
├── iam.tf       # aws_iam_role + attachments (gated on var.create_role)
├── locals.tf
├── variables.tf
├── outputs.tf
├── versions.tf
```

### Cross-module references

The cluster's identifying outputs and the cluster-module-owned controller role
ARNs are read from the cluster module's remote state:

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

Cluster outputs are referenced at the use site (ADR-0001) — no aliasing locals.

In **Mode B** (below), callers select which cluster-owned role ARN to bind by
passing the _output name_ — e.g., `cluster_module_role_output = "alb_role_arn"`
— and the module reads it from remote state. This keeps ARNs out of caller
config and avoids manual ARN passthrough.

### Two modes of operation

**Mode A — module creates the role.** `var.create_role = true` (default). The
module owns an `aws_iam_role` with the Pod Identity trust policy, attaches
`var.managed_policy_arns`, `var.customer_managed_policy_arns`, and any number of
`aws_iam_role_policy` inline policies from `var.inline_policies`.

**Mode B — bind a role the cluster module already created.**
`var.create_role = false`. The module reads
`data.terraform_remote_state.eks.outputs[var.cluster_module_role_output]` to get
the role ARN and creates only the `aws_eks_pod_identity_association`. This is
how the five cluster-module-owned roles (cluster-autoscaler, ALB, external-dns,
FluentD, CW metrics) get bound to their workload SAs without the caller
hand-coding ARNs.

An optional `var.existing_role_arn` escape hatch supports binding roles that
_aren't_ in the cluster module's outputs (e.g., one owned by another team's
state file).

```hcl
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = data.terraform_remote_state.eks.outputs.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  tags            = var.association_tags

  role_arn = (
    var.create_role
      ? aws_iam_role.this[0].arn
      : coalesce(
          var.cluster_module_role_output == null
            ? null
            : data.terraform_remote_state.eks.outputs[var.cluster_module_role_output],
          var.existing_role_arn,
        )
  )
}
```

The role-resolution conditional stays inline at the resource — it does
meaningful work (Mode A vs Mode B vs escape hatch) and a `local` here would only
serve to relocate it.

### Trust policy

Always the same shape; identical across Modes A and B:

```hcl
data "aws_iam_policy_document" "pod_identity_trust" {
  count = var.create_role ? 1 : 0

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

For Mode B, the trust policy is the caller's responsibility — the cluster module
already produces correctly-trusted roles.

### Inline policy support

```hcl
variable "inline_policies" {
  description = "Map of inline policy name → JSON document."
  type        = map(string)
  default     = {}
}

resource "aws_iam_role_policy" "inline" {
  for_each = var.create_role ? var.inline_policies : {}
  name     = each.key
  role     = aws_iam_role.this[0].name
  policy   = each.value
}
```

Callers compose policy JSON with `data.aws_iam_policy_document` or `jsonencode`
and pass it in — keeps this module ignorant of any specific service's permission
shape.

### Naming convention

Role name is `<cluster_name>-<namespace>-<service_account>` (truncated / hashed
to fit IAM's 64-char limit). Predictable, greppable across accounts.

Caller can override with `var.role_name_override` if needed (e.g., to keep a
pre-existing role name during a brownfield migration). When
`create_role = false`, the input is ignored.

## API / Interface Changes

### Required inputs

| Input                 | Notes                                               |
| --------------------- | --------------------------------------------------- |
| `remote_state_bucket` | S3 bucket holding the cluster module's state.       |
| `region`              | Used in the remote state key and for AWS API calls. |
| `cluster_name`        | Used as the remote-state key fragment.              |
| `namespace`           | Kubernetes namespace of the SA.                     |
| `service_account`     | Kubernetes SA name.                                 |

### Optional inputs

| Input                          | Default | Notes                                                                                 |
| ------------------------------ | ------- | ------------------------------------------------------------------------------------- |
| `create_role`                  | `true`  | Mode toggle.                                                                          |
| `cluster_module_role_output`   | `null`  | Mode B: output name to read from the cluster's remote state (e.g., `"alb_role_arn"`). |
| `existing_role_arn`            | `null`  | Mode B escape hatch when the role isn't in the cluster module's outputs.              |
| `role_name_override`           | `null`  | Bypass the naming convention.                                                         |
| `managed_policy_arns`          | `[]`    | AWS-managed policy ARNs (Mode A).                                                     |
| `customer_managed_policy_arns` | `[]`    | Customer-managed policy ARNs (Mode A).                                                |
| `inline_policies`              | `{}`    | Map of name → JSON document (Mode A).                                                 |
| `permissions_boundary`         | `null`  | Mode A only; optional IAM permissions boundary.                                       |
| `association_tags`             | `{}`    | Applied to the Pod Identity Association.                                              |
| `tags`                         | `{}`    | Applied to the role (Mode A only).                                                    |

### Validation

- When `create_role = false`, exactly one of `cluster_module_role_output` or
  `existing_role_arn` must be non-null — enforced via `validation` block.
- When `create_role = true`, at least one of `managed_policy_arns`,
  `customer_managed_policy_arns`, or `inline_policies` should be set — emit a
  `validation` warning (a role with no policies is technically valid but almost
  always a bug).

### Outputs

| Output            | Notes                                                 |
| ----------------- | ----------------------------------------------------- |
| `role_arn`        | Either created or passed through.                     |
| `association_id`  | From `aws_eks_pod_identity_association.this.id`.      |
| `namespace`       | Echo of input — handy in multi-instance compositions. |
| `service_account` | Echo of input.                                        |

## Data Model

### Resource inventory

- `aws_iam_role.this[0]` (Mode A only)
- `aws_iam_role_policy_attachment.managed[*]` (Mode A only)
- `aws_iam_role_policy_attachment.customer[*]` (Mode A only)
- `aws_iam_role_policy.inline[*]` (Mode A only)
- `aws_eks_pod_identity_association.this` (always)

### Required providers

`hashicorp/aws ~> 6.2`. Terraform `>= 1.1`.

## Testing Strategy

### Static validation

- `terraform validate` and `tflint` clean.
- The `create_role = false` + `existing_role_arn = null` combination must fail
  at plan time (variable validation).

### libtftest plan-time / apply-time (LocalStack)

- **Mode A creates exactly four resource kinds.** With three managed policies
  and two inline policies and zero customer-managed policies, the plan contains:
  1 role, 3 managed attachments, 0 customer attachments, 2 inline policies, 1
  association.
- **Mode A trust policy.** Role's trust policy includes `pods.eks.amazonaws.com`
  with `sts:AssumeRole` and `sts:TagSession`.
- **Mode B passthrough.** With `create_role = false`, plan contains exactly one
  resource: `aws_eks_pod_identity_association`, and its `role_arn` equals
  `var.existing_role_arn`.
- **Association binding.** `aws_eks_pod_identity_association` has the expected
  `cluster_name`, `namespace`, `service_account`.
- **Name truncation.** With a long cluster name + long namespace + long SA, the
  generated role name is ≤ 64 chars and deterministic.

### Integration (post-deploy)

A canonical end-to-end test using a representative workload:

1. Deploy a Deployment in the target namespace with a service account matching
   the association.
2. The Deployment's pod runs `aws sts get-caller-identity` and writes the result
   to a ConfigMap (or just logs it).
3. The returned ARN matches the role this module created/bound.
4. A negative test: a pod in the same namespace with a _different_ SA gets no
   AWS credentials (Pod Identity scope is per-SA, not per-namespace).

### Module-instantiation tests

Because this module will be instantiated many times in real consumers, the test
suite should include at least one composition test — `for_each` over a map of
grants — to ensure naming conflicts and provider context propagation work as
expected.

## Caveats

- **Fargate is excluded.** Pod Identity requires the Pod Identity Agent
  DaemonSet, which Fargate does not schedule. Fargate workloads stay on IRSA.
  Both can coexist in the same cluster — Pod Identity for EC2-backed pods, IRSA
  for Fargate-backed pods.
- **AWS SDK version matters.** Pre-2023 SDKs do not honor
  `AWS_CONTAINER_CREDENTIALS_FULL_URI` and silently fall back to IMDS — they
  will _appear_ to work while actually using the node role's empty credentials.
  This is the most common Pod Identity trap. Workloads adopting this module
  should pin a current SDK base image; the libtftest assertion suite cannot
  detect this fallback.
- **Eventual consistency.** Pod Identity Associations are eventually consistent.
  There is a small window between `terraform apply` returning and the agent
  vending the new association's credentials. Do not create associations in
  critical-path startup code.
- **Dynamic namespaces are not supported.** Pod Identity Associations do not
  accept globs on namespace or service-account names. Per-PR ephemeral
  namespaces need a per-namespace association (or fall back to IRSA for those
  workloads).
- **Universal trust policy.** Every Pod Identity role uses the _same_ trust
  policy (`pods.eks.amazonaws.com` with `sts:AssumeRole` + `sts:TagSession`) —
  no OIDC URL, no per-cluster customization (ADR-0002 / ADR-0004). The same role
  can be re-used across every EKS cluster in the account.

## Migration / Rollout Plan

Greenfield clusters (the working assumption): adopt from day one.

Brownfield clusters (cluster previously using IRSA or node-role policies):

1. **Per-controller, parallel-run.** Create the Pod Identity Association with
   the same policy set the controller previously used. Pod Identity takes
   precedence over node-role inheritance — the controller starts pulling
   credentials from the Pod Identity Agent automatically.
2. **Verify.** `aws sts get-caller-identity` from inside the controller pod
   returns the new role ARN, not the node role.
3. **Remove legacy.** Strip the previous IAM grants (node-role attachment, IRSA
   service account annotation, etc.). The Pod Identity binding remains the only
   credential path.
4. **Repeat per controller.** No big-bang cutover required.

For larger brownfield migrations consider
[`eksctl utils migrate-to-pod-identity`](https://eksctl.io/usage/pod-identity-associations/),
which automates the identification of existing IRSA roles, updates trust
policies, and creates associations as a one-shot.

Rollback is `terraform destroy` of the specific module instance —
controller-by-controller — without affecting unrelated grants.

## Open Questions

### Resolved by ADRs

| Question                                             | Resolution                                                                                                                                                                                                                                     |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cross-module composition mechanism                   | ADR-0001 — `terraform_remote_state` (S3); Mode B reads cluster-owned role ARNs at use site.                                                                                                                                                    |
| Node IAM minimization is the point                   | ADR-0002 — this module is the AWS-side enabler of the empty-node-role posture for every workload that needs AWS credentials.                                                                                                                   |
| Trust policy shape                                   | ADR-0002 / ADR-0004 — universal Pod Identity trust policy (`pods.eks.amazonaws.com`, `sts:AssumeRole` + `sts:TagSession`). Same shape as the addon-managed pattern.                                                                            |
| Standalone vs addon-managed PIA resource             | ADR-0004 — this module uses `aws_eks_pod_identity_association` (standalone), the right tool for workload-level grants where there's no parent `aws_eks_addon`. The addon-managed `pod_identity_association` block is reserved for DESIGN-0003. |
| Should the module own the Kubernetes ServiceAccount? | ADR-0011 — no. Terraform modules in this repo manage AWS API resources only; the SA is owned by the workload's Helm chart / Kustomize / manifest, not by this module.                                                                          |
| Hop-limit 1 vs 2 (downstream concern)                | ADR-0007 — hop=2 is a hard requirement of the Pod Identity credential model, not a tunable. Empty node role does the credential-theft defense work. Not revisited after this module's adoption.                                                |

### Still open

- **Cross-account roles.** Some workloads need to assume a role in a different
  AWS account. The Pod Identity role can include a `sts:AssumeRole` policy to
  chain. Out of scope for v1 — callers build the inline policy. A future
  `var.target_account_arns` convenience input could simplify common cases.
- **Brownfield migration tooling.** `eksctl utils migrate-to-pod-identity` vs
  Terraform-only cutover; tracked in the rollout plan above.

## References

### ADRs that constrain this module

- ADR-0001 — Cross-module composition via `terraform_remote_state` (Mode B reads
  cluster-owned controller role ARNs at use site).
- ADR-0002 — Node IAM minimization via Pod Identity (this module is what _makes_
  the empty-node-role posture viable for workloads).
- ADR-0004 — Addon-managed Pod Identity Association pattern (defines the
  boundary: this module uses the _standalone_ `aws_eks_pod_identity_association`
  resource; the addon-managed block is reserved for DESIGN-0003).
- ADR-0007 — IMDS hop limit 2 with minimal node IAM (the hop=2 requirement that
  this module's workloads rely on for the Pod Identity Agent to be reachable).
- ADR-0011 — RuntimeClass delivered out-of-band, not by Terraform (the
  AWS-only-Terraform principle — this module does not create the ServiceAccount
  it binds to).

### Sibling designs

- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (the empty-node-role
  posture this module makes feasible).
- DESIGN-0002 — EKS Cluster Module (pre-creates the five cluster-wide controller
  roles consumed via Mode B; defines the remote-state contract this module
  reads).
- DESIGN-0003 — EKS Addons Module (the _addon-level_ counterpart with fixed SA
  names; uses the addon-managed PIA pattern per ADR-0004, the complement of this
  module's standalone-resource pattern).

### External

- EKS Pod Identity overview:
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>
- `aws_eks_pod_identity_association` resource:
  <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association>
- EKS Pod Identity vs IRSA:
  <https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html>
- `eksctl utils migrate-to-pod-identity`:
  <https://eksctl.io/usage/pod-identity-associations/>
