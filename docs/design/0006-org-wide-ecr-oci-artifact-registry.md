---
id: DESIGN-0006
title: "Org-wide ECR OCI Artifact Registry"
status: Draft
author: Donald Gifford
created: 2026-05-18
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0006: Org-wide ECR OCI Artifact Registry

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-18

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [Architecture at a glance](#architecture-at-a-glance)
  - [Resource inventory](#resource-inventory)
  - [Namespacing](#namespacing)
  - [Tag mutability](#tag-mutability)
  - [Lifecycle policy](#lifecycle-policy)
  - [Cross-account access](#cross-account-access)
  - [Encryption](#encryption)
  - [Publisher IAM](#publisher-iam)
- [Reference Terraform](#reference-terraform)
  - [KMS key](#kms-key)
  - [ECR-assumed IAM role](#ecr-assumed-iam-role)
  - [Org-wide pull policy](#org-wide-pull-policy)
  - [Creation template — helm-charts/](#creation-template--helm-charts)
  - [Creation template — tf-modules/](#creation-template--tf-modules)
  - [Publisher IAM policy (reusable)](#publisher-iam-policy-reusable)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
  - [Plan-time invariants (terraform test)](#plan-time-invariants-terraform-test)
  - [Apply-time validation](#apply-time-validation)
  - [Verification smoke (post-apply)](#verification-smoke-post-apply)
- [Migration / Rollout Plan](#migration--rollout-plan)
  - [Cleanup notes](#cleanup-notes)
- [Open Questions](#open-questions)
- [References](#references)
<!--toc:end-->

## Overview

Implements the fleet-shared, org-wide OCI artifact registry proposed in
[RFC-0002](../rfc/0002-ecr-layout-for-internal-oci-artifacts.md) and decided
in [ADR-0016](../adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md).
Two `aws_ecr_repository_creation_template` resources (one per managed
prefix — `helm-charts/`, `tf-modules/`) govern lazy repo creation for the
entire estate's internal Helm charts and Terraform modules.

## Goals and Non-Goals

### Goals

- Provision two ECR creation templates that materialize per-artifact repos
  on first push, with uniform encryption, lifecycle, tag mutability, and
  org-wide pull access.
- Provide a reusable publisher IAM policy module that CI / IRSA roles
  attach to publish artifacts.
- Stand up the supporting primitives (KMS key, ECR-assumed IAM role,
  org-wide repository policy) in the artifact-hosting account.
- Document the verification recipe and the operational gotchas
  ([ADR-0016](../adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md) §Consequences) so onboarding teams don't re-discover them.

### Non-Goals

- Migrate existing artifacts off legacy distribution (ChartMuseum, Terraform
  HTTP module registry, etc.) — that is RFC-0002 Phase 3/4 operational work,
  not part of this design.
- Govern container image repos under `images/` — those pre-date this
  design and are unaffected.
- Replace or augment the per-region EKS pull-through cache module
  ([DESIGN-0005](0005-ecr-pull-through-cache-module.md) / [ADR-0015](../adr/0015-permit-opt-in-third-managed-policy-on-node-role-for-ecr-pull.md)). That module is per-region and EKS-cluster-facing; this design is per-organization and CI-publisher-facing. The two consume ECR but for distinct purposes (cache vs publish) and do not share state, IAM, or KMS keys.
- Cross-account ECR replication. Cross-account *pull* is solved via the
  template's repository policy; replication is RFC-0002 Alternatives §5
  and remains rejected.

## Background

ECR Repository Creation Templates (GA July 2024) let a registry-owner
define configuration that ECR applies automatically when a new repo is
created via push, replication, or pull-through cache. The template matches
by longest prefix; `ROOT` is the catch-all. Configuration covers
encryption, lifecycle policy, tag mutability, repository policy, and
resource tags.

A "repository" in ECR is a namespace for one artifact identity (chart name,
module name, image name) plus its tagged versions. Slashes in repo names
are a naming convention, not a hierarchy — `helm-charts/api` and
`helm-charts/web` are two independent repos that happen to share a name
prefix.

Helm and the Terraform OCI module workflow both push to a parent URL and
let the client append the artifact's name as the final path segment:

```bash
helm push api-1.2.0.tgz oci://<acct>.dkr.ecr.<region>.amazonaws.com/helm-charts
# → creates repo helm-charts/api with tag 1.2.0
```

This makes `helm-charts/` and `tf-modules/` natural prefix boundaries: one
template per prefix, every artifact in that namespace inherits the
template's configuration on first push.

## Detailed Design

### Architecture at a glance

```text
                ┌─────────────────────────────────────────┐
                │  Artifact-hosting AWS account (one)     │
                │                                         │
                │  ┌──────────────────────────────────┐   │
                │  │ aws_kms_key.ecr_oci              │   │
                │  │ (single key, all OCI prefixes)   │   │
                │  └────────────┬─────────────────────┘   │
                │               │                         │
                │  ┌────────────▼─────────────────────┐   │
                │  │ aws_iam_role.ecr_template        │   │
                │  │ (ECR assumes this during         │   │
                │  │  repo creation; required for     │   │
                │  │  KMS + resource_tags)            │   │
                │  └────────────┬─────────────────────┘   │
                │               │                         │
                │  ┌────────────▼─────────────────────┐   │
                │  │ aws_ecr_repository_creation_     │   │
                │  │ template.helm_charts             │   │
                │  │ aws_ecr_repository_creation_     │   │
                │  │ template.tf_modules              │   │
                │  └────────────┬─────────────────────┘   │
                │               │ first push → lazy create│
                │               ▼                         │
                │  helm-charts/<name>   tf-modules/<name> │
                │  (auto-created repos with template      │
                │   config applied at creation only)      │
                └─────────────────────────────────────────┘
                                ▲
                                │ pull (BatchGetImage, etc.)
                                │ — repository policy +
                                │   aws:PrincipalOrgID condition
                                │
                ┌───────────────┴─────────────────────────┐
                │  Consumer accounts (200+ in the org)    │
                │  ArgoCD, Terraform, IRSA workloads      │
                └─────────────────────────────────────────┘
```

### Resource inventory

The artifact-hosting account contains exactly these Terraform resources
for this design:

| Resource | Count | Purpose |
|----------|-------|---------|
| `aws_kms_key.ecr_oci` + `aws_kms_alias` | 1 | Dedicated CMK for OCI artifacts (single key for cross-repo blob mounting). |
| `aws_iam_role.ecr_template` + `aws_iam_role_policy` | 1 | Assumed by ECR during repo creation; needed because the templates use KMS and `resource_tags`. |
| `aws_ecr_repository_creation_template.helm_charts` | 1 | Governs new `helm-charts/<name>` repos. |
| `aws_ecr_repository_creation_template.tf_modules` | 1 | Governs new `tf-modules/<name>` repos. |
| `aws_iam_policy.oci_publisher` | 1 | Reusable publisher policy attached to CI / IRSA roles. |
| `data.aws_iam_policy_document.org_pull` | 1 | Source of the org-wide repository policy embedded in each template. |
| `data.aws_caller_identity.current` | 1 | Account ID for IAM resource ARN scoping. |
| `data.aws_organizations_organization.this` | 1 | Org ID for the `aws:PrincipalOrgID` condition. |

Zero per-artifact `aws_ecr_repository` resources, by design
([ADR-0016](../adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md)).

### Namespacing

| Prefix | Contents | Example repo |
|--------|----------|--------------|
| `helm-charts/` | Internal Helm charts | `helm-charts/api-service` |
| `tf-modules/` | Internal Terraform modules | `tf-modules/eks-cluster` |
| `images/` | Container images (existing, unchanged) | `images/api-service` |

This design only manages the first two. `images/` predates this design and
keeps whatever provisioning model it already has (most commonly per-repo
`aws_ecr_repository` resources).

### Tag mutability

- `image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"` so versioned tags
  (semver) cannot be overwritten — chart and module versions are contracts
  consumers pin to.
- Exclude floating tags (`latest`; optionally `dev-*`) via a wildcard
  exclusion filter so publishers can still overwrite them.
- Requires AWS Terraform provider **>= 6.8.0**. If pinned older, fall back
  to plain `IMMUTABLE` and forbid floating tags via CI lint.

### Lifecycle policy

Identical between the two templates (the operational characteristics of
charts and modules are the same — both are versioned, signed, consumer-pinned):

| Rule | Tag pattern | Action | When |
|------|-------------|--------|------|
| 1 | `dev-*`, `rc-*`, `snapshot-*` | expire | 90 days after push |
| 2 | untagged | expire | 7 days after push |

Tagged production versions are retained indefinitely — semver tags are
contracts and consumers may pin to old versions.

If the `tf-modules/` namespace needs different retention in practice (some
teams need indefinite retention of pre-release module tags), drop rule 1
from the `tf_modules` template — the two are independent resources.

### Cross-account access

The template's `repository_policy` grants read-only pull access to any
principal in the AWS Organization:

```hcl
condition {
  test     = "StringEquals"
  variable = "aws:PrincipalOrgID"
  values   = [data.aws_organizations_organization.this.id]
}
```

Granted actions: `BatchGetImage`, `GetDownloadUrlForLayer`,
`BatchCheckLayerAvailability`, `DescribeImages`, `DescribeRepositories`.

Every auto-created repo inherits this policy on creation. No per-repo or
per-account grants needed. If a future requirement narrows access to
specific OUs, swap `aws:PrincipalOrgID` for `aws:PrincipalOrgPaths`.

### Encryption

- KMS encryption with `aws_kms_key.ecr_oci` (rotation on, 30-day deletion
  window).
- Single key across both prefixes. Cross-repository blob mounting requires
  matching encryption config across source and destination; sharing one
  key keeps the option open.
- The template's `custom_role_arn` is the `aws_iam_role.ecr_template`
  role. ECR assumes this role during repo creation to act on KMS and on
  `resource_tags`; without it, KMS-encrypted templates fail at creation
  time with an unhelpful error.

### Publisher IAM

CI / IRSA roles publishing charts and modules attach the
`aws_iam_policy.oci_publisher` policy emitted by this module. It grants:

```text
ecr:GetAuthorizationToken              (resource = "*"; AWS limitation)
ecr:CreateRepository                   (scoped to managed prefixes)
ecr:DescribeRepositories               (scoped)
ecr:InitiateLayerUpload                (scoped)
ecr:UploadLayerPart                    (scoped)
ecr:CompleteLayerUpload                (scoped)
ecr:BatchCheckLayerAvailability        (scoped)
ecr:PutImage                           (scoped)
kms:Encrypt / GenerateDataKey* / DescribeKey  (the OCI KMS key only)
```

`ecr:CreateRepository` is the critical permission — its absence is the
common first-rollout failure mode ([ADR-0016](../adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md) §Consequences).

## Reference Terraform

The implementation is a single Terraform configuration in the artifact-
hosting account. Resource bodies are reproduced here as a copy-paste
baseline; see `ecr-temp/examples.md` for the un-renumbered draft.

### KMS key

```hcl
resource "aws_kms_key" "ecr_oci" {
  description             = "ECR encryption key for OCI artifact repos (helm-charts/*, tf-modules/*)"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    purpose    = "ecr-oci-artifacts"
    managed_by = "platform"
  }
}

resource "aws_kms_alias" "ecr_oci" {
  name          = "alias/ecr-oci-artifacts"
  target_key_id = aws_kms_key.ecr_oci.key_id
}
```

### ECR-assumed IAM role

```hcl
data "aws_iam_policy_document" "ecr_template_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecr.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecr_template" {
  name               = "ecr-repository-creation-template"
  description        = "Assumed by ECR when creating repos via creation templates"
  assume_role_policy = data.aws_iam_policy_document.ecr_template_assume.json
}

data "aws_iam_policy_document" "ecr_template" {
  statement {
    sid    = "ManageRepoConfig"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:PutLifecyclePolicy",
      "ecr:SetRepositoryPolicy",
      "ecr:TagResource",
    ]
    resources = [
      "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/helm-charts/*",
      "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/tf-modules/*",
    ]
  }

  statement {
    sid    = "UseKmsKey"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.ecr_oci.arn]
  }
}

resource "aws_iam_role_policy" "ecr_template" {
  name   = "ecr-template-permissions"
  role   = aws_iam_role.ecr_template.id
  policy = data.aws_iam_policy_document.ecr_template.json
}

data "aws_caller_identity" "current" {}
data "aws_organizations_organization" "this" {}
```

### Org-wide pull policy

```hcl
data "aws_iam_policy_document" "org_pull" {
  statement {
    sid    = "AllowOrgPull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [data.aws_organizations_organization.this.id]
    }
  }
}
```

### Creation template — `helm-charts/`

```hcl
resource "aws_ecr_repository_creation_template" "helm_charts" {
  prefix      = "helm-charts"
  applied_for = ["CREATE_ON_PUSH"]
  description = "Internal Helm charts published as OCI artifacts"

  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "latest"
    filter_type = "WILDCARD"
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr_oci.arn
  }

  custom_role_arn = aws_iam_role.ecr_template.arn

  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire pre-release tags after 90 days"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["dev-", "rc-", "snapshot-"]
          countType     = "sinceImagePushed"
          countUnit     = "days"
          countNumber   = 90
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged manifests after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
    ]
  })

  repository_policy = data.aws_iam_policy_document.org_pull.json

  resource_tags = {
    artifact_type = "helm-chart"
    managed_by    = "platform"
  }
}
```

### Creation template — `tf-modules/`

Near-identical to `helm-charts/` with module-specific tags. Lifecycle is
the same — if `tf-modules/` ever needs indefinite retention for pre-release
tags in practice, drop rule 1 here only.

```hcl
resource "aws_ecr_repository_creation_template" "tf_modules" {
  prefix      = "tf-modules"
  applied_for = ["CREATE_ON_PUSH"]
  description = "Internal Terraform modules published as OCI artifacts"

  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  image_tag_mutability_exclusion_filter {
    filter      = "latest"
    filter_type = "WILDCARD"
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr_oci.arn
  }

  custom_role_arn = aws_iam_role.ecr_template.arn

  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire pre-release tags after 90 days"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["dev-", "rc-", "snapshot-"]
          countType     = "sinceImagePushed"
          countUnit     = "days"
          countNumber   = 90
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Expire untagged manifests after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
    ]
  })

  repository_policy = data.aws_iam_policy_document.org_pull.json

  resource_tags = {
    artifact_type = "terraform-module"
    managed_by    = "platform"
  }
}
```

### Publisher IAM policy (reusable)

```hcl
data "aws_iam_policy_document" "oci_publisher" {
  statement {
    sid    = "EcrAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "EcrCreateAndPush"
    effect = "Allow"
    actions = [
      "ecr:CreateRepository",
      "ecr:DescribeRepositories",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:BatchCheckLayerAvailability",
      "ecr:PutImage",
    ]
    resources = [
      "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/helm-charts/*",
      "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/tf-modules/*",
    ]
  }

  statement {
    sid    = "UseKmsForEncryption"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.ecr_oci.arn]
  }
}

resource "aws_iam_policy" "oci_publisher" {
  name        = "ecr-oci-publisher"
  description = "Permissions to push internal Helm charts and Terraform modules to ECR via create-on-push"
  policy      = data.aws_iam_policy_document.oci_publisher.json
}
```

`ecr:GetAuthorizationToken` requires `*` resource (AWS limitation). All
other actions are scoped to the two managed prefixes.

## API / Interface Changes

This design exposes no public Terraform module surface yet — the resources
above are intended to live in the artifact-hosting account's root
configuration. A future iteration may package them as a reusable internal
module (input surface would be `org_id`, `region`, KMS overrides), but
the v1 ask is to stand up the registry, not to ship a module.

The publisher-side interface is the `aws_iam_policy.oci_publisher` ARN —
emit it as a Terraform `output` (or reference via SSM Parameter Store)
so downstream CI / IRSA roles can attach it without copy-pasting policy
JSON.

## Data Model

No schema changes. ECR repositories materialize lazily on first push; the
template's configuration becomes the repo's configuration at creation
time and does not auto-update on template edits (this is an ECR property,
not a Terraform property — see Open Questions).

## Testing Strategy

Per [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md)
and [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md),
the fleet's standard tooling is `terraform test` for plan-time invariants
and libtftest for apply-time runtime validation.

### Plan-time invariants (`terraform test`)

- Both `aws_ecr_repository_creation_template` resources plan with the
  expected `prefix`, `applied_for = ["CREATE_ON_PUSH"]`, encryption,
  custom role, and repository policy.
- The org-wide policy document's encoded JSON includes the
  `aws:PrincipalOrgID` condition and the org ID from
  `data.aws_organizations_organization.this`.
- The publisher policy's encoded JSON scopes `ecr:CreateRepository` to
  the two managed prefix ARNs.
- The lifecycle policy JSON embeds `countNumber: 90` for rule 1 and
  `countNumber: 7` for rule 2 (mirrors the assertion shape in
  `modules/eks/ecr-pull-through-cache/tests/lifecycle_json.tftest.hcl`).

### Apply-time validation

As of LocalStack Pro 2026.5.0, `aws_ecr_repository_creation_template` is
**not implemented** — see
`modules/eks/ecr-pull-through-cache/tests-localstack/FINDINGS.md` for the
501 evidence captured during IMPL-0005 Phase 9. Until LocalStack lands
the API, apply-time validation is a real-account smoke (the
`helm push` / `aws ecr describe-repositories` verification recipe in
RFC-0002 §References). The 501 is filed as sneakystack backlog;
re-validate when a release bump lands the API.

### Verification smoke (post-apply)

```bash
# Authenticate
aws ecr get-login-password --region us-west-2 \
  | helm registry login --username AWS --password-stdin \
      "${ACCOUNT_ID}.dkr.ecr.us-west-2.amazonaws.com"

# Create a throwaway chart and push it
helm create smoke-test
helm package smoke-test
helm push smoke-test-0.1.0.tgz \
  oci://${ACCOUNT_ID}.dkr.ecr.us-west-2.amazonaws.com/helm-charts

# Confirm the repo was created with template settings
aws ecr describe-repositories \
  --repository-names helm-charts/smoke-test \
  --query 'repositories[0].{Encryption:encryptionConfiguration,Mutability:imageTagMutability}'

aws ecr get-lifecycle-policy \
  --repository-name helm-charts/smoke-test

aws ecr get-repository-policy \
  --repository-name helm-charts/smoke-test
```

Confirm:

- `encryptionConfiguration.encryptionType == "KMS"` and the right key ARN
- `imageTagMutability == "IMMUTABLE_WITH_EXCLUSION"` with the `latest`
  exclusion filter
- Lifecycle policy matches the template
- Repository policy contains the `aws:PrincipalOrgID` condition

If the policy is missing or the mutability is wrong, the most common cause
is that the principal pushing didn't trigger the `CREATE_ON_PUSH` path —
either the repo already existed (template only applies at creation) or the
prefix didn't match.

## Migration / Rollout Plan

Follows RFC-0002's four-phase plan. This design owns Phase 1 (Foundation)
and provides the reusable IAM policy that unblocks Phase 2 (Publisher IAM).
Phases 3-4 (publish migration, consumer migration) are operational work
outside this design.

### Cleanup notes

- Deleting a creation template does **not** affect existing repos. Repos
  retain whatever config they were created with.
- Changing a template's settings does **not** retroactively apply to
  existing repos. If you change the lifecycle policy and need it
  everywhere, write a one-shot script that iterates
  `aws ecr describe-repositories --query 'repositories[?starts_with(repositoryName, \`helm-charts/\`)]'`
  and applies the new policy with `aws ecr put-lifecycle-policy`.

## Open Questions

1. **Module packaging.** Should the resources above be packaged as a
   reusable Terraform module under `modules/ecr/` in this repo, or kept
   inline in the artifact-hosting account's root config? Argument for
   packaging: reusability if a second org-wide registry instance is ever
   needed (unlikely). Argument against: the registry is a singleton per
   org, so abstraction adds indirection with no payoff. **Tentative
   answer:** keep inline; revisit if a second instance materializes.

2. **`scan_on_push` per-prefix vs per-account.** The pull-through-cache
   module ([DESIGN-0005](0005-ecr-pull-through-cache-module.md)) found
   that the v6 provider's template schema does NOT expose `scan_on_push`
   ([IMPL-0005](../impl/0005-ecr-pull-through-cache-module-implementation.md)
   Q3 outcome). ECR scan-on-push is per-account
   (`aws_ecr_registry_scanning_configuration`). This design inherits the
   same constraint — scan-on-push is out of scope here; enable it once
   at the account level if desired.

3. **`tf-modules/` lifecycle.** The current design uses the same lifecycle
   as `helm-charts/`. If product teams pin to old pre-release module tags
   beyond 90 days in practice, drop rule 1 from the `tf_modules` template.
   Defer until consumer behavior is observed.

4. **`images/` namespace integration.** This design leaves the existing
   `images/` namespace alone. A future ADR may govern whether
   `images/` is migrated to a template-based model too, but that is out
   of scope here.

## References

- [RFC-0002](../rfc/0002-ecr-layout-for-internal-oci-artifacts.md) — ECR Layout for Internal OCI Artifacts
- [ADR-0016](../adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md) — Use ECR Repository Creation Templates for OCI Artifact Repos
- [DESIGN-0005](0005-ecr-pull-through-cache-module.md) — EKS-facing pull-through cache module (distinct scope; same provider gotchas around the template schema)
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants
- [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md) — libtftest for apply-time runtime validation
- [Amazon ECR repository creation templates](https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-creation-templates.html)
- [Pushing a Helm chart to an Amazon ECR private repository](https://docs.aws.amazon.com/AmazonECR/latest/userguide/push-oci-artifact.html)
