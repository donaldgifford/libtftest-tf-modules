---
id: RFC-0002
title: "ECR Layout for Internal OCI Artifacts"
status: Draft
author: Donald Gifford
created: 2026-05-18
---
<!-- markdownlint-disable-file MD025 MD041 -->

# RFC 0002: ECR Layout for Internal OCI Artifacts

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-18

<!--toc:start-->
- [Summary](#summary)
- [Problem Statement](#problem-statement)
- [Proposed Solution](#proposed-solution)
- [Design](#design)
  - [ECR repository model](#ecr-repository-model)
  - [Namespacing](#namespacing)
  - [Repository Creation Templates](#repository-creation-templates)
  - [Tag mutability](#tag-mutability)
  - [Lifecycle policy](#lifecycle-policy)
  - [Cross-account access](#cross-account-access)
  - [Encryption](#encryption)
  - [IAM for publishers](#iam-for-publishers)
- [Alternatives Considered](#alternatives-considered)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Foundation](#phase-1-foundation)
  - [Phase 2: Publisher IAM](#phase-2-publisher-iam)
  - [Phase 3: Migration](#phase-3-migration)
  - [Phase 4: Consumer Migration](#phase-4-consumer-migration)
- [Risks and Mitigations](#risks-and-mitigations)
- [Success Criteria](#success-criteria)
- [References](#references)
<!--toc:end-->

## Summary

We will use Amazon ECR as our internal OCI registry for Helm charts and
Terraform modules. ECR repositories will be auto-created via Repository
Creation Templates using two prefix-based namespaces — `helm-charts/` and
`tf-modules/` — with one ECR repository per artifact identity. This
eliminates per-artifact provisioning toil while enforcing uniform encryption,
lifecycle, tag mutability, and access policies registry-wide.

## Problem Statement

We publish a growing set of internal Helm charts and Terraform modules that
are consumed across our AWS estate (200+ accounts, ~1,500 developers). We
want a single distribution format (OCI) so consumers use one authentication
model and one set of tooling. ECR is the natural target given existing AWS
investment, IRSA-based authentication, and account-scoped IAM controls.

The core friction is that ECR's data model maps one repository to one
artifact identity (chart or module name) — not the source Git repo. A Git
repo named `helm-charts` containing twenty charts maps to twenty ECR
repositories named `helm-charts/<chart-name>`. Slashes are a naming
convention; there is no real hierarchy inside ECR.

This raises three operational questions:

1. How do we provision these repos at scale without per-artifact Terraform
   sprawl?
2. How do we enforce uniform encryption, lifecycle, tag mutability, and
   access policies across them?
3. How do we expose them to consumers across many AWS accounts without
   per-repo permission grants?

## Proposed Solution

Use ECR Repository Creation Templates (GA July 2024) with the
`CREATE_ON_PUSH` action to lazily create repositories with consistent
configuration on first push.

- Reserve two prefixes: `helm-charts/` for Helm charts, `tf-modules/` for
  Terraform modules.
- One creation template per prefix specifies encryption, lifecycle policy,
  tag mutability, and a resource-based access policy.
- CI pipelines push using standard `helm push` / Terraform OCI module
  tooling; ECR creates the underlying repo lazily on first push.
- Org-wide pull access is granted via an `aws:PrincipalOrgID` condition on
  the template's repository policy, propagating to every auto-created repo.

This eliminates per-artifact Terraform resources and centralizes policy on
two registry-scoped objects.

## Design

### ECR repository model

A "repository" in ECR is a namespace for one artifact identity plus its
tagged versions. Tags are versions. Slashes in repo names are a naming
convention, not a hierarchy.

Helm's OCI push appends the chart name automatically:

```bash
helm push api-1.2.0.tgz oci://acct.dkr.ecr.region.amazonaws.com/helm-charts
# → creates/uses repo helm-charts/api with tag 1.2.0
```

Terraform's OCI module support follows the same pattern: module name becomes
the final path segment, version becomes the tag.

Container images backing a chart belong in a separate repository (e.g.
`images/api`), since OCI artifact types and image types are distinct and
typically have different lifecycle requirements.

### Namespacing

| Prefix | Contents | Example repo |
|--------|----------|--------------|
| `helm-charts/` | Internal Helm charts | `helm-charts/api-service` |
| `tf-modules/` | Internal Terraform modules | `tf-modules/eks-cluster` |
| `images/` | Container images (existing, unchanged) | `images/api-service` |

### Repository Creation Templates

- Templates match repos by longest prefix; `ROOT` is the catch-all.
- `applied_for = ["CREATE_ON_PUSH"]` triggers template application when ECR
  auto-creates a repo on first push.
- Templates apply only at creation; editing a template later does **not**
  backfill existing repos.

### Tag mutability

- Use `IMMUTABLE_WITH_EXCLUSION` so versioned tags (semver) cannot be
  overwritten — chart and module versions are contracts consumers pin to.
- Exclude floating tags (`latest`, optionally `dev-*`) via wildcard
  exclusion filters where teams need them.
- Requires AWS Terraform provider >= 6.8.0. Fall back to plain `IMMUTABLE`
  and forbid floating tags via CI lint if not available.

### Lifecycle policy

- Tagged versioned artifacts: retain indefinitely. Semver tags are
  contracts and consumers may pin to old versions.
- Pre-release / dev tags (`dev-*`, `rc-*`, `snapshot-*`): expire 90 days
  after push.
- Untagged manifests: expire 7 days after push.

### Cross-account access

- The template's `repository_policy` grants pull
  (`BatchGetImage`, `GetDownloadUrlForLayer`,
  `BatchCheckLayerAvailability`) to any principal in the organization via
  an `aws:PrincipalOrgID` condition.
- New repos inherit this policy automatically on creation. No per-repo or
  per-account grants required.

### Encryption

- KMS encryption with a dedicated CMK for OCI artifacts.
- Cross-repository blob mounting requires matching encryption config; keep
  all OCI artifact repos under the same key.
- KMS or `resource_tags` in a template require a `customRoleArn`. We will
  create one dedicated role that ECR assumes during repo creation.

### IAM for publishers

CI roles publishing charts and modules need:

```text
ecr:GetAuthorizationToken
ecr:CreateRepository
ecr:DescribeRepositories
ecr:InitiateLayerUpload
ecr:UploadLayerPart
ecr:CompleteLayerUpload
ecr:BatchCheckLayerAvailability
ecr:PutImage
```

Scope `ecr:CreateRepository` to
`arn:aws:ecr:*:*:repository/helm-charts/*` and
`arn:aws:ecr:*:*:repository/tf-modules/*` to prevent stray repo creation
outside our managed prefixes.

## Alternatives Considered

1. **GitHub Container Registry (GHCR)** — works fine, but consumers are AWS
   workloads using IRSA. GHCR adds a second auth model (PAT-based) and a
   single-vendor dependency for distribution.
2. **ChartMuseum + Terraform HTTP module registry** — separate protocols
   per artifact type, separate infrastructure to maintain, no IAM
   integration.
3. **Pre-create every repo in Terraform** — explicit and inspectable, but
   requires a platform PR for every new chart or module. At hundreds of
   artifacts this is meaningful toil and slows down product teams who
   shouldn't need to wait on us to publish a new chart version.
4. **Flat namespace (no `helm-charts/` prefix)** — workable but loses the
   ability to differentiate config across artifact types (different
   lifecycle for charts vs modules vs container images) and conflates
   names with the existing `images/` namespace.
5. **Multi-account fan-out via ECR replication** — adds cost and complexity;
   cross-account pull via repository policy is simpler at this scale.

## Implementation Phases

### Phase 1: Foundation

- Create KMS key for OCI artifacts in the artifact-hosting account.
- Create the `ecr-template` IAM role (assumed by ECR during repo creation).
- Apply two repository creation templates (`helm-charts/`, `tf-modules/`).
- Validate by pushing a test chart and module.

### Phase 2: Publisher IAM

- Update CI / IRSA roles for chart and module publishers to include the
  required ECR permissions, scoped to the managed prefixes.
- Test create-on-push end-to-end from an actual CI pipeline.
- Add a reusable IAM policy module so teams onboarding new publishers
  don't reinvent it.

### Phase 3: Migration

- Publish existing internal charts to ECR alongside current locations
  during transition.
- Publish Terraform modules as OCI artifacts.

### Phase 4: Consumer Migration

- Update ArgoCD repository configs to pull charts from ECR.
- Update Terraform/Terragrunt sources to reference modules via OCI.
- Decommission legacy distribution paths once stable.

## Risks and Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Publishers missing `ecr:CreateRepository` → silent first-push failures | Medium | High during rollout | Document the gotcha in onboarding; ship a reusable IAM policy module |
| `IMMUTABLE_WITH_EXCLUSION` requires recent Terraform provider | Low | Low | Fall back to plain `IMMUTABLE`, forbid floating tags via CI lint |
| Template edits don't backfill existing repos | Medium | Medium | Document explicitly; provide a remediation script for bulk config updates |
| Org-wide pull policy too permissive for some artifacts | Low | Low | Acceptable for internal artifacts; if needed, scope to specific OUs via `aws:PrincipalOrgPaths` |
| ECR throttling on first-push burst during mass migration | Low | Low | Serialize initial migration pushes |
| Encryption-key mismatch prevents cross-repo blob mounting | Medium | Low | Single KMS key for all OCI artifact prefixes; documented in design |

## Success Criteria

- Zero per-artifact Terraform resources for ECR repos under the
  `helm-charts/` and `tf-modules/` prefixes.
- New charts and modules can be published by CI without platform-team
  intervention.
- Cross-account consumers can pull without per-repo grants.
- Tag mutability, lifecycle, and encryption policies are uniformly
  applied across all new repos under the managed prefixes.

## References

- [Amazon ECR repository creation templates](https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-creation-templates.html)
- [Pushing a Helm chart to an Amazon ECR private repository](https://docs.aws.amazon.com/AmazonECR/latest/userguide/push-oci-artifact.html)
- [ADR-0016](../adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md) — Use ECR Repository Creation Templates for OCI Artifact Repos
- [DESIGN-0006](../design/0006-org-wide-ecr-oci-artifact-registry.md) — Org-wide ECR OCI Artifact Registry (reference Terraform implementation)
