---
id: IMPL-0004
title: "Pod Identity Access Module Implementation"
status: Draft
author: Donald Gifford
created: 2026-05-15
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0004: Pod Identity Access Module Implementation

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
  - [Phase 2: Remote state composition and locals](#phase-2-remote-state-composition-and-locals)
    - [Tasks](#tasks-1)
    - [Success Criteria](#success-criteria-1)
  - [Phase 3: Mode A — IAM role + trust policy](#phase-3-mode-a--iam-role--trust-policy)
    - [Tasks](#tasks-2)
    - [Success Criteria](#success-criteria-2)
  - [Phase 4: Mode A — policy attachments and inline policies](#phase-4-mode-a--policy-attachments-and-inline-policies)
    - [Tasks](#tasks-3)
    - [Success Criteria](#success-criteria-3)
  - [Phase 5: Pod Identity Association](#phase-5-pod-identity-association)
    - [Tasks](#tasks-4)
    - [Success Criteria](#success-criteria-4)
  - [Phase 6: Outputs](#phase-6-outputs)
    - [Tasks](#tasks-5)
    - [Success Criteria](#success-criteria-5)
  - [Phase 7: terraform test plan-only suite (tests/)](#phase-7-terraform-test-plan-only-suite-tests)
    - [Tasks](#tasks-6)
    - [Success Criteria](#success-criteria-6)
  - [Phase 8: terraform test apply-against-LocalStack suite (tests-localstack/)](#phase-8-terraform-test-apply-against-localstack-suite-tests-localstack)
    - [Tasks](#tasks-7)
    - [Success Criteria](#success-criteria-7)
  - [Phase 9: README, USAGE, and CI plumbing](#phase-9-readme-usage-and-ci-plumbing)
    - [Tasks](#tasks-8)
    - [Success Criteria](#success-criteria-8)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [Q1 — DESIGN-0004 Mode B is partly stale; should this module own pre-built role bundles?](#q1--design-0004-mode-b-is-partly-stale-should-this-module-own-pre-built-role-bundles)
  - [Q2 — Stable input contract for cross-module composition (just cluster_name?)](#q2--stable-input-contract-for-cross-module-composition-just-clustername)
  - [Q3 — LocalStack fidelity of awsekspodidentityassociation](#q3--localstack-fidelity-of-awsekspodidentityassociation)
  - [Q4 — Association eventual consistency in apply tests](#q4--association-eventual-consistency-in-apply-tests)
  - [Q5 — association_id output vs id](#q5--associationid-output-vs-id)
  - [Q6 — Cross-account targetaccountarns convenience input](#q6--cross-account-targetaccountarns-convenience-input)
- [References](#references)
<!--toc:end-->

## Objective

Implement `modules/eks/pod-identity-access` — the small, single-purpose module
that binds a Kubernetes service account to AWS credentials via an EKS Pod
Identity Association. Instantiated many times per cluster (one per
`(namespace, service_account)` pair), this module is the AWS-side enabler of
the empty-node-role posture established by IMPL-0002 (managed-node-group) and
DESIGN-0001.

**Implements:** DESIGN-0004 (with the stale-Mode-B caveat flagged in Open
Questions).

## Scope

### In Scope

- `aws_eks_pod_identity_association` (always created — module's reason to
  exist).
- Mode A: module creates a Pod-Identity-trusting IAM role with attached managed
  policies, customer-managed policies, and inline JSON policy documents.
- Mode B (escape hatch only): caller passes `existing_role_arn`; module creates
  only the association.
- Remote-state read of cluster identifying outputs (`cluster_name`).
- Validation: enforce exactly one of `create_role = true` vs
  `existing_role_arn` non-null.
- Deterministic IAM role naming with truncation to fit IAM's 64-char limit.
- Plan-time terraform test suite (Modes A + B, validation negatives, name
  truncation).
- Apply-against-LocalStack terraform test suite (opt-in via
  `-test-directory tests-localstack`).

### Out of Scope

- Installing the Pod Identity Agent — owned by IMPL-0003 (addons module) per
  ADR-0003.
- Creating the Kubernetes ServiceAccount — out-of-band (Helm / Kustomize /
  Argo) per ADR-0011.
- Workload Deployment / Pod manifests — out-of-band.
- Cross-account `sts:AssumeRole` convenience inputs (DESIGN-0004 "Still open"
  — callers build inline policy themselves).
- Migration tooling (`eksctl utils migrate-to-pod-identity`) — documented as
  a brownfield path in DESIGN-0004; not in-module.
- Pre-built role bundles for the five well-known controllers (autoscaler, ALB,
  external-dns, FluentD, CW metrics). See Open Questions Q1.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its tasks
are checked off and its success criteria are met.

---

### Phase 1: Module scaffolding and variable surface

Copy the per-module scaffolding from `modules/eks/cluster` (`.terraform-docs.yml`,
`.tflint.hcl`, `README.md`, `versions.tf` shell, USAGE.md skeleton) and define
the full input contract. No resources yet.

#### Tasks

- [x] Create `modules/eks/pod-identity-access/` directory.
- [x] Copy scaffolding files verbatim from `modules/eks/cluster/`:
      `.terraform-docs.yml`, `.tflint.hcl`, `README.md`, `USAGE.md` skeleton.
- [x] Create `versions.tf` pinning `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`.
- [x] Create `variables.tf` with the full surface from DESIGN-0004:
  - Required: `remote_state_bucket`, `region`, `cluster_name`, `namespace`,
    `service_account`.
  - Mode toggle: `create_role` (default `true`).
  - Mode B: `existing_role_arn` (default `null`).
  - Naming: `role_name_override` (default `null`).
  - Mode A policy inputs: `managed_policy_arns` (`list(string)`, default
    `[]`), `customer_managed_policy_arns` (`list(string)`, default `[]`),
    `inline_policies` (`map(string)`, default `{}`), `permissions_boundary`
    (default `null`).
  - Tags: `tags` (default `{}`), `association_tags` (default `{}`).
- [x] Add variable validation: when `create_role = false`,
      `existing_role_arn` must be non-null (`validation` block with clear
      condition / error_message).
- [x] Create empty `main.tf`, `iam.tf`, `locals.tf`, `outputs.tf` files
      (resources land in later phases).
- [x] Run `terraform init && terraform validate` in module dir.
- [x] Run `tflint --init && tflint`.

#### Success Criteria

- `terraform validate` and `tflint` both pass clean.
- `terraform-docs .` produces a USAGE.md table listing every variable with
  type, description, and default.
- All scaffolding files (`.terraform-docs.yml`, `.tflint.hcl`, `versions.tf`,
  `README.md`) match the cluster module's shape verbatim (uniformity by
  convention per CLAUDE.md).
- A `create_role = false` + `existing_role_arn = null` combination fails at
  plan time with a clear validation error.

---

### Phase 2: Remote state composition and locals

Wire up the `data.terraform_remote_state.eks` read and derive the module's
internal naming. No IAM yet — keep this phase pure plumbing.

#### Tasks

- [x] Add `data.terraform_remote_state.eks` block in `main.tf` matching the
      convention from CLAUDE.md (`key = "${var.region}/eks/${var.cluster_name}/terraform.tfstate"`).
- [x] In `locals.tf`, compute `role_name`:
  - Default: `<cluster_name>-<namespace>-<service_account>` joined with `-`.
  - If `var.role_name_override != null`, use the override.
  - Apply length-safe truncation to fit IAM's 64-char limit. Use
    `substr(...)` plus a short hash suffix (e.g., last 6 chars of `sha256`)
    when the joined name exceeds 64 chars, so callers get deterministic
    names without silent collisions.
- [x] Reference `data.terraform_remote_state.eks.outputs.cluster_name` at the
      use site only — no aliasing local (ADR-0001).
- [x] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- A unit-style test (in Phase 7) can confirm the `role_name` local is ≤ 64
  characters for any input combination.
- No `local` simply re-exports a remote-state output (per ADR-0001 / CLAUDE.md
  guidance).

---

### Phase 3: Mode A — IAM role + trust policy

Create the Pod-Identity-trusting role, gated on `var.create_role`. Trust
policy is the universal `pods.eks.amazonaws.com` shape — identical across all
Pod Identity roles fleet-wide (ADR-0004 / DESIGN-0004).

#### Tasks

- [x] In `iam.tf`, add `data "aws_iam_policy_document" "pod_identity_trust"`
      with `count = var.create_role ? 1 : 0`:
  - `effect = "Allow"`.
  - `principals { type = "Service" identifiers = ["pods.eks.amazonaws.com"] }`.
  - `actions = ["sts:AssumeRole", "sts:TagSession"]`.
- [x] Add `aws_iam_role.this` with `count = var.create_role ? 1 : 0`:
  - `name = local.role_name`.
  - `assume_role_policy = data.aws_iam_policy_document.pod_identity_trust[0].json`.
  - `permissions_boundary = var.permissions_boundary` (nullable passthrough).
  - `tags = var.tags`.
- [x] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- With `create_role = false`, plan contains zero IAM role resources.
- With `create_role = true`, plan contains exactly one IAM role with the
  universal Pod Identity trust policy.
- The trust policy includes both `sts:AssumeRole` and `sts:TagSession`
  actions.

---

### Phase 4: Mode A — policy attachments and inline policies

Attach managed-policy ARNs, customer-managed-policy ARNs, and inline JSON
policy documents to the Mode A role. All gated on `var.create_role`.

#### Tasks

- [x] Add `aws_iam_role_policy_attachment.managed` with `for_each = var.create_role ? toset(var.managed_policy_arns) : []`:
  - `role = aws_iam_role.this[0].name`.
  - `policy_arn = each.value`.
- [x] Add `aws_iam_role_policy_attachment.customer` with `for_each = var.create_role ? toset(var.customer_managed_policy_arns) : []`:
  - Same shape as managed; separate resource for state-readability and to
    keep AWS-managed vs customer-owned ARNs visible at the plan level.
- [x] Add `aws_iam_role_policy.inline` with `for_each = var.create_role ? var.inline_policies : {}`:
  - `name = each.key`.
  - `role = aws_iam_role.this[0].name`.
  - `policy = each.value`.
- [x] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- With three managed + one customer + two inline policies, plan contains:
  1 role, 3 managed attachments, 1 customer attachment, 2 inline policies.
- With `create_role = false`, plan contains zero attachments / inline
  policies regardless of `managed_policy_arns` / `customer_managed_policy_arns` /
  `inline_policies` contents (gating works).

---

### Phase 5: Pod Identity Association

Create the `aws_eks_pod_identity_association` — the module's reason to exist.
Role ARN resolution: Mode A passes `aws_iam_role.this[0].arn`, Mode B passes
`var.existing_role_arn`. The conditional lives inline at the resource
(meaningful work — per ADR-0001 framing); no aliasing local.

#### Tasks

- [x] In `main.tf`, add `resource "aws_eks_pod_identity_association" "this"`:
  - `cluster_name = data.terraform_remote_state.eks.outputs.cluster_name`.
  - `namespace = var.namespace`.
  - `service_account = var.service_account`.
  - `role_arn = var.create_role ? aws_iam_role.this[0].arn : var.existing_role_arn`.
  - `tags = var.association_tags`.
- [ ] Re-run `terraform validate` and `tflint`.

#### Success Criteria

- `terraform validate` and `tflint` pass.
- Plan always contains exactly one `aws_eks_pod_identity_association`,
  regardless of mode.
- Mode A: association's `role_arn` is the created role.
- Mode B: association's `role_arn` equals `var.existing_role_arn`.
- Association binding is correct (`cluster_name`, `namespace`,
  `service_account` match inputs / cluster remote state).

---

### Phase 6: Outputs

Define the module's output contract per DESIGN-0004 — `role_arn` plus three
echo outputs handy for multi-instance compositions.

#### Tasks

- [x] In `outputs.tf`, define:
  - `role_arn` — `var.create_role ? aws_iam_role.this[0].arn : var.existing_role_arn`.
  - `association_id` — `aws_eks_pod_identity_association.this.id` (or
    `association_id` if the AWS provider exposes it under that name; verify
    against current `hashicorp/aws ~> 6.2` schema).
  - `namespace` — echo of `var.namespace`.
  - `service_account` — echo of `var.service_account`.
- [x] Run `terraform-docs .` to regenerate USAGE.md.
- [x] Commit USAGE.md.

#### Success Criteria

- USAGE.md is regenerated with all inputs and all four outputs.
- `terraform validate` passes.
- Outputs are stable string types (no nullable surprises that break
  downstream `for_each` over a map of grants).

---

### Phase 7: terraform test plan-only suite (`tests/`)

Plan-time invariants that need no LocalStack — the cheap, fast lane per
RFC-0001. Mode A shape, Mode B shape, validation negatives, naming. All run
without `-test-directory`, default ~1–2s.

#### Tasks

- [x] Create `modules/eks/pod-identity-access/tests/` directory.
- [x] Create `tests/fixtures/setup/` module that produces a stub S3-backend
      `terraform.tfstate` JSON file with cluster outputs (`cluster_name`).
      Pattern: mirror the cluster module's `tests-localstack/fixtures/setup`,
      but plan-only here (no real LocalStack). The remote-state read still
      resolves because Terraform consults the S3 backend at plan time —
      pre-seed the bucket with a fake state in the setup module.
- [x] Create `tests/mode_a.tftest.hcl`:
  - `run "setup_fixture"` applies `fixtures/setup`.
  - `run "plan_mode_a"`: 3 managed + 1 customer + 2 inline policies.
    Assertions:
    - Exactly one `aws_iam_role.this[0]`.
    - Trust policy includes `pods.eks.amazonaws.com`,
      `sts:AssumeRole`, `sts:TagSession`.
    - 3 `aws_iam_role_policy_attachment.managed` entries.
    - 1 `aws_iam_role_policy_attachment.customer` entry.
    - 2 `aws_iam_role_policy.inline` entries.
    - 1 `aws_eks_pod_identity_association.this`.
- [x] Create `tests/mode_b.tftest.hcl`:
  - `run "setup_fixture"` applies `fixtures/setup`.
  - `run "plan_mode_b"`: `create_role = false`,
    `existing_role_arn = "arn:aws:iam::123456789012:role/preexisting"`.
    Assertions:
    - Zero IAM role / attachment / inline resources.
    - Exactly one `aws_eks_pod_identity_association.this`.
    - Association's `role_arn == "arn:aws:iam::123456789012:role/preexisting"`.
- [x] Create `tests/validation.tftest.hcl`:
  - `run "negative_mode_b_missing_arn"`: `create_role = false`,
    `existing_role_arn = null`. Use `expect_failures = [var.existing_role_arn]`
    to assert the validation block fires.
- [x] Create `tests/naming.tftest.hcl`:
  - `run "long_inputs"`: cluster_name / namespace / service_account chosen
    so the concatenated default name exceeds 64 chars.
    Assertion: the created role's `name` is ≤ 64 chars AND
    deterministic (re-running planning produces the same name).
  - `run "override"`: `role_name_override = "my-custom-name"`.
    Assertion: the role's name equals `"my-custom-name"`.
- [x] Add justfile compatibility check — the existing `just tf test` recipe
      should pick this module up without modification (action-dispatch
      already module-agnostic).
- [x] Run `just tf test eks/pod-identity-access` — all suites green.

#### Success Criteria

- All four `.tftest.hcl` suites pass.
- Total runtime ≤ 5s (plan-only, no apply, no LocalStack).
- Each suite is independent — `run "setup_fixture"` per file is fine; tests
  don't share state across files.
- `expect_failures` correctly catches the validation negative.

---

### Phase 8: terraform test apply-against-LocalStack suite (`tests-localstack/`)

Opt-in apply mode that exercises the AWS API surface — IAM role creation,
trust policy attachment, Pod Identity Association lifecycle. This is the
gap-discovery lane per RFC-0001: anything LocalStack can't apply becomes
backlog for libtftest / sneakystack.

#### Tasks

- [ ] Create `modules/eks/pod-identity-access/tests-localstack/` directory.
- [ ] Create `tests-localstack/fixtures/setup/main.tf` that, in one apply,
      provisions:
  - VPC + subnets (minimal — only enough to satisfy `aws_eks_cluster`).
  - A real `aws_eks_cluster` (LocalStack Pro EKS).
  - S3 bucket holding `${var.region}/eks/${var.cluster_name}/terraform.tfstate`
    with the cluster's real outputs serialized.
- [ ] Create `tests-localstack/apply_localstack.tftest.hcl`:
  - Provider block: comprehensive `endpoints` map pointing at
    `http://localhost:4566` (`s3.localhost.localstack.cloud:4566` for S3
    virtual-hosted-style — mirror the cluster module's working config).
  - `provider_meta` / `provider` settings: `skip_credentials_validation = true`,
    `skip_metadata_api_check = true`, `skip_requesting_account_id = true`,
    `s3_use_path_style = true`.
  - `run "setup"` applies `fixtures/setup`.
  - `run "apply_mode_a"`: full Mode A with 1 managed policy + 1 inline
    policy. Assertions:
    - `aws_iam_role.this[0].arn` is populated.
    - `aws_eks_pod_identity_association.this.association_id` is populated.
    - The association's resolved `role_arn` matches the created role.
  - `run "apply_mode_b"`: pre-create a separate IAM role in the setup
    fixture, pass its ARN as `existing_role_arn`. Assertions:
    - Zero IAM role resources in this run's plan.
    - Association apply succeeds, `association_id` populated.
- [ ] Add justfile compatibility check — `just tf test-localstack
      eks/pod-identity-access` should work module-agnostically.
- [ ] Run `just tf test-localstack eks/pod-identity-access` against a
      running LocalStack Pro container. Capture any LocalStack fidelity gaps
      in a `tests-localstack/FINDINGS.md` (mirror the cluster module's
      pattern from the IMPL-0001 plan-only-vs-apply learnings).
- [ ] If `aws_eks_pod_identity_association` apply fails or behaves
      non-physically in LocalStack, note the gap and skip the run with a
      clear comment (this is exactly the RFC-0001 backlog signal — LocalStack
      gap becomes libtftest/sneakystack work).

#### Success Criteria

- `just tf test-localstack eks/pod-identity-access` either:
  - **passes both Mode A and Mode B end-to-end against LocalStack Pro**, OR
  - **fails with a documented LocalStack-fidelity gap** captured in
    `FINDINGS.md` and the runs commented out (gap-discovery signal — by
    RFC-0001 this is a success, not a failure: the suite has done its job
    of surfacing the gap for sneakystack/libtftest planning).
- Total runtime ≤ 90s end-to-end.
- The `setup` fixture cleans up via `terraform destroy` at suite teardown.
- The suite stays opt-in — plain `terraform test` (no `-test-directory`)
  does not load it.

---

### Phase 9: README, USAGE, and CI plumbing

Final polish — caller-facing docs, README pointer matching the cluster
module's pattern, label / CI verification.

#### Tasks

- [ ] Update `modules/eks/pod-identity-access/README.md` to match the cluster
      module's short-pointer shape, with a 1–2 paragraph blurb + the
      typical Mode A and Mode B usage snippets.
- [ ] Regenerate `USAGE.md` via `terraform-docs .` (terraform-docs is
      configured with `output.mode: inject` writing between
      `<!-- BEGIN_TF_DOCS -->` markers).
- [ ] Verify justfile recipes (`just tf validate`, `just tf fmt`, `just tf
      lint`, `just tf docs`, `just tf test`, `just tf all`) all work
      module-agnostically against `eks/pod-identity-access`.
- [ ] Final pass: confirm zero `kubernetes` / `kubectl` / `helm` provider
      references (ADR-0011 — AWS-API-only Terraform).
- [ ] Final pass: confirm zero aliasing locals that simply re-export
      remote-state outputs (ADR-0001 / CLAUDE.md).

#### Success Criteria

- `just tf all eks/pod-identity-access` passes (validate + lint + fmt +
  test).
- USAGE.md committed and reflects the final input/output contract.
- README example snippets parse-clean (a copy-paste reviewer test).
- No provider drift vs the cluster module's pinned `~> 6.2` and Terraform
  `>= 1.1`.

---

## File Changes

| File                                                                 | Action | Description                                                                              |
| -------------------------------------------------------------------- | ------ | ---------------------------------------------------------------------------------------- |
| `modules/eks/pod-identity-access/main.tf`                            | Create | Remote state data block + `aws_eks_pod_identity_association`.                            |
| `modules/eks/pod-identity-access/iam.tf`                             | Create | Mode A: role, trust policy, managed/customer/inline attachments (all gated).             |
| `modules/eks/pod-identity-access/locals.tf`                          | Create | Deterministic role name with 64-char truncation + hash suffix on overflow.               |
| `modules/eks/pod-identity-access/variables.tf`                       | Create | Full input surface with `validation` block for Mode B requires `existing_role_arn`.      |
| `modules/eks/pod-identity-access/outputs.tf`                         | Create | `role_arn`, `association_id`, `namespace`, `service_account`.                            |
| `modules/eks/pod-identity-access/versions.tf`                        | Create | `hashicorp/aws ~> 6.2`, Terraform `>= 1.1`.                                              |
| `modules/eks/pod-identity-access/README.md`                          | Modify | Short pointer + Mode A and Mode B usage snippets.                                        |
| `modules/eks/pod-identity-access/USAGE.md`                           | Modify | Regenerated by terraform-docs.                                                           |
| `modules/eks/pod-identity-access/.terraform-docs.yml`                | Create | Copied verbatim from cluster module.                                                     |
| `modules/eks/pod-identity-access/.tflint.hcl`                        | Create | Copied verbatim from cluster module.                                                     |
| `modules/eks/pod-identity-access/tests/fixtures/setup/main.tf`       | Create | Stub S3-backend `terraform.tfstate` with cluster outputs for plan-only suite.            |
| `modules/eks/pod-identity-access/tests/mode_a.tftest.hcl`            | Create | Plan-time Mode A shape assertions.                                                       |
| `modules/eks/pod-identity-access/tests/mode_b.tftest.hcl`            | Create | Plan-time Mode B (`existing_role_arn`) shape assertions.                                 |
| `modules/eks/pod-identity-access/tests/validation.tftest.hcl`        | Create | Plan-time `expect_failures` for `create_role = false` + null `existing_role_arn`.        |
| `modules/eks/pod-identity-access/tests/naming.tftest.hcl`            | Create | Plan-time name truncation + override assertions.                                         |
| `modules/eks/pod-identity-access/tests-localstack/fixtures/setup/`   | Create | Real VPC + EKS cluster + S3 state bucket fixture for apply suite.                        |
| `modules/eks/pod-identity-access/tests-localstack/apply_localstack.tftest.hcl` | Create | Opt-in apply-mode suite against LocalStack Pro.                                          |

## Testing Plan

Driven by RFC-0001:

- **Plan-only (`tests/`)** — Mode A shape, Mode B shape, validation negative,
  name truncation. Runtime ≤ 5s. Runs in CI on every PR.
- **Apply-against-LocalStack (`tests-localstack/`)** — Mode A + Mode B full
  apply. Runtime ≤ 90s. Opt-in. Discovery surface: any LocalStack fidelity
  gap on `aws_eks_pod_identity_association` is captured as
  libtftest/sneakystack backlog rather than masked.
- **No libtftest harness in this module** for v1 — the cluster module is the
  fleet's side-by-side reference (per RFC-0001 / CLAUDE.md). Once apply-time
  invariants are identified that LocalStack can't validate, those become
  candidates for the libtftest track.

## Dependencies

- IMPL-0001 (cluster module) — complete. The remote-state contract this
  module reads (`cluster_name`) is in place.
- Decision on Open Questions Q1 (pre-built role bundles) before Phase 4 is
  written — the answer affects whether `variables.tf` grows a
  `well_known_controller` enum input or stays a pure primitive.

No blocking dependencies on IMPL-0003 (addons), IMPL-0002 (managed node
group), or IMPL-0005 (ECR pull-through). This module is independent in
state and can ship in any order relative to the workload modules.

## Open Questions

All resolved 2026-05-15.

### Q1 — DESIGN-0004 Mode B is partly stale; should this module own pre-built role bundles?

**Resolved A + C.** Drop `cluster_module_role_output` from the input
surface entirely (Option A) — Mode B becomes purely "caller passes
`existing_role_arn`" — and ship the five well-known controllers
(cluster-autoscaler, ALB, external-dns, FluentD, CW metrics) as
copy-paste examples in `docs/examples/pod-identity-access/` (Option C).
The module stays a pure primitive matching DESIGN-0004's "small,
single-purpose module" framing. Option B (curated policy bundles)
leaks AWS-side policy churn into the module (AWS LBC's IAM policy
revises with each release) and would require maintenance per AWS
provider major.

**Action.** Phase 1 variable surface drops `cluster_module_role_output`.
DESIGN-0004 needs a supersedes note in a follow-up PR to flag Mode B's
trimmed-back shape. Phase 9 / 10 gains a "create examples directory"
task: `docs/examples/pod-identity-access/{cluster-autoscaler,alb,external-dns,fluentd,cw-metrics}/main.tf`,
each a 10–20-line `module "this" { ... }` block using the existing Mode
A primitives.

### Q2 — Stable input contract for cross-module composition (just `cluster_name`?)

**Resolved A.** Keep the remote-state read for fleet uniformity even
though it's now a one-output read (`cluster_name`). Future-proofs
against this module needing the cluster's `kms_key_arn` or
`cluster_version` later, matches CLAUDE.md's "every consumer takes
`remote_state_bucket` / `region` / `cluster_name`" framing, costs one
extra `data` block at no runtime overhead.

### Q3 — LocalStack fidelity of `aws_eks_pod_identity_association`

**Resolved A — gap-discovery via Phase 8.** Test it; if it works, great;
if it doesn't, capture in `tests-localstack/FINDINGS.md` as
sneakystack / libtftest backlog. The gap-discovery is the explicit
value per RFC-0001 — this brand-new(-ish) AWS resource is the kind of
surface where LocalStack lag is most likely to surface, and that
finding becomes load-bearing input into the sneakystack/libtftest
roadmap.

### Q4 — Association eventual consistency in apply tests

**Resolved A — gap-discovery callout.** Out-of-scope for this module's
LocalStack apply tests (LocalStack isn't running a real Pod Identity
Agent; the propagation window doesn't manifest). The credential-
propagation retry/backoff is a libtftest backlog item: the right place
to validate "association exists → agent vends credentials → workload
SDK consumes them" is a real K8s data plane (kind/k3d) fronted by
sneakystack — captured in `FINDINGS.md` for libtftest planning.

### Q5 — `association_id` output vs `id`

**Resolved A.** Verify the actual `hashicorp/aws ~> 6.2` schema at
Phase 6 time. If only `id` is exposed, `output.association_id =
aws_eks_pod_identity_association.this.id`; if a domain-specific
`association_id` attribute exists, use it. Either way, USAGE.md
reflects the actual output value source. Cheap verification at
implementation time.

### Q6 — Cross-account `target_account_arns` convenience input

**Resolved A.** Stay deferred per DESIGN-0004 "Still open" item. v1
callers compose the `sts:AssumeRole` chain in their inline policy
themselves. Add the convenience input only when a real consumer asks.

## References

- DESIGN-0004 — EKS Pod Identity Access Module (this implementation's
  source of truth; Mode B partly superseded by IMPL-0001, see Q1).
- DESIGN-0002 — EKS Cluster Module (the remote-state contract this module
  reads — `cluster_name`).
- DESIGN-0003 — EKS Addons Module (the addon-managed PIA pattern that is
  the complement of this module's standalone-resource pattern).
- IMPL-0001 — EKS Cluster Module Implementation (Completed; moved the five
  controller roles OUT of the cluster module — drives Q1).
- IMPL-0003 — Addons Module Implementation (sibling work; Pod Identity
  Agent installation, which this module assumes is already running on the
  target cluster).
- RFC-0001 — Module Testing Strategy: `terraform test` baseline + libtftest
  runtime track (drives the two-directory `tests/` + `tests-localstack/`
  test layout in Phases 7 + 8).
- ADR-0001 — Cross-module composition via `terraform_remote_state`.
- ADR-0002 — Node IAM minimization via Pod Identity.
- ADR-0003 — Pod Identity Agent lives on the addons module (Phase 8
  prerequisite assumption).
- ADR-0004 — Addon-managed PIA pattern (boundary clarification: this module
  uses the _standalone_ resource).
- ADR-0011 — Terraform manages AWS API resources only (this module does
  not create the ServiceAccount it binds to).
- ADR-0013 — `terraform test` for plan-time module invariants (Phase 7).
- ADR-0014 — libtftest for apply-time runtime validation without AWS
  (informs Phase 8's gap-discovery framing).
