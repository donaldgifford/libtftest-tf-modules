---
id: DESIGN-0005
title: "ECR Pull-Through Cache Module"
status: Draft
author: Donald Gifford
created: 2026-05-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0005: ECR Pull-Through Cache Module

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-15

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Module layout](#module-layout)
  - [Cross-module references](#cross-module-references)
  - [Upstream registries supported](#upstream-registries-supported)
  - [Pull-through cache rules](#pull-through-cache-rules)
  - [Upstream credentials (Docker Hub, GitHub registries)](#upstream-credentials-docker-hub-github-registries)
  - [Repository creation template (auto-vivification)](#repository-creation-template-auto-vivification)
  - [IAM for nodes that pull through the cache](#iam-for-nodes-that-pull-through-the-cache)
  - [Tagging](#tagging)
- [API / Interface Changes](#api--interface-changes)
  - [Required inputs](#required-inputs)
  - [Optional inputs](#optional-inputs)
  - [Outputs](#outputs)
- [Data Model](#data-model)
  - [Resource inventory](#resource-inventory)
  - [Required providers](#required-providers)
- [Testing Strategy](#testing-strategy)
  - [terraform test plan-only suite (default)](#terraform-test-plan-only-suite-default)
  - [terraform test apply-LocalStack suite (gap-discovery)](#terraform-test-apply-localstack-suite-gap-discovery)
  - [Integration (post-deploy)](#integration-post-deploy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Caveats](#caveats)
- [Open Questions](#open-questions)
  - [Resolved by ADRs](#resolved-by-adrs)
  - [Still open](#still-open)
- [References](#references)
  - [ADRs that constrain this module](#adrs-that-constrain-this-module)
  - [Sibling designs](#sibling-designs)
  - [External](#external)
<!--toc:end-->

## Overview

A Terraform module that provisions one or more **ECR pull-through cache
rules** in an AWS account, optionally with the Secrets Manager secrets
needed for authenticated upstreams (Docker Hub, GHCR, etc.) and the IAM
trust scaffolding so EKS nodes can resolve `<acct>.dkr.ecr.<region>.amazonaws.com/<upstream-prefix>/<image>`
through the cache transparently. The aim is to break the cluster's
runtime dependency on direct Docker Hub / Quay / public-registry pulls
without forcing every image reference to be rewritten by hand.

## Goals and Non-Goals

### Goals

- Provision `aws_ecr_pull_through_cache_rule` resources for one or more
  upstream registries (configurable per-instantiation).
- Support authenticated upstreams via `aws_secretsmanager_secret` +
  `aws_secretsmanager_secret_version`, with the credential ARN passed
  to the cache rule's `credential_arn`.
- Configure ECR's **repository creation template** so the first pull
  of an upstream image auto-vivifies the local ECR repo with the
  expected tags, scan-on-push, and lifecycle policy (no manual repo
  creation per upstream image).
- Output the cache-rule ARNs and the cached-image URL prefix
  (`<acct>.dkr.ecr.<region>.amazonaws.com/<upstream-prefix>`) so
  downstream stacks (kustomize, Helm `values.yaml`, image rewrite
  scripts) can compose authoritative image references.
- AWS-API-only, per ADR-0011 — no `kubernetes` / `kubectl` / `helm`
  provider involvement.

### Non-Goals

- Rewriting Kubernetes workload image references — out of scope. The
  caller's Helm/Kustomize stack is the right place for that, and it
  consumes this module's outputs.
- Provisioning a private ECR endpoint for the VPC (the
  `com.amazonaws.<region>.ecr.{api,dkr}` endpoints) — that lives on
  the VPC stack alongside the existing `eks-auth` endpoint per
  DESIGN-0003 §Caveats. Documented as a hard prerequisite in this
  module's README, not provisioned here.
- Managing ECR repository lifecycle policies for non-pull-through
  repositories — that's a different module (or a future addition).
- Caching for non-image artifacts (Helm charts via OCI, Lambda layers,
  etc.). Pull-through cache supports OCI artifacts in principle but
  this module scopes v1 to container images.
- Cross-region cache replication. Each region instantiates the module
  independently. Replication, if needed, is an ECR-side concern not a
  this-module concern.

## Background

EKS clusters typically pull images from Docker Hub, Quay, GHCR, ECR
Public, and Kubernetes registry (`registry.k8s.io`). Direct pulls hit
public registry rate limits (Docker Hub anon = 100 pulls/6h per IP),
introduce a runtime dependency on public network availability, and
broaden the cluster's attack surface (no AWS-side scanning, no VPC
endpoint routing, no IAM-mediated access).

**ECR pull-through cache** solves this. AWS provisions per-account
cache rules — e.g., `ecr-public.aws/` → `mycache/ecr-public/` — and
the first pull of an upstream image lazy-fetches it into ECR. From
that point forward, pulls hit AWS's network, are scanned by ECR, and
inherit the VPC's ECR endpoint routing. Image references change from
`docker.io/library/nginx:1.27` to
`<acct>.dkr.ecr.<region>.amazonaws.com/mycache/library/nginx:1.27`.

The fleet wants this for three concrete reasons:

1. **Reliability.** Removes Docker Hub's anonymous pull limit as a
   cluster-availability concern.
2. **Security posture.** Every image transits ECR's scanner; private
   VPC endpoint routing means images never leave AWS once cached.
3. **Operational cost.** ECR storage cost is bounded (lifecycle
   policies can prune old tags) and dramatically cheaper than the
   incidents caused by rate-limit hits.

LocalStack Pro 2026.5.x supports pull-through cache rule registration,
which means this module is one of the better-fit candidates for
end-to-end `terraform test` apply-LocalStack coverage per RFC-0001.

## Detailed Design

### Module layout

```sh
modules/eks/ecr-pull-through-cache/
├── main.tf              # aws_ecr_pull_through_cache_rule resources
├── credentials.tf       # aws_secretsmanager_secret + version (for auth'd upstreams)
├── template.tf          # aws_ecr_repository_creation_template (auto-vivify rules)
├── variables.tf
├── outputs.tf
├── versions.tf
```

### Cross-module references

This module does **not** depend on the cluster module's state. It is a
fleet-shared account-level resource — multiple clusters in the same
account share the same cache. It only needs the region (for the URL
prefix output) and tagging context.

Consumer modules (managed-node-group via launch template userdata that
configures containerd registry mirrors, or workload Helm charts) read
this module's outputs via remote state if they need the cached-image
URL prefix at deploy time:

```hcl
data "terraform_remote_state" "ecr_cache" {
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = "${var.region}/ecr-pull-through-cache/terraform.tfstate"
    region = var.region
  }
}
```

### Upstream registries supported

| Upstream                | Cache rule prefix    | Auth required?                                                           |
| ----------------------- | -------------------- | ------------------------------------------------------------------------ |
| ECR Public              | `ecr-public/`        | No (open).                                                               |
| Quay                    | `quay/`              | No for public images; opt-in auth via Quay robot token.                  |
| Docker Hub              | `docker-hub/`        | Strongly recommended (anonymous limits) — secret holds username + token. |
| GitHub Container Registry (GHCR) | `ghcr/`     | Yes for private images — secret holds PAT or fine-grained token.         |
| Kubernetes registry     | `kubernetes/`        | No (open).                                                               |
| Microsoft Container Registry (MCR) | `mcr/`    | No (open).                                                               |

Each `var.upstream_registries` entry selects which upstreams to wire.
v1 ships with all six understood; the module rejects unknown
upstreams at plan time via a `validation` block on the input variable.

### Pull-through cache rules

Each entry produces one `aws_ecr_pull_through_cache_rule`:

```hcl
resource "aws_ecr_pull_through_cache_rule" "this" {
  for_each = local.cache_rules

  ecr_repository_prefix = each.value.prefix
  upstream_registry_url = each.value.upstream_url
  credential_arn        = lookup(each.value, "credential_arn", null)
  upstream_repository_prefix = lookup(each.value, "upstream_repository_prefix", null)
}
```

`local.cache_rules` is a map keyed by upstream name (`docker-hub`,
`ghcr`, etc.) derived from `var.upstream_registries` and (for auth'd
upstreams) the matching `aws_secretsmanager_secret.upstream[*].arn`.
The conditional credential_arn handles open-vs-authenticated upstreams
in one shape.

### Upstream credentials (Docker Hub, GitHub registries)

For authenticated upstreams, a Secrets Manager secret stores credentials
in the format ECR pull-through cache requires:

```json
{
  "username": "donaldgifford",
  "accessToken": "ghp_..."
}
```

The module **does not** accept credential values directly in
`var.*` — that would persist secrets in Terraform state. Instead it:

- Creates `aws_secretsmanager_secret.upstream[<name>]` with name
  `ecr-pullthroughcache/<upstream-name>` (the prefix ECR requires).
- Populates `aws_secretsmanager_secret_version` with a placeholder
  body (e.g., `{"username":"REPLACE_ME","accessToken":"REPLACE_ME"}`)
  using `lifecycle.ignore_changes = [secret_string]` so Terraform
  never overwrites the operator-rotated value.
- Emits the secret ARN as an output so operators know which secret
  to rotate.

Operators populate the real credentials post-apply via the AWS
console or `aws secretsmanager put-secret-value`. Rotation, if
desired, is via Secrets Manager's rotation lambda — also out of scope
for v1, but the secret is shaped to accept it.

### Repository creation template (auto-vivification)

Without a creation template, ECR doesn't materialize the local
repository for an upstream image until the first pull, and the
materialized repo gets ECR's default settings (no scan-on-push, no
lifecycle policy, no tags). The creation template provisioned here
fixes that:

```hcl
resource "aws_ecr_repository_creation_template" "pull_through" {
  prefix = "*"  # applies to any pull-through-created repository

  applied_for = ["PULL_THROUGH_CACHE"]

  image_tag_mutability = "MUTABLE"  # tag mutability for cache repos

  encryption_configuration {
    encryption_type = "AES256"
  }

  repository_policy = data.aws_iam_policy_document.cache_repo_policy.json

  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Prune untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      # ... additional rules from var.lifecycle_rules if set
    ]
  })

  resource_tags = var.tags
}
```

`prefix = "*"` matches any pull-through-created repository. If finer
control is needed (different lifecycle for different upstreams), the
module can be extended to one template per upstream prefix — a v2
concern, flagged in Open Questions.

### IAM for nodes that pull through the cache

ECR pull-through requires `ecr:CreateRepository` (for the first pull)
and `ecr:BatchImportUpstreamImage` on the principal doing the pull,
in addition to the usual `ecr:BatchGetImage` and
`ecr:GetDownloadUrlForLayer`.

The managed `AmazonEC2ContainerRegistryPullOnly` policy attached to
the secure-node-group's IAM role per ADR-0002 **does not** include
`ecr:CreateRepository` or `ecr:BatchImportUpstreamImage`. Per
DESIGN-0001's minimal-IAM stance, broadening the node role is the
wrong fix — instead, this module emits **an additional managed-style
policy ARN** that consumers attach via Terragrunt input to the node
role:

```hcl
resource "aws_iam_policy" "node_pull_through" {
  name        = "${var.name_prefix}-ecr-pull-through"
  description = "Permissions for EKS nodes to use ECR pull-through cache"
  policy = data.aws_iam_policy_document.node_pull_through.json
}

data "aws_iam_policy_document" "node_pull_through" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:BatchImportUpstreamImage",
    ]
    resources = ["arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/*"]
  }
}
```

Output `node_pull_through_policy_arn` is the ARN the secure-node-group
module's Terragrunt config opts into via `var.extra_node_policies`.
This is a deliberate departure from ADR-0002's "exactly two managed
policies" posture and is **flagged as an open question** for review.

### Tagging

Standard `var.tags` map merged into every resource. The module-managed
secrets, repository creation template, and IAM policy all carry the
tags so cleanup/audit is greppable.

## API / Interface Changes

### Required inputs

| Input         | Notes                                                                            |
| ------------- | -------------------------------------------------------------------------------- |
| `region`      | AWS region. Used in the policy ARN scope and in computed output URL prefix.      |
| `name_prefix` | Prefix for IAM policy and Secrets Manager secret names (e.g., `acme-prod`).      |
| `upstream_registries` | List of upstream registry shorthand names. Validated against the supported set. |

### Optional inputs

| Input                                | Default | Notes                                                                                        |
| ------------------------------------ | ------- | -------------------------------------------------------------------------------------------- |
| `enable_node_pull_through_policy`    | `true`  | When true, emit the additional IAM policy for nodes. When false, only cache rules + secrets. |
| `repo_creation_template_prefix`      | `"*"`   | The prefix the creation template applies to.                                                 |
| `untagged_image_retention_days`      | `7`     | Lifecycle policy rule for untagged images in the auto-vivified repos.                        |
| `scan_on_push`                       | `true`  | Enabled in the creation template's scanning_configuration.                                   |
| `tags`                               | `{}`    | Merged onto every resource.                                                                  |

### Outputs

| Output                              | Notes                                                                                  |
| ----------------------------------- | -------------------------------------------------------------------------------------- |
| `cache_rule_arns`                   | Map of upstream name → cache rule ARN.                                                 |
| `cache_url_prefixes`                | Map of upstream name → `<acct>.dkr.ecr.<region>.amazonaws.com/<prefix>` URL.            |
| `credential_secret_arns`            | Map of upstream name → Secrets Manager secret ARN (for auth'd upstreams only).          |
| `node_pull_through_policy_arn`      | ARN of the IAM policy nodes need; null when `enable_node_pull_through_policy = false`.  |
| `repository_creation_template_arn`  | ARN of the creation template.                                                          |

## Data Model

### Resource inventory

- `aws_ecr_pull_through_cache_rule.this[*]` — one per upstream.
- `aws_secretsmanager_secret.upstream[*]` + `aws_secretsmanager_secret_version.upstream[*]` — one each per authenticated upstream.
- `aws_ecr_repository_creation_template.pull_through` — one per module instantiation.
- `aws_iam_policy.node_pull_through[0]` — gated on `var.enable_node_pull_through_policy`.
- `data.aws_caller_identity.current` — identity-class carve-out per ADR-0001 (same as cluster module).

### Required providers

`hashicorp/aws ~> 6.2`. Terraform `>= 1.1`. No `kubernetes` provider (per ADR-0011).

## Testing Strategy

Per RFC-0001 / ADR-0013 / ADR-0014: `terraform test` is the default
framework. ECR pull-through cache is a strong LocalStack-Pro-friendly
surface — the apply-LocalStack suite should exercise meaningful runtime
behavior here.

### `terraform test` plan-only suite (default)

- Plan-time assertions on resource counts: with three upstreams
  configured (one open, two authenticated), plan contains 3 cache rules,
  2 Secrets Manager secrets + versions, 1 creation template, 1 node IAM
  policy.
- `enable_node_pull_through_policy = false` produces zero IAM policy
  resources.
- Validation: `upstream_registries = ["bogus"]` rejected at plan.
- Validation: empty `upstream_registries` rejected (would create
  nothing useful).
- Creation template lifecycle policy JSON encodes the
  `var.untagged_image_retention_days` value.
- Node IAM policy's resource scope is bound to `var.region` +
  `data.aws_caller_identity.current.account_id`.

### `terraform test` apply-LocalStack suite (gap-discovery)

ECR pull-through is supported by LocalStack Pro. Apply-time invariants
to verify:

- `aws_ecr_pull_through_cache_rule` creates and `cache_url_prefixes`
  output renders an `<acct>.dkr.ecr.<region>.amazonaws.com/<prefix>`
  URL.
- `aws_secretsmanager_secret` is created with the
  `ecr-pullthroughcache/<name>` prefix ECR requires.
- `aws_ecr_repository_creation_template` accepts the JSON policy and
  the resource is registered.
- IAM policy is created with the correct resource scope.

Findings to surface (per RFC-0001's gap-discovery loop):

- Whether LocalStack Pro honors `aws_ecr_repository_creation_template`
  fully (it's a relatively newer ECR API) — if it returns 501 or stubs
  it without persisting, that's a **sneakystack ticket**.
- Whether the cache rule's `credential_arn` reference validation works
  against a real LocalStack Secrets Manager secret — if it doesn't,
  also a sneakystack ticket.
- Whether actually pulling an image through the cache works in
  LocalStack — likely **not** (LocalStack ECR doesn't proxy to real
  Docker Hub), but worth attempting and documenting.

### Integration (post-deploy)

- From a node in the cluster, `crictl pull <acct>.dkr.ecr.<region>.amazonaws.com/docker-hub/library/nginx:1.27`
  succeeds.
- ECR console shows a newly-materialized repository
  `docker-hub/library/nginx` with image vulnerability scan results.
- Pulling a Quay image (`quay/coreos/etcd:v3.5.0`) materializes
  `quay/coreos/etcd` similarly.
- Removing the Secrets Manager secret value and trying a fresh pull
  fails with a clear authentication error (proves credential wiring).

## Migration / Rollout Plan

Greenfield: instantiate this module in a fleet-shared account before
the cluster modules, wire `node_pull_through_policy_arn` into the
node-group module's `var.extra_node_policies`, and rewrite image
references at the Helm/Kustomize layer to use the cached URLs.

Brownfield: deploy the cache, populate Secrets Manager credentials, then
migrate workloads off direct Docker Hub references one at a time —
each migration is a manifest change, not a Terraform change.

Rollback per upstream: remove from `var.upstream_registries`. Existing
cached repositories remain (ECR doesn't delete them when a cache rule
is removed), so rollback is safe and image references continue to
resolve until manually cleaned up.

## Caveats

- **VPC endpoint required for private subnets.** Nodes in private
  subnets need `com.amazonaws.<region>.ecr.api`,
  `com.amazonaws.<region>.ecr.dkr`, and `com.amazonaws.<region>.s3`
  endpoints (the third because ECR pull-through stores image layers in
  S3 under the hood). Without them, `crictl pull` against the cache
  URL times out. VPC stack owns this; documented in module README.
- **Pull-through rule credential format is upstream-specific.** Docker
  Hub uses `{"username","accessToken"}`; ECR Public takes nothing;
  GHCR uses the same shape as Docker Hub but the token has different
  required scopes (read:packages). The module surfaces the secret
  ARN; the operator is responsible for putting the right shape in.
- **First-pull latency.** The first pull of a new upstream image goes
  to AWS's network through to the public registry, lazily writes to
  ECR, and only then returns to the puller. For a fresh cluster the
  first run of every workload pays this cost; subsequent pods hit the
  warm cache. Not a defect — but a documented expectation.
- **Pull-through doesn't bypass image-signing concerns.** If the
  upstream image is signed (cosign, Notary), pulling through the cache
  passes the bytes through unchanged; signature verification (if
  configured at the cluster level via a policy controller) still
  applies. Out of scope for this module, just worth noting.

## Open Questions

### Resolved by ADRs

| Question                                          | Resolution                                                                                                                          |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Cross-module composition mechanism                | ADR-0001 — `terraform_remote_state` (S3) is the contract; this module's outputs are read by managed-node-group's Terragrunt config. |
| AWS-API-only Terraform                            | ADR-0011 — no `kubernetes`/`helm` providers. Image-reference rewriting at the manifest layer is the consumer's job.                 |
| Testing framework                                 | RFC-0001 / ADR-0013 — `terraform test` is default. ADR-0014 — libtftest only if/when apply-time runtime gaps surface.                |

### Still open

- **Departure from ADR-0002's "two managed policies on the node role."**
  The pull-through cache needs `ecr:CreateRepository` +
  `ecr:BatchImportUpstreamImage` on the puller. ADR-0002 commits the
  node role to `AmazonEKSWorkerNodePolicy` +
  `AmazonEC2ContainerRegistryPullOnly` only. Three paths forward:
  (a) attach the additional policy emitted here as a third managed
  policy on the node role (this design's current proposal);
  (b) move the pull-through cache permissions to Pod Identity, which
  doesn't work because the puller is containerd/kubelet, not a pod;
  (c) skip pull-through cache entirely and accept Docker Hub rate
  limits. Decision needed: write a new ADR amending ADR-0002 to
  permit an opt-in third policy for pull-through? Lean (a).
- **Repository creation template — one or many?** Current design has
  one template with `prefix = "*"`. If different upstreams need
  different lifecycle policies (e.g., MCR images retained 30d but
  Docker Hub images 7d), this needs to become multiple templates with
  per-upstream prefixes. v1 ships one template; revisit if/when
  workloads demand differentiation.
- **Lifecycle policy default — 7 days untagged retention.** Reasonable
  starting point but arbitrary. Should this default be longer for
  production stability or shorter for cost? Open to user input.
- **Multi-region.** This module ships per-region. If the fleet runs
  EKS clusters in two regions, the module is instantiated twice. ECR
  pull-through cache is per-region by design. No cross-region
  replication today; out of scope unless a workload demands it.
- **Auth secret rotation.** Module ships secrets with
  `ignore_changes = [secret_string]` so operators rotate manually via
  AWS console. Should this module ship a Secrets Manager rotation
  lambda? Probably no — that lambda would need to know how to mint
  PATs for Docker Hub / GHCR, which is non-trivial. Operators handle
  rotation manually until a real workflow emerges.
- **OCI artifacts (Helm charts).** Pull-through cache supports OCI
  artifacts in general. Should this module's `upstream_registries`
  accept Helm-chart OCI repositories? v1 says no — keep scope to
  container images. Add when an internal consumer requests it.
- **Should consumer Helm/Kustomize image rewrites be automated?** Out
  of scope here, but worth a sister tool (an `image-rewrite` action
  for Argo CD, or a Kyverno policy that auto-rewrites image
  references). Captured as a downstream concern, not a blocker.

## References

### ADRs that constrain this module

- ADR-0001 — Cross-module composition via `terraform_remote_state`.
- ADR-0002 — Node IAM minimization (this module is in tension with —
  see Open Questions).
- ADR-0011 — AWS-API-only Terraform.

### Sibling designs

- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (where the
  emitted IAM policy is consumed).
- DESIGN-0002 — EKS Cluster Module (does not depend on this module;
  this module is fleet-shared, cluster-agnostic).

### External

- ECR pull-through cache:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/pull-through-cache.html>
- ECR repository creation templates:
  <https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-creation-templates.html>
- `aws_ecr_pull_through_cache_rule` resource:
  <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_pull_through_cache_rule>
- `aws_ecr_repository_creation_template` resource:
  <https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository_creation_template>
- Docker Hub pull rate limits:
  <https://docs.docker.com/docker-hub/usage/>
