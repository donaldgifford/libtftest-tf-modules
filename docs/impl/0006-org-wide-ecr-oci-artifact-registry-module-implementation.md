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
  - [Phase 7: SSM Parameter Store publication (opt-in)](#phase-7-ssm-parameter-store-publication-opt-in)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
  - [Phase 8: Outputs](#phase-8-outputs)
    - [Tasks](#tasks-7)
    - [Success Criteria](#success-criteria-7)
  - [Phase 9: terraform test plan-only suite (tests/)](#phase-9-terraform-test-plan-only-suite-tests)
    - [Tasks](#tasks-8)
    - [Success Criteria](#success-criteria-8)
  - [Phase 10: terraform test apply-against-LocalStack suite (tests-localstack/)](#phase-10-terraform-test-apply-against-localstack-suite-tests-localstack)
    - [Tasks](#tasks-9)
    - [Success Criteria](#success-criteria-9)
  - [Phase 11: README, USAGE, prereq docs, final audits](#phase-11-readme-usage-prereq-docs-final-audits)
    - [Tasks](#tasks-10)
    - [Success Criteria](#success-criteria-10)
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
- Required `var.organizations_org_id` (`o-...` literal) per Q2 (a) —
  no Organizations data source; the org ID flows in as an explicit
  input and is referenced at the use site per ADR-0001.
- Opt-in SSM Parameter Store publication (`var.publish_to_ssm`)
  emitting the publisher policy ARN (for same-account consumers) and
  the full policy JSON (for cross-account consumers). Cross-account
  mode (`var.ssm_cross_account_org_id` non-null) switches the
  parameters to Advanced tier and attaches a resource-based policy
  scoped to the supplied org ID per Q7.
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
- Per-consumer wrapper modules — consumer accounts attach the
  emitted `publisher_policy_arn` (same-account) or recreate the
  policy from the JSON SSM parameter (cross-account) in their own
  Terraform / Terragrunt config; no per-consumer wrapper is emitted
  by this module.
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

- [x] Create `modules/ecr/org-registry/` directory.
- [x] Copy scaffolding files verbatim from
      `modules/ecr/pull-through-cache/`: `.terraform-docs.yml`,
      `.tflint.hcl`, `README.md` stub, `USAGE.md` skeleton.
- [x] Create `versions.tf` pinning `hashicorp/aws ~> 6.2`, Terraform
      `>= 1.1` (matches the fleet pin; resolves to >= 6.8.0 in practice,
      which is the minimum for `IMMUTABLE_WITH_EXCLUSION`).
- [x] Create `variables.tf` with the input surface from DESIGN-0006:
  - Required: `name_prefix` (`string`).
  - Required: `organizations_org_id` (`string`) — the AWS Organizations
    ID (`o-...` format) used in the `aws:PrincipalOrgID` condition on
    the org-wide pull policy. Per Q2 (a) resolution: caller-supplied
    only; no data source.
  - Optional:
    - `kms_key_arn` (`string`, default `null`) — caller-supplied KMS
      key ARN. Null routes to module-managed key.
    - `helm_charts_prefix` (`string`, default `"helm-charts"`).
    - `tf_modules_prefix` (`string`, default `"tf-modules"`).
    - `pre_release_retention_days` (`number`, default `90`).
    - `untagged_retention_days` (`number`, default `7`).
    - `publish_to_ssm` (`bool`, default `false`) — when true, emit
      two SSM Parameter Store entries (the publisher policy ARN and
      the publisher policy JSON) for consumer discovery. Q7
      resolution.
    - `ssm_parameter_path_arn` (`string`, default
      `"/platform/${var.name_prefix}-ecr-oci-publisher-policy-arn"`)
      — SSM path for the ARN parameter.
    - `ssm_parameter_path_json` (`string`, default
      `"/platform/${var.name_prefix}-ecr-oci-publisher-policy-json"`)
      — SSM path for the policy-JSON parameter.
    - `ssm_cross_account_org_id` (`string`, default `null`) — when
      non-null, switch the SSM parameters to Advanced tier and
      attach a resource-based policy granting
      `ssm:GetParameter` / `ssm:GetParameters` to
      `aws:PrincipalOrgID = var.ssm_cross_account_org_id` so
      cross-account publisher CI roles can read the JSON and recreate
      the policy locally. Default null = same-account-only mode (no
      cross-account access on the params).
    - `tags` (`map(string)`, default `{}`).
- [x] Add `validation` block on `pre_release_retention_days`:
      `pre_release_retention_days >= 1` (ECR rejects 0).
- [x] Add `validation` block on `untagged_retention_days`:
      `untagged_retention_days >= 1`.
- [x] Add `validation` block on each of `helm_charts_prefix` /
      `tf_modules_prefix`: match the AWS provider v6 schema rule for
      `aws_ecr_repository_creation_template.prefix` —
      `length(value) >= 2 && length(value) <= 256 &&
      can(regex("^[a-zA-Z0-9_./-]+$", value))`. Reject the literal
      `"ROOT"` (we're using prefix-scoped templates, not the catch-all).
- [x] Add `validation` block on `organizations_org_id`: must match
      `^o-[a-z0-9]{10,32}$` (AWS Organizations ID format). Required
      input — no null fallback.
- [x] Add `validation` block on `ssm_cross_account_org_id`: when
      non-null, same format check as `organizations_org_id`.
- [x] Add `validation` block on `ssm_parameter_path_arn` and
      `ssm_parameter_path_json`: must start with `/` (SSM parameter
      paths require leading slash).
- [x] Create empty `main.tf`, `kms.tf`, `iam.tf`, `templates.tf`,
      `publisher.tf`, `ssm.tf`, `locals.tf`, `outputs.tf` files.
- [x] Run `terraform init && terraform validate`.
- [x] Run `tflint --init && tflint` (unused-var/provider warnings
      expected at this scaffolding stage; resolved naturally as
      Phases 2-7 wire each variable into a resource).

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
- Plan with `organizations_org_id` unset (or `null`) fails at plan
  with a "required input" error (Q2 (a): required string, no
  default).
- `ssm_parameter_path_arn = "no-leading-slash"` fails at plan with
  the SSM path-format error.

---

### Phase 2: Data source and locals

Per Q2 (a) resolution: only one data source — `aws_caller_identity`.
The org ID comes from `var.organizations_org_id` (required input);
no `aws_organizations_organization` data source, no remote state.
Locals handle KMS-key resolution and the deterministic resource-name
composition.

#### Tasks

- [x] In `main.tf`, add `data "aws_caller_identity" "current" {}`
      ([ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md)
      identity-class carve-out — same shape as
      `modules/ecr/pull-through-cache/`).
- [x] In `locals.tf`, derive `local.account_id =
      data.aws_caller_identity.current.account_id` (used to scope IAM
      ARNs to this account's ECR repositories).
- [x] In `locals.tf`, derive
      `local.kms_key_arn = coalesce(var.kms_key_arn,
      try(aws_kms_key.ecr_oci[0].arn, null))`. Meaningful conditional
      work — both templates and the ECR-template IAM role reference
      this single value (no aliasing local; consumed at the use site).
- [x] In `locals.tf`, compose the deterministic resource-name locals:
      `kms_alias_name = "alias/${var.name_prefix}-ecr-oci"`,
      `template_role_name = "${var.name_prefix}-ecr-template"`,
      `publisher_policy_name = "${var.name_prefix}-oci-publisher"`.
- [x] **Do NOT** alias `var.organizations_org_id` into a local. Per
      [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md)
      and CLAUDE.md ("reference at the use site, not via aliasing
      locals"), `var.organizations_org_id` is referenced directly at
      its single use site in Phase 5's `org_pull` policy document.
- [x] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- The only data source in the module is
  `data.aws_caller_identity.current`. (`grep -r "^data " *.tf`
  returns one match.)
- No aliasing locals that re-export remote state or var values
  (ADR-0001 / CLAUDE.md). `local.kms_key_arn` is the only
  variable-aware local and it does meaningful compositional work.

---

### Phase 3: KMS key (gated bring-your-own)

Provision the module-managed KMS key + alias when
`var.kms_key_arn == null`. Both the templates' encryption and the ECR-
assumed IAM role's KMS permissions resolve through `local.kms_key_arn`
so the same code path works for both bring-your-own and module-managed.

#### Tasks

- [x] In `kms.tf`, add `aws_kms_key.ecr_oci` count-gated on
      `var.kms_key_arn == null`:
  - `description = "ECR encryption key for OCI artifact repos (${var.helm_charts_prefix}/*, ${var.tf_modules_prefix}/*)"`.
  - `enable_key_rotation = true`.
  - `deletion_window_in_days = 30`.
  - `tags = var.tags`.
  - `lifecycle { prevent_destroy = true }` — guard per Q8. Stops
    `terraform destroy` / `terraform apply` from scheduling key
    deletion while OCI repos may still depend on it. Operators
    unblock destruction by removing the `lifecycle` block in a
    deliberate PR (see Phase 11 README's destruction procedure).
- [x] In `kms.tf`, add `aws_kms_alias.ecr_oci` count-gated identically:
  - `name = local.kms_alias_name`.
  - `target_key_id = aws_kms_key.ecr_oci[0].key_id`.
- [x] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- With default (`kms_key_arn = null`), plan contains exactly one
  `aws_kms_key.ecr_oci` and one `aws_kms_alias.ecr_oci`.
- The module-managed `aws_kms_key.ecr_oci[0]` has a
  `lifecycle { prevent_destroy = true }` block (visible in the plan
  output / Terraform source — the block itself isn't surfaced via
  attributes; verified by code-review checkbox at Phase 11 final
  audit).
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
    "aws:PrincipalOrgID"; values = [var.organizations_org_id] }`.
    Per Q2 (a): reference `var.organizations_org_id` directly here
    (the only use site); no aliasing local.
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

### Phase 7: SSM Parameter Store publication (opt-in)

Per Q7 resolution: the module optionally publishes the publisher
policy in two shapes — the ARN (for same-account consumers) and the
full JSON (for cross-account consumers). Both are gated on
`var.publish_to_ssm` (default `false` — opt-in). Cross-account
distribution is controlled by `var.ssm_cross_account_org_id`:
when non-null, both SSM parameters use the `Advanced` tier and an
attached resource-based policy grants `ssm:GetParameter` to
`aws:PrincipalOrgID`, mirroring the trust model on the ECR
templates' org-wide pull policy.

#### Tasks

- [ ] In `ssm.tf`, add `aws_ssm_parameter.publisher_policy_arn`:
  - `count = var.publish_to_ssm ? 1 : 0`.
  - `name = var.ssm_parameter_path_arn`
    (default `/platform/ecr-oci-publisher-policy-arn`).
  - `type = "String"`.
  - `value = aws_iam_policy.oci_publisher.arn`.
  - `tier = var.ssm_cross_account_org_id == null ? "Standard" : "Advanced"`
    (Advanced is required to attach a resource-based policy).
  - `description = "ARN of the org-wide ECR OCI publisher IAM policy. Attach to CI / IRSA roles in the artifact-hosting account."`.
  - `tags = var.tags`.
- [ ] In `ssm.tf`, add `aws_ssm_parameter.publisher_policy_json`:
  - Same `count` gate.
  - `name = var.ssm_parameter_path_json`
    (default `/platform/ecr-oci-publisher-policy-json`).
  - `type = "String"`.
  - `value = data.aws_iam_policy_document.oci_publisher.json`
    (re-emits the full policy JSON for cross-account consumers to
    recreate locally — IAM policies don't cross account boundaries
    by reference).
  - `tier` same expression as the ARN parameter.
  - `description = "Full JSON of the org-wide ECR OCI publisher IAM policy. Cross-account consumers read this and recreate the policy in their own accounts."`.
  - `tags = var.tags`.
- [ ] **Cross-account resource-based policies on the parameters.**
      When `var.ssm_cross_account_org_id != null`, grant org-wide
      `ssm:GetParameter` on both parameters. **Provider schema
      caveat (per IMPL-0005 Q3 pattern):** verify at implementation
      time whether `hashicorp/aws ~> 6.2` exposes a dedicated
      resource for SSM parameter resource-based policies (e.g.,
      `aws_ssm_resource_data_sync` is NOT it; the candidate is
      `aws_ssm_resource_policy` if/when it exists, or an inline
      `policy` attribute on `aws_ssm_parameter`). If neither exists
      in v6, document the gap in README under "Cross-account
      consumer wiring" and emit the policy JSON as an additional
      output for operators to attach via AWS CLI
      (`aws ssm put-resource-policy`). Mirror the IMPL-0005
      `prefix = "*"` → `prefix = "ROOT"` divergence pattern:
      schema-driven adjustment, documented inline.
- [ ] Add `data.aws_iam_policy_document.ssm_org_read[0]`
      (count-gated on `var.ssm_cross_account_org_id != null`) with
      one statement:
  - `actions = ["ssm:GetParameter", "ssm:GetParameters"]`.
  - `resources = [aws_ssm_parameter.publisher_policy_arn[0].arn,
    aws_ssm_parameter.publisher_policy_json[0].arn]`.
  - `principals { type = "*"; identifiers = ["*"] }` constrained
    by `condition { test = "StringEquals"; variable =
    "aws:PrincipalOrgID"; values = [var.ssm_cross_account_org_id] }`.
- [ ] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- With `var.publish_to_ssm = false` (default), plan contains zero
  `aws_ssm_parameter` resources and zero
  `data.aws_iam_policy_document.ssm_org_read` reads.
- With `var.publish_to_ssm = true` and
  `var.ssm_cross_account_org_id = null` (same-account default),
  plan contains exactly two `aws_ssm_parameter` resources, both
  `tier = "Standard"`, and no resource-based policy.
- With `var.publish_to_ssm = true` and
  `var.ssm_cross_account_org_id = "o-..."`, plan contains two
  `aws_ssm_parameter` resources at `tier = "Advanced"` and the
  resource-based policy JSON contains the supplied org ID under
  `aws:PrincipalOrgID`.
- The ARN parameter's `value` resolves to
  `aws_iam_policy.oci_publisher.arn`; the JSON parameter's `value`
  resolves to `data.aws_iam_policy_document.oci_publisher.json`.

---

### Phase 8: Outputs

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
  - `publisher_policy_ssm_arn_parameter_name` — the SSM path the ARN
    landed at (or `null` when `var.publish_to_ssm = false`).
    Resolves to
    `try(aws_ssm_parameter.publisher_policy_arn[0].name, null)`.
  - `publisher_policy_ssm_json_parameter_name` — same for the JSON
    parameter.
- [ ] Add clear `description` strings on each output explaining the
      consumer use case (e.g., "attach this to CI / IRSA roles";
      "cross-account consumers read this SSM parameter to recreate
      the publisher policy in their own account").
- [ ] Regenerate `USAGE.md` via `terraform-docs .`.
- [ ] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- `terraform-docs .` regenerates `USAGE.md` listing all seven outputs
  in the rendered table.
- Plan shows non-null values for the five always-on outputs.
- `publisher_policy_ssm_*_parameter_name` outputs are `null` when
  `var.publish_to_ssm = false` and non-null strings when `true`.

---

### Phase 9: terraform test plan-only suite (`tests/`)

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
    `name_prefix = "platform"`,
    `organizations_org_id = "o-test1234ab"`, all other defaults.
    `override_data` for `data.aws_caller_identity.current`
    (account_id `000000000000`). No org-data-source override needed
    (Q2 (a) resolution — `var.organizations_org_id` is a required
    input, not a data-source read).
    Assertions:
    - 1 `aws_kms_key.ecr_oci`.
    - 1 `aws_kms_alias.ecr_oci`.
    - 1 `aws_iam_role.ecr_template`.
    - 1 `aws_iam_role_policy.ecr_template`.
    - 2 `aws_ecr_repository_creation_template` resources (helm_charts
      + tf_modules).
    - 1 `aws_iam_policy.oci_publisher`.
    - 0 `aws_ssm_parameter` resources (`publish_to_ssm` defaults
      `false`).
- [ ] Create `tests/byo_kms.tftest.hcl`:
  - `run "plan_byo_kms"`:
    `kms_key_arn = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"`,
    `organizations_org_id = "o-test1234ab"`.
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
    `untagged_retention_days = 7`,
    `organizations_org_id = "o-test1234ab"`.
    Assertions: both templates' encoded `lifecycle_policy` contain
    `"countNumber":90` AND `"countNumber":7`. Mirrors the assertion
    shape in
    `modules/ecr/pull-through-cache/tests/lifecycle_json.tftest.hcl`.
  - `run "custom_retention"`: `pre_release_retention_days = 30`,
    `untagged_retention_days = 14`. Assertions: both templates'
    encoded JSON contains `"countNumber":30` and `"countNumber":14`.
- [ ] Create `tests/repository_policy_json.tftest.hcl`:
  - `run "plan_org_pull"`:
    `organizations_org_id = "o-test1234ab"`.
    Assertion that the helm_charts template's `repository_policy`
    contains both `"aws:PrincipalOrgID"` and the supplied org ID.
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
    `tf_modules_prefix = "internal-modules"`,
    `organizations_org_id = "o-test1234ab"`.
    Assertions: each template's `prefix` attribute equals the custom
    value; the publisher policy's JSON contains
    `repository/internal-charts/*` and `repository/internal-modules/*`.
- [ ] Create `tests/ssm.tftest.hcl`:
  - `run "ssm_off_default"`:
    `organizations_org_id = "o-test1234ab"` (omit
    `publish_to_ssm` — default `false`). Assertions: 0
    `aws_ssm_parameter` resources; 0
    `data.aws_iam_policy_document.ssm_org_read` reads.
  - `run "ssm_on_same_account"`:
    `publish_to_ssm = true`, no `ssm_cross_account_org_id`.
    Assertions: 2 `aws_ssm_parameter` resources, both
    `tier = "Standard"`; 0
    `data.aws_iam_policy_document.ssm_org_read` reads (no
    cross-account policy emitted); ARN parameter's `value`
    references `aws_iam_policy.oci_publisher.arn`; JSON parameter's
    `value` references
    `data.aws_iam_policy_document.oci_publisher.json`.
  - `run "ssm_on_cross_account"`:
    `publish_to_ssm = true`,
    `ssm_cross_account_org_id = "o-crossacct12"`. Assertions: 2
    `aws_ssm_parameter` resources, both `tier = "Advanced"`; 1
    `data.aws_iam_policy_document.ssm_org_read`; resource-based
    policy JSON contains `"o-crossacct12"` under
    `aws:PrincipalOrgID`.
- [ ] Create `tests/validation.tftest.hcl`:
  - `run "negative_pre_release_zero"`:
    `pre_release_retention_days = 0`,
    `organizations_org_id = "o-test1234ab"`.
    `expect_failures = [var.pre_release_retention_days]`.
  - `run "negative_helm_prefix_root"`:
    `helm_charts_prefix = "ROOT"`,
    `organizations_org_id = "o-test1234ab"`.
    `expect_failures = [var.helm_charts_prefix]`.
  - `run "negative_bad_org_id"`:
    `organizations_org_id = "bogus"`.
    `expect_failures = [var.organizations_org_id]`.
  - `run "negative_bad_ssm_path"`:
    `publish_to_ssm = true`,
    `ssm_parameter_path_arn = "no-leading-slash"`,
    `organizations_org_id = "o-test1234ab"`.
    `expect_failures = [var.ssm_parameter_path_arn]`.
  - `run "negative_bad_cross_account_org_id"`:
    `publish_to_ssm = true`,
    `ssm_cross_account_org_id = "not-an-org-id"`,
    `organizations_org_id = "o-test1234ab"`.
    `expect_failures = [var.ssm_cross_account_org_id]`.
- [ ] Verify `just tf test ecr/org-registry` works module-agnostically.

#### Success Criteria

- All eight `.tftest.hcl` suites pass (`default`, `byo_kms`,
  `lifecycle_json`, `repository_policy_json`, `publisher_policy_scope`,
  `prefix_override`, `ssm`, `validation`).
- Total runtime ≤ 10s (plan-only, no apply, no LocalStack).
- `expect_failures` correctly catches all five validation negatives.
- BYO-KMS test confirms zero module-managed KMS resources.
- SSM test confirms the three behaviors: off → zero parameters; on
  same-account → two Standard parameters; on cross-account → two
  Advanced parameters + a resource-based policy keyed off the
  supplied cross-account org ID.

---

### Phase 10: terraform test apply-against-LocalStack suite (`tests-localstack/`)

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
- [ ] Implement **Pro-tier auto-detection** per Q3 in the
      `just tf test-localstack ecr/org-registry` invocation. The
      `tests-localstack/` suite uses `var.organizations_org_id`
      (BYO org ID) so the AWS Organizations API call is not exercised
      against LocalStack; this means the suite is **runnable against
      LocalStack Community (free-tier)** for this module. ECR's
      pull-through-cache + creation-template APIs were observed as
      501 against LocalStack Pro 2026.5.0 (IMPL-0005 Finding #1);
      they are also missing from Community. Both tiers therefore land
      at the same plan-only smoke surface for this module. Document
      this in `FINDINGS.md`.
- [ ] Create `tests-localstack/FINDINGS.md` capturing:
  - **Finding #1 (inherited from IMPL-0005 Phase 9):** LocalStack
    Pro 2026.5.0 returns 501 for
    `CreateRepositoryCreationTemplate`. Both this module's templates
    hit the same API. Cross-reference
    `modules/ecr/pull-through-cache/tests-localstack/FINDINGS.md`
    rather than duplicate the evidence. The 501 is the same on
    LocalStack Community — no tier difference for this surface.
  - **Finding #2 (Pro-tier auto-detection — fleet principle, Q3):**
    Per the user's testing guidance, `tests-localstack/` suites
    should detect LocalStack tier (Pro vs Community) at invocation
    time and skip Pro-only test cases when running against
    Community. For THIS module the question is moot — the suite
    uses `var.organizations_org_id` to side-step the
    `aws_organizations_organization` Pro-only API, and the ECR
    creation-template APIs 501 on both tiers. The fleet-wide
    Pro-detection harness lives outside this module (a `justfile`
    helper or a CI step probing `/_localstack/info`). Filed as a
    follow-up under the existing testing strategy in RFC-0001 §Phase
    3 — no per-module work here.
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

### Phase 11: README, USAGE, prereq docs, final audits

Polish the consumer-facing surface. README explains prereqs
(Organizations access; provider version; existing-repo limitation),
the post-apply smoke recipe, and how CI / IRSA roles attach
`publisher_policy_arn`.

#### Tasks

- [ ] Update `modules/ecr/org-registry/README.md`:
  - Short pointer to USAGE.md.
  - Overview + RFC-0002 / ADR-0016 / DESIGN-0006 cross-references.
  - **Prerequisite: org ID supply.** "Pass the org ID literal to
    `var.organizations_org_id` (12-char `o-...` string). Available
    in the AWS console under Organizations → Settings, or via
    `aws organizations describe-organization --query
    'Organization.Id' --output text`. The module does not read this
    from Organizations directly (Q2 (a) resolution — required input
    matches the fleet's ADR-0001 cross-stack composition posture)."
  - Post-apply smoke recipe — the `helm registry login` + `helm push`
    + `aws ecr describe-repositories` recipe from DESIGN-0006 §Testing
    Strategy.
  - Consumer integration: how a CI / IRSA role attaches
    `publisher_policy_arn`:
    - **Same-account.** Set `var.publish_to_ssm = true`. Consumer
      Terraform reads the policy ARN from
      `data.aws_ssm_parameter.publisher_policy_arn` (path =
      `publisher_policy_ssm_arn_parameter_name` output) and attaches
      it to its IAM role via `aws_iam_role_policy_attachment`.
    - **Cross-account.** Set `var.publish_to_ssm = true` AND
      `var.ssm_cross_account_org_id = "<consumer-org-id>"`. The SSM
      parameters move to Advanced tier with a resource-based policy
      granting org-wide `ssm:GetParameter`. Consumer accounts read
      the policy *JSON* from the JSON parameter and recreate the
      policy locally in their own account (IAM policies don't cross
      account boundaries by reference). The README documents the
      `data.aws_ssm_parameter` + `aws_iam_policy` snippet consumers
      paste into their own Terraform.
  - **Operational gotchas** (mirrors ADR-0016 §Consequences):
    - Template edits don't backfill existing repos (Q4: greenfield
      assumption — if pre-existing OCI repos appear later, handle
      via a one-shot operational PR outside this module; no
      module-emitted migration tooling).
    - `ecr:CreateRepository` is the critical permission for
      publishers; absence yields confusing first-push errors.
    - **KMS key destruction procedure** (per Q8). The module-managed
      key has `lifecycle.prevent_destroy = true`. Two-step unlock to
      retire the registry:
      1. Empty + delete every repo under `<helm_charts_prefix>/*`
         and `<tf_modules_prefix>/*` (the
         `aws ecr describe-repositories | aws ecr delete-repository
         --force` loop). The module's templates do NOT track or
         delete these repos — they materialize lazily and live
         independently of the module's state.
      2. Open a deliberate PR removing the `lifecycle` block on
         `aws_kms_key.ecr_oci`, then run `terraform destroy`. The
         30-day deletion window starts AFTER apply.
      Skipping step 1 leaves OCI artifact repos depending on a key
      that's scheduled for deletion — all repos under the managed
      prefixes become unreadable on day 30.
- [ ] Regenerate `USAGE.md` via `terraform-docs .`.
- [ ] Final pass: confirm zero `kubernetes` / `kubectl` / `helm`
      provider references
      ([ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md)).
- [ ] Final pass: confirm zero aliasing locals that re-export remote
      state ([ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md)
      / CLAUDE.md). This module reads no remote state; the only data
      source is `aws_caller_identity`. The org ID is a required
      input (Q2 (a) resolution) — referenced at the use site, never
      aliased.
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
| `modules/ecr/org-registry/locals.tf` | Create | Name composition + `local.kms_key_arn` derivation (org ID is referenced directly from `var.organizations_org_id` per Q2 (a) / ADR-0001). |
| `modules/ecr/org-registry/main.tf` | Create | `data.aws_caller_identity.current` only (no Organizations data source per Q2 (a)). |
| `modules/ecr/org-registry/kms.tf` | Create | Gated `aws_kms_key.ecr_oci[0]` + alias (module-managed when `var.kms_key_arn == null`). |
| `modules/ecr/org-registry/iam.tf` | Create | `aws_iam_role.ecr_template` + assume-role + role-policy. |
| `modules/ecr/org-registry/templates.tf` | Create | Shared `org_pull` policy doc + `helm_charts` and `tf_modules` creation templates. |
| `modules/ecr/org-registry/publisher.tf` | Create | `aws_iam_policy.oci_publisher` + policy doc with three statements. |
| `modules/ecr/org-registry/ssm.tf` | Create | Opt-in SSM parameter publication (ARN + JSON), cross-account resource-based policy gated on `var.ssm_cross_account_org_id`. |
| `modules/ecr/org-registry/outputs.tf` | Create | Seven outputs per DESIGN-0006 §API (five always-on plus two SSM-parameter-name outputs that resolve to `null` when SSM publication is off). |
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
| `modules/ecr/org-registry/tests/ssm.tftest.hcl` | Create | Three runs covering off (default) / on same-account (Standard tier) / on cross-account (Advanced tier + resource-based policy). |
| `modules/ecr/org-registry/tests/validation.tftest.hcl` | Create | `expect_failures` on retention=0, prefix=ROOT, malformed org ID, malformed SSM path, malformed cross-account org ID. |
| `modules/ecr/org-registry/tests-localstack/apply_localstack.tftest.hcl` | Create | Opt-in plan_smoke + commented full apply (inherited 501). |
| `modules/ecr/org-registry/tests-localstack/FINDINGS.md` | Create | Inherits IMPL-0005 Finding #1; documents Organizations data source outcome. |
| `CLAUDE.md` | Modify | Add Org-wide ECR module shape section; update repository-purpose. |

## Testing Plan

Driven by [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md):

- **Plan-only (`tests/`)** — eight `.tftest.hcl` suites covering
  resource counts under both KMS shapes (module-managed and BYO),
  five validation negatives, lifecycle JSON content, repository-
  policy JSON content (including the `aws:PrincipalOrgID` condition),
  publisher-policy scope, prefix overrides, and the SSM publication
  off / same-account / cross-account matrix. Runtime ≤ 10s. Runs in
  CI on every PR.
- **Apply-against-LocalStack (`tests-localstack/`)** — one suite
  exercising the same plan-time invariants against LocalStack
  endpoints (the active `plan_smoke` run). Full apply preserved as
  commented HCL pending LocalStack support for
  `CreateRepositoryCreationTemplate` (inherited 501 from IMPL-0005).
  Findings captured in `FINDINGS.md`.
  Suite is designed to run against either **LocalStack Community
  (free-tier)** or **LocalStack Pro** — uses `var.organizations_org_id`
  (required input per Q2 (a)) so the Pro-only Organizations API is
  never touched at test time. Per Q3 / [INV-0002](../investigation/0002-fleet-wide-localstack-pro-auto-detection-harness-for-tests.md),
  the fleet-wide Pro-detection harness (probing `/_localstack/info`
  and skipping Pro-only cases when running Community) is a separate
  workstream; this module's suite is tier-agnostic by construction.
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

Two rounds of answers received (2026-05-18, 2026-05-19). All eight
questions are resolved and folded into the relevant phases.

### Q1 — `name_prefix` semantics — RESOLVED (b)

**Resolved (b):** prefix every resource name with `var.name_prefix`.
The module produces `alias/${name_prefix}-ecr-oci`,
`${name_prefix}-ecr-template`, `${name_prefix}-oci-publisher`. Phase
1 / 2 / 4 / 6 tasks already assume this — no doc changes needed.

### Q2 — `data.aws_organizations_organization` permission scope — RESOLVED (a)

**Resolved (a):** required string input
`var.organizations_org_id`. Zero data sources. Zero permission
concerns. Matches the fleet's
[ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md)
"all cross-stack data is either remote state or explicit input"
posture. The caller's Terragrunt config supplies the literal `o-...`
value in the artifact-hosting account.

Phase 1 (variable surface) makes `organizations_org_id` a required
string with `^o-[a-z0-9]{10,32}$` format validation. Phase 2 drops
the Organizations data source entirely — only
`data.aws_caller_identity.current` remains. Phase 5's org-wide pull
policy references `var.organizations_org_id` directly at the use
site (no aliasing local — ADR-0001). All `tests/` runs now pass the
org ID as a variable value rather than via `override_data` on the
data source.

If a future iteration needs anything else from Organizations (OU
IDs, account enumeration, delegated-admin lookup), introducing a
data source then is a non-breaking additive change — until then,
(a) is the permanent shape.

### Q3 — Pro-tier auto-detection in `tests-localstack/` — RESOLVED (INV-0002 filed)

**Resolved:** filed as
[INV-0002](../investigation/0002-fleet-wide-localstack-pro-auto-detection-harness-for-tests.md)
for the fleet-wide auto-detection harness (out-of-scope for
IMPL-0006). For THIS module specifically, the question is moot —
the `tests-localstack/` suite uses `var.organizations_org_id`
(required input per Q2 (a)) and a `plan_smoke` against LocalStack
endpoints; no Pro-only API is touched. The suite runs identically
against LocalStack Community and Pro and is therefore tier-agnostic
by construction. `FINDINGS.md` (Finding #2) documents this and
cross-references INV-0002.

### Q4 — Existing-repo migration — RESOLVED (c)

**Resolved (c):** ignore old repos; assume the artifact-hosting
account is greenfield for OCI artifacts. No migration tooling
emitted by the module; no bulk script documented in the README
(removed from the Phase 11 task list). If a migration ever becomes
necessary, file it as a one-shot operational PR outside this module.

### Q5 — `var.tags` shape — RESOLVED (`map(string)`)

**Resolved:** `map(string)`. Matches the sibling
`modules/ecr/pull-through-cache/` module's pattern. Phase 1 tasks
already assume this — no doc changes needed.

### Q6 — `IMMUTABLE_WITH_EXCLUSION` provider pin — RESOLVED (`~> 6.2`)

**Resolved:** keep the fleet pin `~> 6.2`. The currently-installed
provider (`v6.45.0`) satisfies the `>= 6.8.0` minimum for
`IMMUTABLE_WITH_EXCLUSION`. No fallback path needed; no provider
pin bump. Phase 1 task already encodes this.

### Q7 — Output via SSM Parameter Store — RESOLVED (c, opt-in, configurable cross-account)

**Resolved (c) + opt-in default off + configurable cross-account:**
the module publishes **both** the publisher policy ARN and the full
policy JSON to SSM, gated on `var.publish_to_ssm` (default
`false` — opt-in). Defaults to same-account behavior (Standard
tier, no resource-based policy); configurable for cross-account via
`var.ssm_cross_account_org_id` — when non-null, the SSM parameters
move to Advanced tier and a resource-based policy grants
`ssm:GetParameter` to `aws:PrincipalOrgID` (mirroring the trust
model on the ECR templates' org-wide pull policy).

Phase 7 (new) adds:

- `aws_ssm_parameter.publisher_policy_arn[0]` — count-gated on
  `var.publish_to_ssm`, value =
  `aws_iam_policy.oci_publisher.arn`, default path
  `/platform/ecr-oci-publisher-policy-arn`.
- `aws_ssm_parameter.publisher_policy_json[0]` — count-gated on
  `var.publish_to_ssm`, value =
  `data.aws_iam_policy_document.oci_publisher.json`, default path
  `/platform/ecr-oci-publisher-policy-json`.
- `data.aws_iam_policy_document.ssm_org_read[0]` — count-gated on
  `var.ssm_cross_account_org_id != null`, drives the resource-based
  policy attachment.

Phase 8 (Outputs) adds
`publisher_policy_ssm_arn_parameter_name` and
`publisher_policy_ssm_json_parameter_name` outputs that resolve to
the SSM path or `null`. Phase 9's `tests/ssm.tftest.hcl` covers
off / on same-account / on cross-account. Phase 11 README covers
the cross-account consumer pattern (consumer reads the JSON via
`data.aws_ssm_parameter` and recreates the policy locally in its
own account).

**Schema caveat carried into implementation (per IMPL-0005 Q3
pattern):** the v6 provider's SSM-parameter resource-based-policy
surface needs verification at implementation time. If
`hashicorp/aws ~> 6.2` lacks a dedicated `aws_ssm_resource_policy`
resource (or an inline `policy` attribute on `aws_ssm_parameter`),
emit the org-read JSON as an additional output and document the
`aws ssm put-resource-policy` CLI fallback in README. Mirrors the
IMPL-0005 `prefix = "*"` → `prefix = "ROOT"` schema-driven
adjustment.

### Q8 — Module-managed KMS key destruction safety — RESOLVED (doc + prevent_destroy)

**Resolved:** **both** doc-only mitigation AND `prevent_destroy`
lifecycle block on `aws_kms_key.ecr_oci`. The Phase 3 task is updated
to add `lifecycle { prevent_destroy = true }`; the Phase 11 README
task is updated with the two-step destruction-unlock procedure
(empty repos → remove `lifecycle` block in a deliberate PR →
destroy). The `prevent_destroy` guard turns the destroy mistake from
a 30-day-time-bomb into a plan-time error pointing the operator at
the README procedure.

## References

- [DESIGN-0006](../design/0006-org-wide-ecr-oci-artifact-registry.md) — Org-wide ECR OCI Artifact Registry (this implementation's source of truth).
- [RFC-0002](../rfc/0002-ecr-layout-for-internal-oci-artifacts.md) — ECR Layout for Internal OCI Artifacts.
- [ADR-0016](../adr/0016-use-ecr-repository-creation-templates-for-oci-artifact-repos.md) — Use ECR Repository Creation Templates for OCI Artifact Repos.
- [DESIGN-0005](../design/0005-ecr-pull-through-cache-module.md) / [IMPL-0005](0005-ecr-pull-through-cache-module-implementation.md) — Sibling EKS-facing pull-through cache module; shares the `aws_ecr_repository_creation_template` provider gotchas (Q3 schema verification, LocalStack 501).
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md) — Module Testing Strategy (drives the `tests/` + `tests-localstack/` split in Phases 9 + 10).
- [INV-0002](../investigation/0002-fleet-wide-localstack-pro-auto-detection-harness-for-tests.md) — Fleet-wide LocalStack Pro auto-detection harness (Q3 follow-up; out-of-scope for IMPL-0006).
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — Cross-module composition via `terraform_remote_state` (this module reads no remote state — fleet-shared).
- [ADR-0011](../adr/0011-runtimeclass-delivered-out-of-band-not-by-terraform.md) — Terraform manages AWS API resources only (this module is pure AWS API).
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md) — `terraform test` for plan-time invariants (Phase 9).
- [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md) — libtftest for apply-time runtime validation (informs Phase 10 framing).
- [Amazon ECR repository creation templates](https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-creation-templates.html)
- [Pushing a Helm chart to an Amazon ECR private repository](https://docs.aws.amazon.com/AmazonECR/latest/userguide/push-oci-artifact.html)
