---
id: ADR-0016
title: "Use ECR Repository Creation Templates for OCI Artifact Repos"
status: Proposed
author: Donald Gifford
created: 2026-05-18
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0016. Use ECR Repository Creation Templates for OCI Artifact Repos

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

Proposed

## Context

We publish internal Helm charts and Terraform modules as OCI artifacts to
Amazon ECR. ECR's data model maps one repository to one artifact identity
(chart or module name), so every chart and every module requires its own
ECR repository. At our scale (hundreds of internal artifacts across many
teams), pre-provisioning each repo in Terraform creates significant
ongoing toil and couples artifact publication to platform-team review
cycles.

ECR Repository Creation Templates (GA July 2024) allow us to define
configuration that ECR applies automatically when a new repo is created
via push, replication, or pull-through-cache. The template matches against
a configurable prefix and applies encryption, lifecycle, tag mutability,
repository policy, and tags to any new repo under that prefix.

See [RFC-0002](../rfc/0002-ecr-layout-for-internal-oci-artifacts.md) for
the full proposal and analysis.

## Decision

We will use ECR Repository Creation Templates with `CREATE_ON_PUSH` to
manage OCI artifact repositories, organized under two prefixes:

- `helm-charts/` — internal Helm charts
- `tf-modules/` — internal Terraform modules

One Terraform `aws_ecr_repository_creation_template` resource exists per
prefix. No per-artifact ECR repository resources are provisioned. Repos
materialize lazily on first push with the template-defined configuration.

## Consequences

### Positive

- Zero per-artifact ECR Terraform resources; new charts and modules can be
  published without platform-team PRs.
- Encryption, lifecycle, tag mutability, and access policies are uniformly
  enforced by registry-scoped configuration.
- Cross-account pull access propagates automatically via the template's
  repository policy with an `aws:PrincipalOrgID` condition.
- Operationally simple: two Terraform resources govern the entire OCI
  artifact surface.

### Negative

- Publishing CI roles require `ecr:CreateRepository`; without it, the
  first push of a new artifact fails with a permissions error rather than
  an obvious template-related message. This is a known onboarding gotcha
  that must be documented in the publisher IAM module.
- Edits to a template do **not** backfill existing repos. Configuration
  drift requires explicit remediation scripts or repo recreation.
- KMS encryption and resource tags in a template require a `customRoleArn`,
  adding one IAM role to manage.

### Neutral

- Creates a soft coupling between artifact naming and registry policy: the
  prefix becomes the policy boundary, so any future need to differentiate
  policy within a prefix would require splitting the namespace.
- Existing container image repos under `images/` are unaffected; this ADR
  only governs new OCI artifact namespaces.
- This ADR governs the **fleet-wide** OCI artifact registry (one
  instantiation per account that hosts OCI artifacts). It is unrelated to
  the per-region EKS pull-through cache module governed by
  [ADR-0015](0015-permit-opt-in-third-managed-policy-on-node-role-for-ecr-pull.md)
  and [DESIGN-0005](../design/0005-ecr-pull-through-cache-module.md). The
  two consume ECR but for distinct purposes.

## Alternatives Considered

1. **Per-repo `aws_ecr_repository` Terraform resources** — explicit and
   discoverable, but requires a platform PR for every new chart/module.
   Rejected due to toil at scale.
2. **Single flat namespace** — workable but conflates artifact types and
   prevents per-prefix policy differentiation. Rejected.
3. **Off-ECR distribution (ChartMuseum, Terraform HTTP registry)** —
   separate auth, separate infrastructure, no IAM integration. Rejected.

## References

- [RFC-0002](../rfc/0002-ecr-layout-for-internal-oci-artifacts.md) — ECR Layout for Internal OCI Artifacts
- [DESIGN-0006](../design/0006-org-wide-ecr-oci-artifact-registry.md) — Org-wide ECR OCI Artifact Registry (reference Terraform implementation)
- [ECR Repository Creation Templates documentation](https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-creation-templates.html)
