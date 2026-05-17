---
id: IMPL-0005
title: "ECR Pull-Through Cache Module Implementation"
status: Draft
author: Donald Gifford
created: 2026-05-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0005: ECR Pull-Through Cache Module Implementation

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-15

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Phase 1: Module scaffolding and variable surface](#phase-1-module-scaffolding-and-variable-surface)
    - [Tasks](#tasks)
    - [Success Criteria](#success-criteria)
  - [Phase 2: Upstream catalog and locals](#phase-2-upstream-catalog-and-locals)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Secrets Manager secrets for authenticated upstreams](#phase-3-secrets-manager-secrets-for-authenticated-upstreams)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Pull-through cache rules](#phase-4-pull-through-cache-rules)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Repository creation template (auto-vivification)](#phase-5-repository-creation-template-auto-vivification)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: Node IAM policy (gated)](#phase-6-node-iam-policy-gated)
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
  - [Phase 10: README, USAGE, prereq docs, CI plumbing](#phase-10-readme-usage-prereq-docs-ci-plumbing)
    - [Tasks](#tasks-9)
    - [Success Criteria](#success-criteria-9)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [Q1 — ADR-0002 tension: does the node role gain a third managed policy?](#q1--adr-0002-tension-does-the-node-role-gain-a-third-managed-policy)
  - [Q2 — Repository creation template: one or many?](#q2--repository-creation-template-one-or-many)
  - [Q3 — awsecrrepositorycreationtemplate schema verification](#q3--awsecrrepositorycreationtemplate-schema-verification)
  - [Q4 — cacheurlprefixes URL construction reliability](#q4--cacheurlprefixes-url-construction-reliability)
  - [Q5 — Secrets Manager auth credential JSON shape across upstreams](#q5--secrets-manager-auth-credential-json-shape-across-upstreams)
  - [Q6 — LocalStack Pro awsecrrepositorycreationtemplate fidelity](#q6--localstack-pro-awsecrrepositorycreationtemplate-fidelity)
  - [Q7 — nodepullthroughpolicyarn attached at Terragrunt layer or at module layer?](#q7--nodepullthroughpolicyarn-attached-at-terragrunt-layer-or-at-module-layer)
  - [Q8 — Should the cluster actually use the cache?](#q8--should-the-cluster-actually-use-the-cache)
- [References](#references)
<!--toc:end-->

## Objective

Implement `modules/eks/ecr-pull-through-cache` — the fleet-shared,
account-level module that provisions ECR pull-through cache rules,
Secrets-Manager-backed upstream credentials, ECR repository creation
templates for auto-vivification, and the additional node IAM policy nodes
need to use the cache. Goal: end the cluster's runtime dependency on
direct public-registry pulls without forcing per-image manifest rewrites.

**Implements:** DESIGN-0005.

## Scope

### In Scope

- `aws_ecr_pull_through_cache_rule` resources, one per selected upstream
  (the six DESIGN-0005 upstreams: ECR Public, Quay, Docker Hub, GHCR,
  Kubernetes registry, MCR).
- Per-authenticated-upstream `aws_secretsmanager_secret` +
  `aws_secretsmanager_secret_version` with placeholder body and
  `lifecycle.ignore_changes = [secret_string]` so operator-rotated values
  aren't clobbered.
- One `aws_ecr_repository_creation_template` with `prefix = "ROOT"`
  (the v6-supported match-all special value; `"*"` is rejected by
  plan-time validation per Q3 schema verification),
  `applied_for = ["PULL_THROUGH_CACHE"]`, parameterized untagged-image
  retention via lifecycle policy, and AES256 encryption.
  (scan_on_push dropped per Q3 — the v6 provider's template schema
  does not expose it; ECR scan-on-push is per-account, out-of-scope.)
- One gated `aws_iam_policy.node_pull_through[0]` (gated on
  `var.enable_node_pull_through_policy`) granting
  `ecr:CreateRepository` + `ecr:BatchImportUpstreamImage` on
  account-scoped ECR repository ARNs — the consumer node-group module
  attaches this via `var.extra_node_policies`.
- `data.aws_caller_identity.current` for account-ID-scoped IAM policy
  resource ARNs (identity-class carve-out per ADR-0001).
- Plan-time terraform test suite (resource counts, validation
  negatives, lifecycle JSON content, IAM policy resource scope).
- Apply-against-LocalStack terraform test suite — best-fit candidate per
  DESIGN-0005 §Testing Strategy; expected to surface meaningful
  sneakystack/libtftest backlog items.

### Out of Scope

- Kubernetes manifest image-reference rewriting — caller's
  Helm/Kustomize/Argo job (ADR-0011).
- VPC endpoints (`ecr.api`, `ecr.dkr`, `s3`) — VPC stack owns these;
  documented prerequisite in README.
- Secrets Manager rotation lambda — operators rotate manually via
  `aws secretsmanager put-secret-value` (DESIGN-0005 still-open Q).
- ECR repository lifecycle for non-pull-through repos.
- OCI artifact caching (Helm charts via OCI registry) — image-only in v1.
- Cross-region replication — per-region instantiations only.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its
tasks are checked off and its success criteria are met.

---

### Phase 1: Module scaffolding and variable surface

Copy the per-module scaffolding from `modules/eks/cluster` and define the
full input contract. Validation block on `upstream_registries` rejects
unknown values at plan time. No resources yet.

#### Tasks

- [x] Create `modules/eks/ecr-pull-through-cache/` directory.
- [x] Copy scaffolding files verbatim from `modules/eks/cluster/`:
      `.terraform-docs.yml`, `.tflint.hcl`, `README.md`, `USAGE.md`
      skeleton.
- [x] Create `versions.tf` pinning `hashicorp/aws ~> 6.2`, Terraform
      `>= 1.1`.
- [x] Create `variables.tf` with the full surface from DESIGN-0005:
  - Required: `region` (`string`), `name_prefix` (`string`),
    `upstream_registries` (`list(string)`).
  - Optional: `enable_node_pull_through_policy` (default `true`),
    `repo_creation_template_prefix` (default `"ROOT"` — schema-driven
    divergence from DESIGN-0005's speculative `"*"`; the v6 provider's
    plan-time validation accepts only the special string `"ROOT"` or
    a 2-256 char alphanumeric/underscore/period/hyphen/slash value),
    `untagged_image_retention_days` (`number`, default `7`),
    `tags` (`map(string)`, default `{}`).
    (`scan_on_push` dropped — not exposed by the v6 template schema.)
- [x] Add `validation` block on `upstream_registries`:
  - `condition = alltrue([for u in var.upstream_registries : contains(["ecr-public","quay","docker-hub","ghcr","kubernetes","mcr"], u)])`.
  - Clear error message listing the supported set.
- [x] Add `validation` block: `length(var.upstream_registries) > 0`
      (DESIGN-0005 §Testing Strategy plan-time assertion).
- [x] Create empty `main.tf`, `credentials.tf`, `template.tf`,
      `iam.tf`, `locals.tf`, `outputs.tf` files.
- [x] Run `terraform init && terraform validate`.
- [x] Run `tflint --init && tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass clean.
- `terraform-docs .` produces a USAGE.md table listing every variable.
- Scaffolding files match the cluster module's shape verbatim.
- `upstream_registries = ["bogus"]` fails at plan with a clear
  validation error.
- Empty `upstream_registries = []` fails at plan with a clear
  validation error.

---

### Phase 2: Upstream catalog and locals

Build the static catalog mapping each supported upstream to its `prefix`,
`upstream_url`, and whether it requires authentication. Compose
`local.cache_rules` keyed by upstream name from `var.upstream_registries`.

#### Tasks

- [x] In `locals.tf`, add `local.upstream_catalog`:

  ```hcl
  local.upstream_catalog = {
    "ecr-public" = { prefix = "ecr-public",  upstream_url = "public.ecr.aws",   auth_required = false }
    "quay"       = { prefix = "quay",        upstream_url = "quay.io",          auth_required = false }
    "docker-hub" = { prefix = "docker-hub",  upstream_url = "registry-1.docker.io", auth_required = true  }
    "ghcr"       = { prefix = "ghcr",        upstream_url = "ghcr.io",          auth_required = true  }
    "kubernetes" = { prefix = "kubernetes",  upstream_url = "registry.k8s.io",  auth_required = false }
    "mcr"        = { prefix = "mcr",         upstream_url = "mcr.microsoft.com", auth_required = false }
  }
  ```

- [x] In `locals.tf`, derive `local.selected = { for name in var.upstream_registries : name => local.upstream_catalog[name] }`.
- [x] In `locals.tf`, derive `local.authenticated = { for name, cfg in local.selected : name => cfg if cfg.auth_required }`.
- [x] In `locals.tf`, derive `local.account_id = data.aws_caller_identity.current.account_id`.
- [x] Add `data "aws_caller_identity" "current" {}` (ADR-0001
      identity-class carve-out — same shape as cluster module).
- [x] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- The three locals (`selected`, `authenticated`, `account_id`) compute
  for every legal `upstream_registries` input.
- No aliasing locals that re-export `data.aws_caller_identity` fields
  beyond what's needed for compositional IAM policy ARN scoping (ADR-0001 / CLAUDE.md).

---

### Phase 3: Secrets Manager secrets for authenticated upstreams

Provision one `aws_secretsmanager_secret` + initial
`aws_secretsmanager_secret_version` per authenticated upstream. Secret
name must be prefixed `ecr-pullthroughcache/` (ECR API requirement).
Version body is a placeholder; operator populates real credentials
post-apply.

#### Tasks

- [x] In `credentials.tf`, add `aws_secretsmanager_secret.upstream` with
      `for_each = local.authenticated`:
  - `name = "ecr-pullthroughcache/${var.name_prefix}-${each.key}"`.
  - `description = "ECR pull-through cache credentials for ${each.value.upstream_url}"`.
  - `tags = var.tags`.
- [x] Add `aws_secretsmanager_secret_version.upstream` with
      `for_each = local.authenticated`:
  - `secret_id = aws_secretsmanager_secret.upstream[each.key].id`.
  - `secret_string = jsonencode({ username = "REPLACE_ME", accessToken = "REPLACE_ME" })`.
  - `lifecycle { ignore_changes = [secret_string] }` so the operator-
    rotated value persists across `terraform apply` runs.
- [x] Add a README NOTE block (in the module's README, not USAGE.md)
      explaining the post-apply credential population step:

  ```sh
  aws secretsmanager put-secret-value \
    --secret-id ecr-pullthroughcache/${name_prefix}-docker-hub \
    --secret-string '{"username":"<user>","accessToken":"<token>"}'
  ```

- [x] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- With `upstream_registries = ["ecr-public","docker-hub","ghcr"]`,
  plan contains 2 secrets + 2 secret versions (only docker-hub + ghcr
  are auth-required).
- With `upstream_registries = ["ecr-public","quay","kubernetes","mcr"]`,
  plan contains 0 secrets / 0 versions.
- The `lifecycle.ignore_changes = [secret_string]` is on the
  `aws_secretsmanager_secret_version` resource (confirmed in plan output
  via `tflint`-clean run).

---

### Phase 4: Pull-through cache rules

Provision one `aws_ecr_pull_through_cache_rule` per selected upstream.
Authenticated upstreams reference their Secrets Manager secret ARN;
open upstreams pass `credential_arn = null`.

#### Tasks

- [x] In `main.tf`, add `aws_ecr_pull_through_cache_rule.this` with
      `for_each = local.selected`:
  - `ecr_repository_prefix = each.value.prefix`.
  - `upstream_registry_url = each.value.upstream_url`.
  - `credential_arn = each.value.auth_required ? aws_secretsmanager_secret.upstream[each.key].arn : null`.
- [x] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- One cache rule per upstream in plan.
- Authenticated upstreams' `credential_arn` references the matching
  secret ARN.
- Open upstreams' `credential_arn` is `null`.

---

### Phase 5: Repository creation template (auto-vivification)

Provision the single `aws_ecr_repository_creation_template` per
DESIGN-0005, parameterized by `var.untagged_image_retention_days` and
`var.scan_on_push`.

#### Tasks

- [x] In `template.tf`, add `data "aws_iam_policy_document"
      "cache_repo_policy"` — minimal repository policy granting the
      pull-through service principal `ecr:BatchImportUpstreamImage`
      access. (Verify exact action set against current ECR docs.)
- [x] Add `aws_ecr_repository_creation_template.pull_through`:
  - `prefix = var.repo_creation_template_prefix` (default `"ROOT"` —
    schema-driven from Q3; `"*"` is rejected by v6 plan-time validation).
  - `applied_for = ["PULL_THROUGH_CACHE"]`.
  - `image_tag_mutability = "MUTABLE"`.
  - `encryption_configuration { encryption_type = "AES256" }`.
  - `lifecycle_policy = jsonencode({ rules = [ { rulePriority = 1, description = "Prune untagged images after ${var.untagged_image_retention_days} days", selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = var.untagged_image_retention_days }, action = { type = "expire" } } ] })`.
  - `resource_tags = var.tags`.
  - `repository_policy` and `scan_on_push` dropped per Q3 — the v6
    template schema does not expose `scan_on_push`, and an explicit
    `repository_policy` is unnecessary (ECR auto-attaches a service
    -principal policy to pull-through-created repos).
- [x] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- Plan contains exactly one
  `aws_ecr_repository_creation_template.pull_through`.
- The encoded `lifecycle_policy` JSON contains the
  `var.untagged_image_retention_days` value (verifiable in plan output).
- `applied_for` is exactly `["PULL_THROUGH_CACHE"]` — does not include
  `REPLICATION` (would scope the template wider than intended).

---

### Phase 6: Node IAM policy (gated)

Provision the additional managed-style IAM policy that the node-group
module's `var.extra_node_policies` consumes. **Important:** this is the
tension point with ADR-0002 — see Open Questions Q1.

#### Tasks

- [x] In `iam.tf`, add `data "aws_iam_policy_document" "node_pull_through"`
      with `count = var.enable_node_pull_through_policy ? 1 : 0`:
  - One Allow statement, two actions: `ecr:CreateRepository`,
    `ecr:BatchImportUpstreamImage`.
  - `resources = ["arn:aws:ecr:${var.region}:${local.account_id}:repository/*"]`.
- [x] Add `aws_iam_policy.node_pull_through` with
      `count = var.enable_node_pull_through_policy ? 1 : 0`:
  - `name = "${var.name_prefix}-ecr-pull-through"`.
  - `description = "Permissions for EKS nodes to use ECR pull-through cache (consumed by managed-node-group var.extra_node_policies)"`.
  - `policy = data.aws_iam_policy_document.node_pull_through[0].json`.
  - `tags = var.tags`.
- [x] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- `enable_node_pull_through_policy = true` produces exactly one IAM
  policy resource.
- `enable_node_pull_through_policy = false` produces zero IAM policy
  resources, and the `node_pull_through_policy_arn` output is `null`.
- Policy resource ARN scope is correctly bound to
  `var.region` + `data.aws_caller_identity.current.account_id`.

---

### Phase 7: Outputs

Define the module's output contract per DESIGN-0005.

#### Tasks

- [x] In `outputs.tf`, define:
  - `cache_rule_arns` —
    `{ for k, r in aws_ecr_pull_through_cache_rule.this : k => r.id }`
    (or `.arn` — verify v6 schema; pull-through cache rules expose `id`
    as the canonical identifier).
  - `cache_url_prefixes` —
    `{ for k, r in aws_ecr_pull_through_cache_rule.this : k => "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com/${r.ecr_repository_prefix}" }`.
  - `credential_secret_arns` —
    `{ for k, s in aws_secretsmanager_secret.upstream : k => s.arn }`.
  - `node_pull_through_policy_arn` —
    `var.enable_node_pull_through_policy ? aws_iam_policy.node_pull_through[0].arn : null`.
  - `repository_creation_template_arn` —
    `aws_ecr_repository_creation_template.pull_through.arn` (verify
    schema; may be exposed under a different attribute name).
- [x] Run `terraform-docs .` to regenerate USAGE.md.
- [x] Commit USAGE.md.

#### Success Criteria

- USAGE.md regenerated with all inputs and all five outputs.
- `terraform validate` passes.
- `cache_url_prefixes` renders syntactically valid ECR URLs in plan
  output (the account-ID interpolation resolves at plan time because
  `data.aws_caller_identity.current` is a data source resolved during
  plan).

---

### Phase 8: terraform test plan-only suite (`tests/`)

Plan-time invariants per RFC-0001. Resource-count assertions for the
three load-bearing shapes (all open, mixed, all authenticated), the two
validation negatives, the lifecycle JSON content, and the IAM policy
resource scope.

#### Tasks

- [x] Create `modules/eks/ecr-pull-through-cache/tests/` directory.
- [x] Create `tests/all_open.tftest.hcl`:
  - `run "plan_open"`:
    `upstream_registries = ["ecr-public","kubernetes","mcr"]`.
    Assertions:
    - 3 `aws_ecr_pull_through_cache_rule` resources.
    - 0 `aws_secretsmanager_secret` resources.
    - 1 `aws_ecr_repository_creation_template` resource.
    - 1 `aws_iam_policy` resource (default
      `enable_node_pull_through_policy = true`).
- [x] Create `tests/mixed.tftest.hcl`:
  - `run "plan_mixed"`:
    `upstream_registries = ["ecr-public","docker-hub","ghcr"]`.
    Assertions:
    - 3 cache rules.
    - 2 Secrets Manager secrets + 2 versions (docker-hub + ghcr only).
    - 1 creation template.
    - 1 IAM policy.
  - Assertion: the docker-hub cache rule's `credential_arn` references
    the docker-hub Secrets Manager secret's ARN (not `null`).
    *(Implementation note: at plan time the secret ARN is unknown, so
    the assertion is structural — verify the docker-hub key exists in
    `aws_secretsmanager_secret.upstream`, which guarantees the
    for_each wiring in main.tf populates credential_arn.)*
  - Assertion: the ecr-public cache rule's `credential_arn` is `null`.
- [x] Create `tests/all_authenticated.tftest.hcl`:
  - `run "plan_auth"`: `upstream_registries = ["docker-hub","ghcr"]`.
    Assertions:
    - 2 cache rules, 2 secrets, 2 versions.
- [x] Create `tests/validation.tftest.hcl`:
  - `run "negative_bogus_upstream"`:
    `upstream_registries = ["bogus"]`.
    `expect_failures = [var.upstream_registries]`.
  - `run "negative_empty"`: `upstream_registries = []`.
    `expect_failures = [var.upstream_registries]`.
- [x] Create `tests/iam_gate.tftest.hcl`:
  - `run "iam_disabled"`:
    `enable_node_pull_through_policy = false`,
    `upstream_registries = ["docker-hub"]`.
    Assertions:
    - 0 IAM policy resources.
    - `output.node_pull_through_policy_arn == null`.
- [x] Create `tests/lifecycle_json.tftest.hcl`:
  - `run "default_retention"`: `untagged_image_retention_days = 7`.
    Assertion: encoded JSON of the creation template's
    `lifecycle_policy` contains `"countNumber":7`.
  - `run "custom_retention"`: `untagged_image_retention_days = 30`.
    Assertion: encoded JSON contains `"countNumber":30`.
- [x] Create `tests/iam_scope.tftest.hcl`:
  - `run "policy_scope"`: with `region = "us-east-1"`.
    Assertion: IAM policy JSON's `Resource` field matches
    `arn:aws:ecr:us-east-1:*:repository/*` (the account-ID placeholder
    is resolved at plan time via
    `data.aws_caller_identity.current.account_id`).
- [x] Verify `just tf test eks/ecr-pull-through-cache` works
      module-agnostically.

#### Success Criteria

- All seven `.tftest.hcl` suites pass.
- Total runtime ≤ 8s (plan-only, no apply, no LocalStack).
- `expect_failures` correctly catches both validation negatives.
- The lifecycle-policy JSON assertion captures the
  `untagged_image_retention_days` parameter — a regression of the JSON
  encoding (e.g., dropping `countNumber`) would fail this test.

---

### Phase 9: terraform test apply-against-LocalStack suite (`tests-localstack/`)

DESIGN-0005 explicitly calls this module out as a strong LocalStack Pro
candidate. The apply suite exercises the four AWS APIs this module
touches: ECR pull-through cache, Secrets Manager, ECR creation template,
IAM. Expected outcome: real surface gets covered, sneakystack tickets
get filed for any LocalStack fidelity gaps.

#### Tasks

- [ ] Create `modules/eks/ecr-pull-through-cache/tests-localstack/`
      directory.
- [ ] Create `tests-localstack/apply_localstack.tftest.hcl` (no setup
      fixture needed — this module reads no cluster state):
  - Provider block with the comprehensive `endpoints` map and
    LocalStack-friendly settings (mirror the cluster module's working
    config).
  - `run "apply_mixed"`:
    `upstream_registries = ["ecr-public","docker-hub"]`,
    `name_prefix = "test"`. Assertions:
    - `aws_ecr_pull_through_cache_rule.this["ecr-public"].id` populated.
    - `aws_ecr_pull_through_cache_rule.this["docker-hub"].id` populated.
    - `aws_secretsmanager_secret.upstream["docker-hub"].arn` populated.
    - `aws_secretsmanager_secret_version.upstream["docker-hub"].id`
      populated.
    - `aws_ecr_repository_creation_template.pull_through.arn`
      populated.
    - `aws_iam_policy.node_pull_through[0].arn` populated.
    - Output `cache_url_prefixes["docker-hub"]` is a syntactically
      valid `<acct>.dkr.ecr.<region>.amazonaws.com/docker-hub` URL.
- [ ] Create `tests-localstack/FINDINGS.md` capturing observed
      LocalStack Pro fidelity gaps per DESIGN-0005 §Testing Strategy
      (use as input into sneakystack / libtftest backlog):
  - Does LocalStack persist `aws_ecr_repository_creation_template`?
    (Newer ECR API; expected to be partial.)
  - Does LocalStack validate the `credential_arn` reference on
    `aws_ecr_pull_through_cache_rule` against Secrets Manager?
  - Does an actual `crictl pull` through the cache URL work? (Almost
    certainly no — LocalStack ECR doesn't proxy to real Docker Hub.
    Document as "out-of-scope-of-LocalStack" backlog for
    sneakystack-vs-real-cluster planning.)
- [ ] Verify `just tf test-localstack eks/ecr-pull-through-cache` works
      module-agnostically.
- [ ] If any apply step 501s in LocalStack, comment out that block, log
      the gap in `FINDINGS.md`, and proceed — gap-discovery success per
      RFC-0001.

#### Success Criteria

- `just tf test-localstack eks/ecr-pull-through-cache` either:
  - **passes the apply end-to-end**, with all five output ARNs
    populated, OR
  - **fails with documented LocalStack-fidelity gaps** captured in
    `FINDINGS.md` and the affected blocks skipped — same gap-discovery
    framing as IMPL-0004 Phase 8.
- Total runtime ≤ 90s end-to-end.
- The suite stays opt-in — plain `terraform test` does not load it.
- `FINDINGS.md` captures every observed gap as actionable sneakystack /
  libtftest backlog (the explicit goal of this suite per
  DESIGN-0005 §Testing Strategy).

---

### Phase 10: README, USAGE, prereq docs, CI plumbing

Final polish — caller-facing docs covering the VPC endpoint prerequisite,
the post-apply credential population step, and how to wire
`node_pull_through_policy_arn` into the node-group module.

#### Tasks

- [ ] Update `modules/eks/ecr-pull-through-cache/README.md`:
  - Short pointer to USAGE.md.
  - Prerequisite section: the three VPC endpoints
    (`com.amazonaws.<region>.ecr.api`,
    `com.amazonaws.<region>.ecr.dkr`,
    `com.amazonaws.<region>.s3`).
  - Post-apply Secrets Manager population snippet (the `aws
    secretsmanager put-secret-value` command from Phase 3).
  - Consumer integration snippet showing how the managed-node-group
    module attaches `node_pull_through_policy_arn` via
    `var.extra_node_policies` (forward-references IMPL-0002).
  - Image-reference rewriting note (out-of-scope; Helm/Kustomize
    layer).
- [ ] Regenerate `USAGE.md` via `terraform-docs .`.
- [ ] Final pass: confirm zero `kubernetes` / `kubectl` / `helm`
      provider references (ADR-0011).
- [ ] Final pass: confirm zero aliasing locals that re-export remote
      state (ADR-0001 / CLAUDE.md). This module reads no remote state
      anyway — confirm the only `data.*` call is
      `aws_caller_identity.current`.
- [ ] Verify `just tf all eks/ecr-pull-through-cache` passes.

#### Success Criteria

- `just tf all eks/ecr-pull-through-cache` passes (validate + lint +
  fmt + test).
- USAGE.md committed and reflects the final input/output contract.
- README documents the three VPC endpoint prerequisites, the
  post-apply secret population step, and the node-group integration
  snippet — all three failure modes a new caller would otherwise hit.
- No provider drift vs the cluster module's pinned `~> 6.2` and
  Terraform `>= 1.1`.

---

## File Changes

| File                                                                    | Action | Description                                                                                       |
| ----------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------- |
| `modules/eks/ecr-pull-through-cache/main.tf`                            | Create | `aws_ecr_pull_through_cache_rule.this` (for_each over selected upstreams).                        |
| `modules/eks/ecr-pull-through-cache/credentials.tf`                     | Create | Secrets Manager secret + version per authenticated upstream; `ignore_changes = [secret_string]`.  |
| `modules/eks/ecr-pull-through-cache/template.tf`                        | Create | `aws_ecr_repository_creation_template.pull_through` with lifecycle JSON.                          |
| `modules/eks/ecr-pull-through-cache/iam.tf`                             | Create | Gated `aws_iam_policy.node_pull_through[0]`.                                                      |
| `modules/eks/ecr-pull-through-cache/locals.tf`                          | Create | Upstream catalog, selected map, authenticated map, account-id local.                              |
| `modules/eks/ecr-pull-through-cache/variables.tf`                       | Create | Input surface with two validation blocks (unknown upstreams + empty list).                        |
| `modules/eks/ecr-pull-through-cache/outputs.tf`                         | Create | Five outputs per DESIGN-0005.                                                                     |
| `modules/eks/ecr-pull-through-cache/versions.tf`                        | Create | `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`.                                                       |
| `modules/eks/ecr-pull-through-cache/README.md`                          | Modify | Prereqs, post-apply secret population, node-group integration snippet.                            |
| `modules/eks/ecr-pull-through-cache/USAGE.md`                           | Modify | Regenerated by terraform-docs.                                                                    |
| `modules/eks/ecr-pull-through-cache/.terraform-docs.yml`                | Create | Copied verbatim from cluster module.                                                              |
| `modules/eks/ecr-pull-through-cache/.tflint.hcl`                        | Create | Copied verbatim from cluster module.                                                              |
| `modules/eks/ecr-pull-through-cache/tests/all_open.tftest.hcl`          | Create | Resource-count assertions for the all-open shape.                                                 |
| `modules/eks/ecr-pull-through-cache/tests/mixed.tftest.hcl`             | Create | Resource-count + credential_arn wiring for mixed open/auth upstreams.                             |
| `modules/eks/ecr-pull-through-cache/tests/all_authenticated.tftest.hcl` | Create | Resource-count assertions for the all-authenticated shape.                                       |
| `modules/eks/ecr-pull-through-cache/tests/validation.tftest.hcl`        | Create | `expect_failures` on unknown upstream + empty list.                                               |
| `modules/eks/ecr-pull-through-cache/tests/iam_gate.tftest.hcl`          | Create | `enable_node_pull_through_policy = false` produces zero IAM resources.                            |
| `modules/eks/ecr-pull-through-cache/tests/lifecycle_json.tftest.hcl`    | Create | `untagged_image_retention_days` is embedded in the lifecycle JSON.                                |
| `modules/eks/ecr-pull-through-cache/tests/iam_scope.tftest.hcl`         | Create | IAM policy resource ARN is scoped to `var.region` + account ID.                                   |
| `modules/eks/ecr-pull-through-cache/tests-localstack/apply_localstack.tftest.hcl` | Create | Opt-in apply against LocalStack Pro — explicit gap-discovery surface.                  |
| `modules/eks/ecr-pull-through-cache/tests-localstack/FINDINGS.md`       | Create | Captured LocalStack fidelity gaps feeding sneakystack/libtftest backlog.                          |

## Testing Plan

Driven by RFC-0001:

- **Plan-only (`tests/`)** — seven `.tftest.hcl` suites covering
  resource counts under three upstream-set shapes, two validation
  negatives, IAM gate, lifecycle JSON content, and IAM resource
  scope. Runtime ≤ 8s. Runs in CI on every PR.
- **Apply-against-LocalStack (`tests-localstack/`)** — one apply suite
  exercising the four AWS APIs (ECR pull-through, Secrets Manager, ECR
  creation template, IAM). DESIGN-0005 explicitly identifies this
  module as a strong LocalStack candidate. Runtime ≤ 90s. Opt-in.
  Findings captured in `FINDINGS.md` per RFC-0001 gap-discovery loop.
- **No libtftest harness in v1** — cluster module remains the
  side-by-side reference. If `FINDINGS.md` reveals load-bearing apply
  gaps (e.g., LocalStack stubs the creation template), those become
  sneakystack / libtftest backlog.

## Dependencies

- **No blocking dependencies on other module implementations.** This
  module is fleet-shared and cluster-agnostic. It can ship in any order
  relative to IMPL-0001 / IMPL-0002 / IMPL-0003 / IMPL-0004.
- **ADR-0015 (Proposed)** unblocks Phase 6 — the opt-in third
  managed-style policy on the node role is permitted by amendment to
  ADR-0002. The opt-in posture (default `true` on
  `enable_node_pull_through_policy` here; default `[]` on the
  consumer's `var.extra_node_policies` there) means the policy is
  emitted in every pull-through-cache instantiation but never reaches
  a node role without explicit Terragrunt-layer wiring.
- **Downstream consumer**: IMPL-0002 (managed-node-group) Phase 2 adds
  `var.extra_node_policies = []` (default empty list); consumers'
  Terragrunt configs wire
  `module.ecr_pull_through_cache.node_pull_through_policy_arn` into the
  list when both modules are instantiated. IMPL-0002 Phase 4 adds the
  opt-in `var.containerd_pull_through_mirror` (default disabled) for
  the runtime side per Q8.

## Open Questions

All resolved 2026-05-15.

### Q1 — ADR-0002 tension: does the node role gain a third managed policy?

**Resolved A — proposed ADR-0015 written.** See
[ADR-0015](../adr/0015-permit-opt-in-third-managed-policy-on-node-role-for-ecr-pull.md)
(status: Proposed). ADR-0015 permits exactly one customer-managed
policy on the node role with two specific actions
(`ecr:CreateRepository`, `ecr:BatchImportUpstreamImage`) scoped to
`arn:aws:ecr:${region}:${account_id}:repository/*`. The grant is
**opt-in by default** — two stages of consent are required to reach a
node role: (a) the pull-through cache module is instantiated AND (b)
the consumer's Terragrunt config passes the emitted ARN into the
managed-node-group module's `var.extra_node_policies`. Either consent
alone is a no-op.

**Action.** Phase 6's IAM policy stays as drafted (it's the emission
side). IMPL-0002 Q6 captures the consumer-side `var.extra_node_policies`
input addition. README in Phase 10 links to ADR-0015.

### Q2 — Repository creation template: one or many?

**Resolved A.** v1 keeps one template with `prefix = "*"` and a single
global `var.untagged_image_retention_days`. Wait for an actual workload
demand for per-upstream differentiation before adding surface. Phase 10
README documents the v2 path (`var.lifecycle_overrides` keyed by
upstream-name) for the future revisit.

### Q3 — `aws_ecr_repository_creation_template` schema verification

**Resolved A.** Verify exact AWS provider v6 attribute names at Phase 5
implementation time. If the schema diverges from DESIGN-0005's example
(`scan_configuration` vs `scanning_configuration`, lifecycle_policy as
string vs typed block), follow the schema and note the divergence in
USAGE.md. Cheap inline verification; no preflight `terraform providers
schema -json` needed.

### Q4 — `cache_url_prefixes` URL construction reliability

**Resolved A.** v1 is implicitly public-AWS-only. Document the
assumption in Phase 10 README. Partition-aware URL construction
(`amazonaws.com.cn` for China, GovCloud variants) becomes future work
when a real GovCloud consumer materializes — add `data.aws_partition.current`
then.

### Q5 — Secrets Manager auth credential JSON shape across upstreams

**Resolved A.** Single placeholder shape for v1:
`{"username":"REPLACE_ME","accessToken":"REPLACE_ME"}`. ECR's documented
credential format is uniform across Docker Hub / GHCR / Quay; verify
Quay's robot-token shape actually diverges in real testing before
adding per-upstream placeholders. Phase 10 README documents the
post-apply `aws secretsmanager put-secret-value` step and points at
ECR docs for upstream-specific credential format details.

### Q6 — LocalStack Pro `aws_ecr_repository_creation_template` fidelity

**Resolved A.** Test in Phase 9 and capture findings in `FINDINGS.md`.
Gap-discovery is the explicit RFC-0001 value: if creation template is
stubbed-but-not-persisted in LocalStack, that's a sneakystack ticket
(success of the test infrastructure, not failure of the module). The
template is a relatively new ECR API (2023+); LocalStack lag is the
expected case.

### Q7 — `node_pull_through_policy_arn` attached at Terragrunt layer or at module layer?

**Resolved A.** Keep policy emission here, attachment at the
**Terragrunt consumer layer** via the managed-node-group module's
`var.extra_node_policies` input. Avoids this module having a
cross-module dependency on the node-group module's outputs; keeps this
module fleet-shared / cluster-agnostic; matches the existing pattern
where attachments live with the role owner, not the policy author.
ADR-0015's "two stages of consent" framing depends on this boundary.

### Q8 — Should the cluster actually use the cache?

**Resolved B with opt-in default.** IMPL-0002 Phase 4 owns the
containerd mirror config — the launch template user data writes a
`/etc/containerd/config.toml.d/mirror.toml` snippet redirecting
configured upstream registries to the cache URL. This is bootstrap-time
EC2 user-data work (before Kubernetes exists), so ADR-0011 (no K8s API
manipulation from Terraform) is not violated.

**Off by default / opt-in via the managed-node-group module's
`var.containerd_pull_through_mirror = { enabled = false, ... }` input.**
Three reasons for opt-in default:

1. **Symmetry with the IAM gate from ADR-0015.** Two independent
   consents — IAM attachment (`var.extra_node_policies`) AND runtime
   mirror (`var.containerd_pull_through_mirror.enabled`) — match
   ADR-0015's two-stages-of-consent framing. A cluster can have one
   without the other.
2. **Failure mode bias.** A misconfigured mirror silently breaks every
   pod that starts on the node. Off-by-default keeps the boring path
   as the default; opt-in flips it for clusters that have validated
   their cache.
3. **Brownfield migration.** DESIGN-0005's migration plan is
   per-upstream / per-workload. The containerd mirror is all-or-nothing
   at the node level. Opt-in matches the gradual rollout.

**Action.** Cross-reference [IMPL-0002 Q7](0002-managed-node-group-module-implementation.md)
for the consumer-side input shape (the `containerd_pull_through_mirror`
object). No work in this module; this Q only confirms the IMPL-0002 +
IMPL-0005 boundary and the opt-in default.

## References

- DESIGN-0005 — ECR Pull-Through Cache Module (this implementation's
  source of truth).
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (consumer of
  `node_pull_through_policy_arn`; ADR-0002 tension lives here too).
- DESIGN-0002 — EKS Cluster Module (independent of this module).
- IMPL-0002 — Managed Node Group Implementation (downstream consumer of
  `node_pull_through_policy_arn`; needs Q1 resolved before its Phase 2
  hardens around the two-policy node-role shape).
- RFC-0001 — Module Testing Strategy (drives the `tests/` +
  `tests-localstack/` split in Phases 8 + 9; this module is an
  explicit gap-discovery candidate).
- ADR-0001 — Cross-module composition via `terraform_remote_state`
  (relevant to consumers; this module is fleet-shared, reads no remote
  state).
- ADR-0002 — Node IAM minimization (Q1 tension point).
- ADR-0011 — Terraform manages AWS API resources only (this module is
  pure AWS API; image-reference rewriting + containerd config are
  out-of-band).
- ADR-0013 — `terraform test` for plan-time module invariants
  (Phase 8).
- ADR-0014 — libtftest for apply-time runtime validation without AWS
  (informs Phase 9 framing).
- [ADR-0015 (Proposed)](../adr/0015-permit-opt-in-third-managed-policy-on-node-role-for-ecr-pull.md) —
  Permit opt-in third managed policy on node role for ECR pull-through
  cache (resolves Q1).
