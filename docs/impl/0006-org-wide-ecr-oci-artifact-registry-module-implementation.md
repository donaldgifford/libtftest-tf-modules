---
id: IMPL-0006
title: "Org-wide ECR OCI Artifact Registry Module Implementation"
status: Draft
author: Donald Gifford
created: 2026-05-18
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0006: Org-wide ECR OCI Artifact Registry Module Implementation

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-18

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Module scaffolding and variable surface](#phase-1-module-scaffolding-and-variable-surface)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Data sources and locals](#phase-2-data-sources-and-locals)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: KMS key (gated bring-your-own)](#phase-3-kms-key-gated-bring-your-own)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: ECR-assumed IAM role](#phase-4-ecr-assumed-iam-role)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Repository creation templates + org-wide pull policy](#phase-5-repository-creation-templates--org-wide-pull-policy)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: Publisher IAM policy](#phase-6-publisher-iam-policy)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
  - [Phase 7: Outputs](#phase-7-outputs)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
  - [Phase 8: terraform test plan-only suite (tests/)](#phase-8-terraform-test-plan-only-suite-tests)
    - [Tasks](#tasks-7)
    - [Success Criteria](#success-criteria-7)
  - [Phase 9: terraform test apply-against-LocalStack suite (tests-localstack/)](#phase-9-terraform-test-apply-against-localstack-suite-tests-localstack)
    - [Tasks](#tasks-8)
    - [Success Criteria](#success-criteria-8)
  - [Phase 10: README, USAGE, prereq docs, final audits](#phase-10-readme-usage-prereq-docs-final-audits)
    - [Tasks](#tasks-9)
    - [Success Criteria](#success-criteria-9)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [Q1 — name_prefix semantics: prefix every resource name, or hardcode singletons?](#q1--nameprefix-semantics-prefix-every-resource-name-or-hardcode-singletons)
  - [Q2 — data.awsorganizationsorganization permission scope](#q2--dataawsorganizationsorganization-permission-scope)
  - [Q3 — LocalStack Pro fidelity for data.awsorganizationsorganization](#q3--localstack-pro-fidelity-for-dataawsorganizationsorganization)
  - [Q4 — Existing-repo migration tooling](#q4--existing-repo-migration-tooling)
  - [Q5 — var.tags shape: typed object or simple map(string)?](#q5--vartags-shape-typed-object-or-simple-mapstring)
  - [Q6 — IMMUTABLEWITHEXCLUSION provider version guard](#q6--immutablewithexclusion-provider-version-guard)
  - [Q7 — Output via SSM Parameter Store?](#q7--output-via-ssm-parameter-store)
  - [Q8 — Module-managed KMS key destruction safety](#q8--module-managed-kms-key-destruction-safety)
- [References](#references)
<!--toc:end-->

## Objective

Implement `modules/ecr/org-registry/` — the fleet-shared, account-level
module that provisions the org-wide OCI artifact registry. The module
emits two `aws_ecr_repository_creation_template` resources (one per
managed prefix — `helm-charts/`, `tf-modules/`), a supporting KMS key,
an ECR-assumed IAM role, and a reusable publisher IAM policy that CI /
IRSA roles attach to push internal Helm charts and Terraform modules.

**Implements:** [DESIGN-0006](../design/0006-org-wide-ecr-oci-artifact-registry.md)
([RFC-0002](../rfc/0002-ecr-layout-for-internal-oci-artifacts.md) /
[ADR-0016](../adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md)).

## Scope

### In Scope

- One `aws_ecr_repository_creation_template` per managed prefix
  (`helm-charts/`, `tf-modules/`) with:
  - `applied_for = ["CREATE_ON_PUSH"]`
  - `image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"` with a wildcard
    exclusion filter on `latest` (provider `~> 6.2` resolves to `>= 6.8.0`
    in practice; verified against `hashicorp/aws v6.45.0` installed).
  - KMS-encrypted via `local.kms_key_arn` (module-managed or
    caller-supplied per `var.kms_key_arn`).
  - `custom_role_arn` set to the module's ECR-assumed IAM role —
    required by ECR for KMS + `resource_tags`.
  - `lifecycle_policy` JSON expiring `dev-*` / `rc-*` / `snapshot-*` tags
    after `var.pre_release_retention_days` and untagged manifests after
    `var.untagged_retention_days`.
  - `repository_policy` granting org-wide pull via
    `aws:PrincipalOrgID` condition.
  - `resource_tags` merging `var.tags` with the module's
    `artifact_type` marker (`helm-chart` / `terraform-module`) per
    template.
- Gated module-managed KMS key (`aws_kms_key.ecr_oci[0]` + alias) with
  rotation on, 30-day deletion window. Gate is
  `var.kms_key_arn == null` — bring-your-own pattern matches the
  cluster module's KMS handling.
- `aws_iam_role.ecr_template` + `aws_iam_role_policy.ecr_template`
  granting ECR (`CreateRepository`, `PutLifecyclePolicy`,
  `SetRepositoryPolicy`, `TagResource` on the two managed prefixes) and
  KMS (`Encrypt` / `Decrypt` / `ReEncrypt*` / `GenerateDataKey*` /
  `DescribeKey` on `local.kms_key_arn`).
- Shared `data.aws_iam_policy_document.org_pull` (single declaration,
  embedded in both templates' `repository_policy`).
- `aws_iam_policy.oci_publisher` — reusable policy attached by
  consumers (CI / IRSA roles) granting auth + scoped push + KMS encrypt.
- `data.aws_caller_identity.current` for IAM resource ARN scoping
  ([ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md)
  identity-class carve-out).
- `data.aws_organizations_organization.this` count-gated on
  `var.organizations_org_id == null` — bring-your-own org ID for accounts
  that lack `organizations:DescribeOrganization` permissions or for
  test scenarios that need a deterministic value (Q2).
- Plan-time `terraform test` suite covering resource counts,
  bring-your-own KMS gating, lifecycle JSON content, repository-policy
  JSON content, publisher-policy scope, and prefix overrides.
- Apply-against-LocalStack `terraform test` suite — explicit
  gap-discovery; inherits the IMPL-0005 Phase 9 finding that
  LocalStack Pro 2026.5.0 returns 501 for
  `CreateRepositoryCreationTemplate` (this module hits the same API).

### Out of Scope

- Migration of existing `helm-charts/*` / `tf-modules/*` repos that
  pre-date this module — the template doesn't backfill them. Operator
  tooling (a bulk `aws ecr put-lifecycle-policy` script) is documented
  in the README but not emitted by the module.
- Container image repos under `images/` — predates this design;
  unaffected ([DESIGN-0006](../design/0006-org-wide-ecr-oci-artifact-registry.md)
  §Non-Goals).
- Cross-account ECR replication — out of scope per RFC-0002
  Alternatives §5.
- SSM Parameter Store export of `publisher_policy_arn` — defer to a
  consumer-side wrapper if it materializes.
- Per-prefix KMS keys — DESIGN-0006 mandates a single shared key for
  cross-repo blob mounting.
- Kubernetes-API objects (no `kubernetes` / `kubectl` / `helm` provider
  references — [ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md)).

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its
tasks are checked off and its success criteria are met.

---

### Phase 1: Module scaffolding and variable surface

Copy the per-module scaffolding from `modules/ecr/pull-through-cache/`
(closest sibling — fleet-shared, no remote state, same provider pin).
Define the full input contract. Validation blocks reject misconfigured
inputs at plan time. No resources yet.

#### Tasks

- [ ] Create `modules/ecr/org-registry/` directory.
- [ ] Copy scaffolding files verbatim from
      `modules/ecr/pull-through-cache/`: `.terraform-docs.yml`,
      `.tflint.hcl`, `README.md` stub, `USAGE.md` skeleton.
- [ ] Create `versions.tf` pinning `hashicorp/aws ~> 6.2`, Terraform
      `>= 1.1` (matches the fleet pin; resolves to >= 6.8.0 in practice,
      which is the minimum for `IMMUTABLE_WITH_EXCLUSION`).
- [ ] Create `variables.tf` with the input surface from DESIGN-0006:
  - Required: `name_prefix` (`string`).
  - Optional:
    - `kms_key_arn` (`string`, default `null`) — caller-supplied KMS
      key ARN. Null routes to module-managed key.
    - `helm_charts_prefix` (`string`, default `"helm-charts"`).
    - `tf_modules_prefix` (`string`, default `"tf-modules"`).
    - `pre_release_retention_days` (`number`, default `90`).
    - `untagged_retention_days` (`number`, default `7`).
    - `organizations_org_id` (`string`, default `null`) — caller-
      supplied org ID. Null routes to the
      `data.aws_organizations_organization.this` data source.
    - `tags` (`map(string)`, default `{}`).
- [ ] Add `validation` block on `pre_release_retention_days`:
      `pre_release_retention_days >= 1` (ECR rejects 0).
- [ ] Add `validation` block on `untagged_retention_days`:
      `untagged_retention_days >= 1`.
- [ ] Add `validation` block on each of `helm_charts_prefix` /
      `tf_modules_prefix`: match the AWS provider v6 schema rule for
      `aws_ecr_repository_creation_template.prefix` —
      `length(value) >= 2 && length(value) <= 256 &&
      can(regex("^[a-zA-Z0-9_./-]+$", value))`. Reject the literal
      `"ROOT"` (we're using prefix-scoped templates, not the catch-all).
- [ ] Add `validation` block on `organizations_org_id`: when non-null,
      must match `^o-[a-z0-9]{10,32}$` (AWS Organizations ID format).
- [ ] Create empty `main.tf`, `kms.tf`, `iam.tf`, `templates.tf`,
      `publisher.tf`, `locals.tf`, `outputs.tf` files.
- [ ] Run `terraform init && terraform validate`.
- [ ] Run `tflint --init && tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass clean.
- `terraform-docs .` produces a USAGE.md table listing every variable.
- Scaffolding files match the pull-through-cache module's shape
  verbatim.
- `pre_release_retention_days = 0` fails at plan with a clear
  validation error.
- `helm_charts_prefix = "ROOT"` fails at plan (we don't want the
  catch-all here).
- `organizations_org_id = "bogus"` fails at plan with the org-ID
  format error.

---

### Phase 2: Data sources and locals

Add the two data sources (one always-on, one count-gated) and the
locals that drive name composition and KMS-key / org-ID resolution.

#### Tasks

- [ ] In `main.tf`, add `data "aws_caller_identity" "current" {}`
      ([ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md)
      identity-class carve-out — same shape as
      `modules/ecr/pull-through-cache/`).
- [ ] In `main.tf`, add
      `data "aws_organizations_organization" "this"` count-gated on
      `var.organizations_org_id == null`. The data source requires
      `organizations:DescribeOrganization` (Q2); the var.input is the
      escape hatch for accounts without that permission and for tests.
- [ ] In `locals.tf`, derive `local.account_id =
      data.aws_caller_identity.current.account_id` (used to scope IAM
      ARNs to this account's ECR repositories).
- [ ] In `locals.tf`, derive `local.org_id = coalesce(var.organizations_org_id,
      try(data.aws_organizations_organization.this[0].id, null))`.
      Null is impossible by construction (one of the two paths
      resolves); the `try()` keeps plan-time evaluation safe when the
      data source is gated off.
- [ ] In `locals.tf`, derive
      `local.kms_key_arn = coalesce(var.kms_key_arn,
      try(aws_kms_key.ecr_oci[0].arn, null))`. Meaningful conditional
      work — both templates and the ECR-template IAM role reference
      this single value (no aliasing local; consumed at the use site).
- [ ] In `locals.tf`, compose the deterministic resource-name locals:
      `kms_alias_name = "alias/${var.name_prefix}-ecr-oci"`,
      `template_role_name = "${var.name_prefix}-ecr-template"`,
      `publisher_policy_name = "${var.name_prefix}-oci-publisher"`.
- [ ] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- With `var.organizations_org_id = null`, plan reads one
  `data.aws_organizations_organization.this` instance.
- With `var.organizations_org_id = "o-abc1234567"`, plan reads zero
  `data.aws_organizations_organization.this` instances; `local.org_id`
  echoes the var value.
- No aliasing locals that re-export remote-state fields (ADR-0001 /
  CLAUDE.md) — the only data sources are `aws_caller_identity` and the
  gated `aws_organizations_organization`.

---

### Phase 3: KMS key (gated bring-your-own)

Provision the module-managed KMS key + alias when
`var.kms_key_arn == null`. Both the templates' encryption and the ECR-
assumed IAM role's KMS permissions resolve through `local.kms_key_arn`
so the same code path works for both bring-your-own and module-managed.

#### Tasks

- [ ] In `kms.tf`, add `aws_kms_key.ecr_oci` count-gated on
      `var.kms_key_arn == null`:
  - `description = "ECR encryption key for OCI artifact repos (${var.helm_charts_prefix}/*, ${var.tf_modules_prefix}/*)"`.
  - `enable_key_rotation = true`.
  - `deletion_window_in_days = 30`.
  - `tags = var.tags`.
- [ ] In `kms.tf`, add `aws_kms_alias.ecr_oci` count-gated identically:
  - `name = local.kms_alias_name`.
  - `target_key_id = aws_kms_key.ecr_oci[0].key_id`.
- [ ] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- With default (`kms_key_arn = null`), plan contains exactly one
  `aws_kms_key.ecr_oci` and one `aws_kms_alias.ecr_oci`.
- With `kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/bring-your-own"`,
  plan contains zero KMS resources from this module; `local.kms_key_arn`
  echoes the BYO ARN.

---

### Phase 4: ECR-assumed IAM role

The templates' `custom_role_arn` is required when the templates use
KMS encryption or `resource_tags`. This role is assumed by the
`ecr.amazonaws.com` service principal at repo-creation time.

#### Tasks

- [ ] In `iam.tf`, add
      `data "aws_iam_policy_document" "ecr_template_assume"` with one
      statement allowing `sts:AssumeRole` for the `ecr.amazonaws.com`
      service principal.
- [ ] In `iam.tf`, add `aws_iam_role.ecr_template`:
  - `name = local.template_role_name`.
  - `description = "Assumed by ECR when creating repos via creation templates (managed by org-registry module)"`.
  - `assume_role_policy = data.aws_iam_policy_document.ecr_template_assume.json`.
  - `tags = var.tags`.
- [ ] In `iam.tf`, add
      `data "aws_iam_policy_document" "ecr_template"` with two
      statements:
  - `sid = "ManageRepoConfig"`: actions `["ecr:CreateRepository",
    "ecr:PutLifecyclePolicy", "ecr:SetRepositoryPolicy",
    "ecr:TagResource"]`, resources scoped to both managed prefixes:
    `["arn:aws:ecr:*:${local.account_id}:repository/${var.helm_charts_prefix}/*",
    "arn:aws:ecr:*:${local.account_id}:repository/${var.tf_modules_prefix}/*"]`.
  - `sid = "UseKmsKey"`: actions `["kms:Encrypt", "kms:Decrypt",
    "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]`,
    resources `[local.kms_key_arn]`.
- [ ] In `iam.tf`, add `aws_iam_role_policy.ecr_template`:
  - `name = "${var.name_prefix}-ecr-template-permissions"`.
  - `role = aws_iam_role.ecr_template.id`.
  - `policy = data.aws_iam_policy_document.ecr_template.json`.
- [ ] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- Plan contains exactly one `aws_iam_role.ecr_template` and one
  `aws_iam_role_policy.ecr_template`.
- The role's `assume_role_policy` JSON includes the
  `ecr.amazonaws.com` service principal.
- The role-policy's JSON `Resource` field for the `ManageRepoConfig`
  statement contains both managed-prefix ARNs (uses the same
  `local.account_id` placeholder both modules use).

---

### Phase 5: Repository creation templates + org-wide pull policy

Two `aws_ecr_repository_creation_template` resources share one
`data.aws_iam_policy_document.org_pull` source for their
`repository_policy`. The templates differ only in `prefix` and
the `artifact_type` resource tag (and could differ in lifecycle later
if `tf-modules/` needs separate retention — DESIGN-0006 §Open
Questions).

#### Tasks

- [ ] In `templates.tf`, add
      `data "aws_iam_policy_document" "org_pull"`:
  - One statement granting `["ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability",
    "ecr:DescribeImages", "ecr:DescribeRepositories"]` to
    `principals { type = "AWS"; identifiers = ["*"] }` with a
    `condition { test = "StringEquals"; variable =
    "aws:PrincipalOrgID"; values = [local.org_id] }`.
- [ ] In `templates.tf`, add
      `aws_ecr_repository_creation_template.helm_charts`:
  - `prefix = var.helm_charts_prefix`.
  - `applied_for = ["CREATE_ON_PUSH"]`.
  - `description = "Internal Helm charts published as OCI artifacts"`.
  - `image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"`.
  - `image_tag_mutability_exclusion_filter { filter = "latest";
    filter_type = "WILDCARD" }`.
  - `encryption_configuration { encryption_type = "KMS"; kms_key =
    local.kms_key_arn }`.
  - `custom_role_arn = aws_iam_role.ecr_template.arn`.
  - `lifecycle_policy = jsonencode({ rules = [ ... ] })` — two rules
    (pre-release expire after `var.pre_release_retention_days`,
    untagged expire after `var.untagged_retention_days`); mirrors
    DESIGN-0006's reference Terraform.
  - `repository_policy = data.aws_iam_policy_document.org_pull.json`.
  - `resource_tags = merge(var.tags, { artifact_type = "helm-chart",
    managed_by = "platform" })`.
- [ ] In `templates.tf`, add
      `aws_ecr_repository_creation_template.tf_modules` — identical
      shape to `helm_charts` except:
  - `prefix = var.tf_modules_prefix`.
  - `description = "Internal Terraform modules published as OCI artifacts"`.
  - `resource_tags`'s `artifact_type = "terraform-module"`.
- [ ] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- Plan contains exactly two
  `aws_ecr_repository_creation_template` resources.
- Both templates' `encryption_configuration.kms_key` resolves to
  `local.kms_key_arn`.
- Both templates' `repository_policy` resolves to the same
  org-wide-pull JSON.
- Each template's `resource_tags` includes the canonical
  `artifact_type` marker (`helm-chart` vs `terraform-module`).

---

### Phase 6: Publisher IAM policy

Reusable customer-managed policy attached by CI / IRSA roles in
consumer accounts (or in the artifact-hosting account itself, when CI
runs there). Grants ECR auth + scoped push + KMS encrypt.

#### Tasks

- [ ] In `publisher.tf`, add
      `data "aws_iam_policy_document" "oci_publisher"` with three
      statements:
  - `sid = "EcrAuth"`: action `["ecr:GetAuthorizationToken"]`,
    resource `["*"]` (AWS API limitation — auth token must be
    requested with `*`).
  - `sid = "EcrCreateAndPush"`: actions
    `["ecr:CreateRepository", "ecr:DescribeRepositories",
    "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
    "ecr:CompleteLayerUpload", "ecr:BatchCheckLayerAvailability",
    "ecr:PutImage"]`, resources scoped to both managed prefixes via
    the same `local.account_id` template as the ECR-template role's
    `ManageRepoConfig` statement.
  - `sid = "UseKmsForEncryption"`: actions
    `["kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]`,
    resources `[local.kms_key_arn]`.
- [ ] In `publisher.tf`, add `aws_iam_policy.oci_publisher`:
  - `name = local.publisher_policy_name`.
  - `description = "Permissions to push internal Helm charts and Terraform modules to ECR via create-on-push (consumed by CI / IRSA roles)"`.
  - `policy = data.aws_iam_policy_document.oci_publisher.json`.
  - `tags = var.tags`.
- [ ] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- Plan contains exactly one `aws_iam_policy.oci_publisher`.
- The policy's JSON `Resource` array for `EcrCreateAndPush` contains
  both managed-prefix ARNs.
- `ecr:GetAuthorizationToken` keeps `"*"` resource (deliberate).

---

### Phase 7: Outputs

Define the consumer contract. Match DESIGN-0006's API/Interface
Changes section.

#### Tasks

- [ ] In `outputs.tf`, add:
  - `helm_charts_template_id` — the helm_charts template's `id`
    attribute (per v6 schema, the resource exposes `id` not `arn`; cf.
    [IMPL-0005](0005-ecr-pull-through-cache-module-implementation.md)
    Q3).
  - `tf_modules_template_id` — same for tf_modules.
  - `kms_key_arn = local.kms_key_arn` — module-managed ARN or BYO,
    transparently.
  - `publisher_policy_arn = aws_iam_policy.oci_publisher.arn`.
  - `ecr_template_role_arn = aws_iam_role.ecr_template.arn`.
- [ ] Add clear `description` strings on each output explaining the
      consumer use case (e.g., "attach this to CI / IRSA roles").
- [ ] Regenerate `USAGE.md` via `terraform-docs .`.
- [ ] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- `terraform-docs .` regenerates `USAGE.md` listing all five outputs
  in the rendered table.
- Plan shows non-null values for every output.

---

### Phase 8: terraform test plan-only suite (`tests/`)

Plan-time invariants per
[RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md).
Resource-count assertions for the default shape (module-managed KMS)
and the BYO shape, validation negatives, lifecycle JSON content,
repository-policy JSON content, publisher-policy scope, and prefix
overrides.

#### Tasks

- [ ] Create `modules/ecr/org-registry/tests/` directory.
- [ ] Create `tests/default.tftest.hcl`:
  - `run "plan_default"`:
    `name_prefix = "platform"`, all other defaults.
    `override_data` for `data.aws_caller_identity.current` (account_id
    `000000000000`) and `data.aws_organizations_organization.this`
    (`id = "o-test1234ab"`).
    Assertions:
    - 1 `aws_kms_key.ecr_oci`.
    - 1 `aws_kms_alias.ecr_oci`.
    - 1 `aws_iam_role.ecr_template`.
    - 1 `aws_iam_role_policy.ecr_template`.
    - 2 `aws_ecr_repository_creation_template` resources (helm_charts
      + tf_modules).
    - 1 `aws_iam_policy.oci_publisher`.
- [ ] Create `tests/byo_kms.tftest.hcl`:
  - `run "plan_byo_kms"`:
    `kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"`.
    Assertions:
    - 0 `aws_kms_key.ecr_oci` resources.
    - 0 `aws_kms_alias.ecr_oci` resources.
    - Both templates' `encryption_configuration[0].kms_key` equals
      the BYO ARN (known at plan time — no unknown-value issue).
    - The ECR-template role-policy's JSON contains the BYO ARN in its
      KMS-permissions statement.
- [ ] Create `tests/lifecycle_json.tftest.hcl`:
  - `run "default_retention"`:
    `pre_release_retention_days = 90`,
    `untagged_retention_days = 7`.
    Assertions: both templates' encoded `lifecycle_policy` contain
    `"countNumber":90` AND `"countNumber":7`. Mirrors the assertion
    shape in
    `modules/ecr/pull-through-cache/tests/lifecycle_json.tftest.hcl`.
  - `run "custom_retention"`: `pre_release_retention_days = 30`,
    `untagged_retention_days = 14`. Assertions: both templates'
    encoded JSON contains `"countNumber":30` and `"countNumber":14`.
- [ ] Create `tests/repository_policy_json.tftest.hcl`:
  - `run "plan_org_pull"`: assertion that the helm_charts template's
    `repository_policy` contains both `"aws:PrincipalOrgID"` and the
    expected org ID (e.g., `"o-test1234ab"` from `override_data`).
    Same assertion against the tf_modules template (proves the shared
    policy doc reaches both templates).
- [ ] Create `tests/publisher_policy_scope.tftest.hcl`:
  - `run "scope_managed_prefixes"`: assertions on the encoded
    `aws_iam_policy.oci_publisher.policy` JSON:
    - Contains the helm_charts-prefix ARN
      (`arn:aws:ecr:*:000000000000:repository/helm-charts/*`).
    - Contains the tf_modules-prefix ARN
      (`arn:aws:ecr:*:000000000000:repository/tf-modules/*`).
    - `ecr:GetAuthorizationToken` has Resource `"*"`.
- [ ] Create `tests/prefix_override.tftest.hcl`:
  - `run "custom_prefixes"`:
    `helm_charts_prefix = "internal-charts"`,
    `tf_modules_prefix = "internal-modules"`.
    Assertions: each template's `prefix` attribute equals the custom
    value; the publisher policy's JSON contains
    `repository/internal-charts/*` and `repository/internal-modules/*`.
- [ ] Create `tests/validation.tftest.hcl`:
  - `run "negative_pre_release_zero"`:
    `pre_release_retention_days = 0`.
    `expect_failures = [var.pre_release_retention_days]`.
  - `run "negative_helm_prefix_root"`:
    `helm_charts_prefix = "ROOT"`.
    `expect_failures = [var.helm_charts_prefix]`.
  - `run "negative_bad_org_id"`:
    `organizations_org_id = "bogus"`.
    `expect_failures = [var.organizations_org_id]`.
- [ ] Create `tests/org_id_override.tftest.hcl`:
  - `run "plan_byo_org_id"`:
    `organizations_org_id = "o-bringyourown1"`. Assertions:
    - 0 `data.aws_organizations_organization.this` reads (cannot
      directly assert; rely on the absence in the plan + the absence
      of the override_data block).
    - Both templates' `repository_policy` JSON contains
      `"o-bringyourown1"`.
- [ ] Verify `just tf test ecr/org-registry` works module-agnostically.

#### Success Criteria

- All eight `.tftest.hcl` suites pass.
- Total runtime ≤ 8s (plan-only, no apply, no LocalStack).
- `expect_failures` correctly catches all three validation negatives.
- BYO-KMS test confirms zero module-managed KMS resources.
- BYO-org-id test confirms the data source is not read.

---

### Phase 9: terraform test apply-against-LocalStack suite (`tests-localstack/`)

Inherits the IMPL-0005 Phase 9 finding: LocalStack Pro 2026.5.0
returns 501 for `CreateRepositoryCreationTemplate`. This module
relies on that same API for both templates, so a full apply will hit
the same 501. Per the established Phase 9 pattern, the active suite
is a `plan_smoke` against LocalStack endpoints; the full apply is
preserved as commented HCL for re-enable when LocalStack lands the
API.

#### Tasks

- [ ] Create `modules/ecr/org-registry/tests-localstack/` directory.
- [ ] Create `tests-localstack/apply_localstack.tftest.hcl`:
  - Provider block with comprehensive `endpoints` map (`ecr`, `iam`,
    `kms`, `sts`, `organizations` if covered) following the
    pull-through-cache module's working config.
  - `variables` block: `name_prefix = "tftest-ocr"`,
    `organizations_org_id = "o-tftest1234"` (skip the
    `aws_organizations_organization` data source — LocalStack Pro
    support is unknown / out of scope per Q3).
  - **Active run:** `run "plan_smoke"` with `command = plan`,
    asserting:
    - 1 KMS key + 1 alias (module-managed default).
    - 1 ECR-template IAM role.
    - 2 creation templates.
    - 1 publisher policy.
  - **Commented run:** `run "apply_default"` with `command = apply`
    and the full apply-time assertions (KMS key ARN populated, both
    template IDs populated, role + policy ARNs populated). Preserve
    as commented-out HCL so future LocalStack releases enable it by
    uncomment-only.
- [ ] Create `tests-localstack/FINDINGS.md` capturing:
  - **Finding #1 (inherited from IMPL-0005 Phase 9):** LocalStack
    Pro 2026.5.0 returns 501 for
    `CreateRepositoryCreationTemplate`. Both this module's templates
    hit the same API. Cross-reference
    `modules/ecr/pull-through-cache/tests-localstack/FINDINGS.md`
    rather than duplicate the evidence.
  - **Finding #2 (to investigate):** Does LocalStack Pro 2026.5.0
    serve `data.aws_organizations_organization`? Document outcome.
    If yes, the test could drop the `organizations_org_id` var and
    let the data source resolve. If no (likely — Organizations is
    typically AWS-account-level admin surface, not LocalStack-modeled),
    file as sneakystack backlog and document the workaround (BYO org
    ID).
  - **Out-of-scope of LocalStack (libtftest/sneakystack backlog):**
    `helm push` through the create-on-push path; auto-vivification
    of `helm-charts/*` repos; lifecycle-policy enforcement on
    auto-created repos; cross-account pull validation.
- [ ] Verify `just tf test-localstack ecr/org-registry` works
      module-agnostically.

#### Success Criteria

- `just tf test-localstack ecr/org-registry` exits 0 with the
  `plan_smoke` run green.
- `FINDINGS.md` captures the inherited 501 plus the Organizations data
  source resolution outcome.
- The commented `apply_default` run preserves the full apply-time
  assertion set for re-enable.
- The suite stays opt-in — plain `terraform test` does not load it.

---

### Phase 10: README, USAGE, prereq docs, final audits

Polish the consumer-facing surface. README explains prereqs
(Organizations access; provider version; existing-repo limitation),
the post-apply smoke recipe, and how CI / IRSA roles attach
`publisher_policy_arn`.

#### Tasks

- [ ] Update `modules/ecr/org-registry/README.md`:
  - Short pointer to USAGE.md.
  - Overview + RFC-0002 / ADR-0016 / DESIGN-0006 cross-references.
  - **Prerequisite: Organizations access.** The module's
    `data.aws_organizations_organization.this` requires
    `organizations:DescribeOrganization`, which is only available
    from the Organizations management account or a delegated admin.
    Callers without this permission MUST pass
    `var.organizations_org_id`.
  - Post-apply smoke recipe — the `helm registry login` + `helm push`
    + `aws ecr describe-repositories` recipe from DESIGN-0006 §Testing
    Strategy.
  - Consumer integration: how a CI / IRSA role attaches
    `publisher_policy_arn` (cross-account: attach as a customer-
    managed policy; same-account: use `aws_iam_role_policy_attachment`
    referencing the output ARN).
  - **Operational gotchas** (mirrors ADR-0016 §Consequences):
    - Template edits don't backfill existing repos. Provide the
      bulk-`put-lifecycle-policy` script as a copy-paste snippet
      (DESIGN-0006 §Cleanup notes).
    - `ecr:CreateRepository` is the critical permission for
      publishers; absence yields confusing first-push errors.
    - The module's KMS key has a 30-day deletion window; destroying
      the module schedules deletion of all OCI artifact repos'
      encryption key. Operators should empty + delete repos BEFORE
      destroying the module to avoid the schedule.
- [ ] Regenerate `USAGE.md` via `terraform-docs .`.
- [ ] Final pass: confirm zero `kubernetes` / `kubectl` / `helm`
      provider references
      ([ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md)).
- [ ] Final pass: confirm zero aliasing locals that re-export remote
      state ([ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md)
      / CLAUDE.md). This module reads no remote state; only data
      sources are `aws_caller_identity` and the gated
      `aws_organizations_organization`.
- [ ] Verify `just tf all ecr/org-registry` passes.
- [ ] Update CLAUDE.md to add the "Org-wide ECR OCI Artifact Registry
      module shape" section under `modules/ecr/` describing inputs,
      data sources, resources, outputs, and the two test suites
      (mirrors the pull-through-cache section format).

#### Success Criteria

- `just tf all ecr/org-registry` passes (validate + lint + fmt +
  test).
- USAGE.md committed and reflects the final input/output contract.
- README documents the three prerequisite tripwires (Organizations
  access, missing `ecr:CreateRepository` on publishers, KMS key
  destruction lifecycle).
- No provider drift vs the cluster module's pinned `~> 6.2` and
  Terraform `>= 1.1`.
- CLAUDE.md has a new section parallel to the pull-through-cache
  module's; "Repository purpose" updated to reflect IMPL-0006
  completion.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/ecr/org-registry/versions.tf` | Create | `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`. |
| `modules/ecr/org-registry/variables.tf` | Create | Input surface with four validation blocks (retention >=1, prefix shape, org-ID format). |
| `modules/ecr/org-registry/locals.tf` | Create | Name composition + `local.kms_key_arn` + `local.org_id` derivations. |
| `modules/ecr/org-registry/main.tf` | Create | `data.aws_caller_identity.current` + gated `data.aws_organizations_organization.this`. |
| `modules/ecr/org-registry/kms.tf` | Create | Gated `aws_kms_key.ecr_oci[0]` + alias (module-managed when `var.kms_key_arn == null`). |
| `modules/ecr/org-registry/iam.tf` | Create | `aws_iam_role.ecr_template` + assume-role + role-policy. |
| `modules/ecr/org-registry/templates.tf` | Create | Shared `org_pull` policy doc + `helm_charts` and `tf_modules` creation templates. |
| `modules/ecr/org-registry/publisher.tf` | Create | `aws_iam_policy.oci_publisher` + policy doc with three statements. |
| `modules/ecr/org-registry/outputs.tf` | Create | Five outputs per DESIGN-0006 §API. |
| `modules/ecr/org-registry/README.md` | Create | Prereqs, post-apply smoke, consumer integration, operational gotchas. |
| `modules/ecr/org-registry/USAGE.md` | Create | Generated by terraform-docs. |
| `modules/ecr/org-registry/.terraform-docs.yml` | Create | Copied verbatim from pull-through-cache module. |
| `modules/ecr/org-registry/.tflint.hcl` | Create | Copied verbatim from pull-through-cache module. |
| `modules/ecr/org-registry/tests/default.tftest.hcl` | Create | Module-managed-KMS resource-count assertions. |
| `modules/ecr/org-registry/tests/byo_kms.tftest.hcl` | Create | BYO KMS shape — zero module-managed KMS resources. |
| `modules/ecr/org-registry/tests/lifecycle_json.tftest.hcl` | Create | `pre_release_retention_days` + `untagged_retention_days` embed in lifecycle JSON. |
| `modules/ecr/org-registry/tests/repository_policy_json.tftest.hcl` | Create | `aws:PrincipalOrgID` + org ID in both templates' repository policy. |
| `modules/ecr/org-registry/tests/publisher_policy_scope.tftest.hcl` | Create | Publisher policy scoped to both managed prefixes. |
| `modules/ecr/org-registry/tests/prefix_override.tftest.hcl` | Create | Custom prefixes flow into template + publisher policy. |
| `modules/ecr/org-registry/tests/validation.tftest.hcl` | Create | `expect_failures` on retention=0, prefix=ROOT, malformed org ID. |
| `modules/ecr/org-registry/tests/org_id_override.tftest.hcl` | Create | BYO org ID skips data source. |
| `modules/ecr/org-registry/tests-localstack/apply_localstack.tftest.hcl` | Create | Opt-in plan_smoke + commented full apply (inherited 501). |
| `modules/ecr/org-registry/tests-localstack/FINDINGS.md` | Create | Inherits IMPL-0005 Finding #1; documents Organizations data source outcome. |
| `CLAUDE.md` | Modify | Add Org-wide ECR module shape section; update repository-purpose. |

## Testing Plan

Driven by [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md):

- **Plan-only (`tests/`)** — eight `.tftest.hcl` suites covering
  resource counts under both KMS shapes (module-managed and BYO),
  three validation negatives, lifecycle JSON content, repository-
  policy JSON content (including the `aws:PrincipalOrgID` condition),
  publisher-policy scope, prefix overrides, and the BYO-org-ID path.
  Runtime ≤ 8s. Runs in CI on every PR.
- **Apply-against-LocalStack (`tests-localstack/`)** — one suite
  exercising the same plan-time invariants against LocalStack
  endpoints (the active `plan_smoke` run). Full apply preserved as
  commented HCL pending LocalStack support for
  `CreateRepositoryCreationTemplate` (inherited 501 from IMPL-0005).
  Findings captured in `FINDINGS.md`.
- **Post-apply smoke (operator)** — `helm push` + `aws ecr
  describe-repositories` recipe documented in README; exercised on a
  real account during initial rollout. Not automated; not part of CI.

## Dependencies

- **No blocking dependencies on other module implementations.** This
  module is fleet-shared and singleton per artifact-hosting account.
  Sibling to `modules/ecr/pull-through-cache/`; the two consume ECR
  but for distinct purposes and do not share state, IAM, or KMS keys.
- **RFC-0002 / ADR-0016 / DESIGN-0006** are the source-of-truth for
  the module's shape and policy choices.
- **No downstream Terraform consumers in this repo.** Consumers are
  CI / IRSA roles in workload accounts; they attach the emitted
  `publisher_policy_arn` via their own Terraform / Terragrunt config
  (cross-account: copy the policy as a customer-managed policy in
  the consumer account, since IAM policies don't cross account
  boundaries by reference).

## Open Questions

These are surfaced for review before implementation begins. Each
should resolve to a one-line answer that lands in the relevant Phase's
Tasks section.

### Q1 — `name_prefix` semantics: prefix every resource name, or hardcode singletons?

DESIGN-0006 §API says `name_prefix` "drives names of the KMS alias,
IAM role, and IAM policy." But the reference Terraform in DESIGN-0006
hardcodes those names (`alias/ecr-oci-artifacts`,
`ecr-repository-creation-template`, `ecr-oci-publisher`) — they're
singletons per artifact-hosting account, so prefixing isn't strictly
required.

**Options:**

1. **(a) Hardcode** the three names; drop `var.name_prefix` from the
   variable surface. Pro: simpler; matches DESIGN-0006's reference
   Terraform exactly. Con: divergence from the
   pull-through-cache module's `var.name_prefix` convention.
2. **(b) Prefix every name** with `var.name_prefix` (e.g.,
   `alias/${name_prefix}-ecr-oci`,
   `${name_prefix}-ecr-template`,
   `${name_prefix}-oci-publisher`). Pro: fleet consistency with
   pull-through-cache; enables multiple instances per account if
   ever needed (unlikely but cheap). Con: the design's reference
   Terraform's names become un-clean.
3. **(c) Per-resource name overrides** (`var.kms_alias_name`,
   `var.template_role_name`, `var.publisher_policy_name`) with no
   `var.name_prefix`. Maximum flexibility; most surface.

**Tentative recommendation:** (b). The Phase 1/2/4/6 tasks above
already assume (b); flip to (a) by removing `var.name_prefix` and
hardcoding the names if you prefer.

**Action needed:** confirm (b), or pick (a) / (c).

### Q2 — `data.aws_organizations_organization` permission scope

The reference Terraform's `data "aws_organizations_organization" "this" {}`
requires `organizations:DescribeOrganization`, which is only
available from:

- the AWS Organizations **management account**, or
- a **delegated administrator** for the relevant service (Organizations
  itself, or sometimes a per-service delegation).

If the artifact-hosting account is a **workload account** (not the
management account and not a delegated admin), the data source fails
at plan time with `AccessDeniedException`.

**Options:**

1. **(a) Always use the data source.** Assumes admin permissions
   present. Hard fail if not — clear error message but no graceful
   fallback.
2. **(b) Module-managed by default, var override** (the current Phase
   1 plan). `var.organizations_org_id == null` → data source;
   non-null → use the var. Best of both worlds; the test suite uses
   the var path to avoid permissions concerns.
3. **(c) Always require the var.** No data source. Simpler module
   code; pushes the responsibility (and the var value) into the
   caller's Terragrunt config.

**Tentative recommendation:** (b). Implemented in the Phase 1/2/8
tasks. If artifact-hosting is **always** in an org-admin position,
(a) is simpler; if **always** a workload account, (c) avoids the
gated data source entirely.

**Action needed:** confirm (b), or pick (a) / (c). Also: **which AWS
account will host this module?** Management account, delegated admin,
or workload account?

### Q3 — LocalStack Pro fidelity for `data.aws_organizations_organization`

Even if the production-side answer to Q2 is (b) or (a), the
`tests-localstack/` suite needs the data source to resolve against
LocalStack. Unknown whether LocalStack Pro 2026.5.0 models
`organizations:DescribeOrganization`. The Phase 9 plan uses the BYO
org-ID path (`var.organizations_org_id = "o-tftest1234"`) to
side-step this question, then files the LocalStack support outcome
in FINDINGS.md.

**Tentative resolution:** confirmed during Phase 9 implementation;
documented in FINDINGS.md. No action needed pre-implementation.

### Q4 — Existing-repo migration tooling

If the artifact-hosting account already has `helm-charts/*` or
`tf-modules/*` repos pre-dating this module, the creation templates
will **not** backfill them (ECR property — templates only apply at
creation time). Those repos retain whatever encryption / mutability /
lifecycle / repository-policy they were created with.

**Options:**

1. **(a) Module-emitted Terraform `import` blocks** for any
   pre-existing repos under the managed prefixes. The caller passes
   a list of repo names; the module imports them and re-applies
   template-equivalent config explicitly per repo.
2. **(b) Documented bulk script** (the
   `aws ecr describe-repositories | aws ecr put-lifecycle-policy`
   loop from DESIGN-0006 §Cleanup notes). One-shot operator workflow,
   no module surface.
3. **(c) Out of scope.** Manual handoff. If the artifact-hosting
   account is brand-new, this is the cheapest option.

**Tentative recommendation:** (b). Documented in Phase 10 README; no
module surface added. If the artifact-hosting account is being
green-fielded for this work (no pre-existing OCI repos), even (c) is
fine.

**Action needed:** confirm (b) — or tell me there are existing OCI
repos that need a migration story.

### Q5 — `var.tags` shape: typed object or simple `map(string)`?

Fleet inconsistency:

- `modules/eks/cluster/`, `modules/eks/addons/`,
  `modules/eks/managed-node-group/`, `modules/eks/pod-identity-access/`
  use a **typed object** (`{ Account, ClusterName, ClusterType,
  Environment, Region }`) that mirrors the Boilerplate-generated
  Terragrunt config.
- `modules/ecr/pull-through-cache/` uses simple `map(string)` (it's
  account-scoped, not cluster-scoped — no `ClusterName` to slot in).

This module is also account-scoped (not cluster-scoped).

**Tentative recommendation:** `map(string)` — matches the
pull-through-cache module's pattern (the closest sibling). Phase 1
tasks assume `map(string)`.

**Action needed:** confirm `map(string)`, or specify a typed object
shape if Terragrunt-side tagging conventions require it.

### Q6 — `IMMUTABLE_WITH_EXCLUSION` provider version guard

DESIGN-0006 §Tag mutability calls out: "Requires AWS Terraform
provider >= 6.8.0. If pinned older, fall back to plain `IMMUTABLE`
and forbid floating tags via CI lint."

**Verified:** the fleet pin `~> 6.2` allows `>= 6.2.0, < 7.0.0`. The
currently-installed provider is `v6.45.0`. `IMMUTABLE_WITH_EXCLUSION`
is supported. **No fallback needed.**

**No action needed.** Documented here for traceability — flag in a
PR comment if the fleet pin ever tightens to `~> 6.2.0` (patch-only)
or if we add a CI step that resolves the minimum-compatible provider.

### Q7 — Output via SSM Parameter Store?

DESIGN-0006 §API mentions in passing: "emit it as a Terraform
`output` (or reference via SSM Parameter Store) so downstream CI /
IRSA roles can attach it without copy-pasting policy JSON."

The Phase 7 plan emits Terraform outputs only. An SSM Parameter
Store wrapper (a parameter holding the publisher policy ARN under a
well-known name like `/platform/ecr-oci-publisher-policy-arn`) would
help cross-account consumers that can't reference the
artifact-hosting account's Terraform outputs directly.

**Tentative recommendation:** out of scope for v1. Add as a follow-up
module / addition if cross-account consumer ergonomics become a real
problem.

**Action needed:** confirm out-of-scope, or expand v1 to include SSM
Parameter Store outputs.

### Q8 — Module-managed KMS key destruction safety

If operators destroy the module while OCI artifact repos exist under
the managed prefixes, the module-managed KMS key gets scheduled for
deletion (`deletion_window_in_days = 30`). When the key actually
deletes 30 days later, **all template-encrypted repos become
unreadable** — affects every chart and module in the org.

**Mitigations to consider:**

1. Add a `prevent_destroy` lifecycle block on `aws_kms_key.ecr_oci`?
   (Caller-level Terraform-state breakage if they really do want to
   destroy.)
2. Document the destruction order: empty + delete all repos under
   `helm-charts/*` + `tf-modules/*` BEFORE running
   `terraform destroy`. Phase 10 README plan already includes this.
3. Add a key policy statement denying `kms:ScheduleKeyDeletion`
   except from a break-glass principal? (Heavier; production-grade.)

**Tentative recommendation:** (2) only (documentation). Defer the
heavier mitigations to a future iteration if real operational pain
shows up.

**Action needed:** confirm doc-only mitigation, or escalate to
`prevent_destroy` / key-policy guard for v1.

## References

- [DESIGN-0006](../design/0006-org-wide-ecr-oci-artifact-registry.md) — Org-wide ECR OCI Artifact Registry (this implementation's source of truth).
- [RFC-0002](../rfc/0002-ecr-layout-for-internal-oci-artifacts.md) — ECR Layout for Internal OCI Artifacts.
- [ADR-0016](../adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md) — Use ECR Repository Creation Templates for OCI Artifact Repos.
- [DESIGN-0005](../design/0005-ecr-pull-through-cache-module.md) / [IMPL-0005](0005-ecr-pull-through-cache-module-implementation.md) — Sibling EKS-facing pull-through cache module; shares the `aws_ecr_repository_creation_template` provider gotchas (Q3 schema verification, LocalStack 501).
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module Testing Strategy (drives the `tests/` + `tests-localstack/` split in Phases 8 + 9).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state` (this module reads no remote state — fleet-shared).
- [ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md) — Terraform manages AWS API resources only (this module is pure AWS API).
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants (Phase 8).
- [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md) — libtftest for apply-time runtime validation (informs Phase 9 framing).
- [Amazon ECR repository creation templates](https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-creation-templates.html)
- [Pushing a Helm chart to an Amazon ECR private repository](https://docs.aws.amazon.com/AmazonECR/latest/userguide/push-oci-artifact.html)
