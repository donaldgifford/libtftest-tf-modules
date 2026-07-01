# LocalStack apply findings — `org-registry` module

Per [RFC-0001](../../../../docs/rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
§*`terraform test` as the gap-discovery tool*: the `tests-localstack/`
apply suite exists to surface what LocalStack Pro does and doesn't
serve for this module's AWS API surface. Each finding here either
documents a workaround in HCL or files a sneakystack / libtftest
backlog item.

## Environment captured at last run

- LocalStack Pro **2026.6.0** on `:4566` (re-probed 2026-07-01;
  first captured on Pro 2026.5.0, 2026-05-20)
- **Re-probe result:** `CreateRepositoryCreationTemplate` **still 501**
  on 2026.6.0 (`InternalFailure: The create_repository_creation_template
  action has not been implemented`). Finding #1 persists; the apply run
  stays commented and the active suite remains `plan_smoke`. The plan-only
  `plan_smoke` passed on 2026.6.0.

## Findings

### Finding #1 — Inherited from IMPL-0005 Phase 9: `CreateRepositoryCreationTemplate` returns 501

Both this module's `aws_ecr_repository_creation_template` resources
(`helm_charts` and `tf_modules`) call ECR's
`CreateRepositoryCreationTemplate` API. IMPL-0005 Phase 9 found this
API returns `501/NotImplemented` on LocalStack Pro 2026.5.0:

```text
Error: creating ECR Repository Creation Template (<prefix>): operation
error ECR: CreateRepositoryCreationTemplate, https response error
StatusCode: 501, api error InternalFailure: The
create_repository_creation_template action has not been implemented
```

The evidence and probe history are captured in
[`modules/ecr/pull-through-cache/tests-localstack/FINDINGS.md`](../../pull-through-cache/tests-localstack/FINDINGS.md)
§Finding #1 — cross-reference rather than duplicate.

These two creation templates ARE the module's reason to exist; a
partial apply that skips them is not meaningful. The remaining
resources (KMS key + alias, IAM role + policy, optional SSM
parameters) would apply cleanly against LocalStack — the gap is in
the ECR-side surface.

Per the established IMPL-0005 Phase 9 pattern, the apply run block is
preserved as commented-out HCL in `apply_localstack.tftest.hcl`.
Future LocalStack releases that implement
`CreateRepositoryCreationTemplate` re-enable the apply suite by
uncomment-only.

The active suite is a `plan_smoke` run that exercises plan against
LocalStack — proves the provider endpoint resolution works
(STS GetCallerIdentity reachable, every resource validates at plan
time against LocalStack's AWS API surface) and the module's
plan-time shape matches expectations.

**Filed as sneakystack backlog**: same upstream issue tracked from
the pull-through-cache module — implement
`ecr:CreateRepositoryCreationTemplate` and the corresponding
describe/delete actions in LocalStack Pro's ECR provider. Closing
that issue closes this finding.

### Finding #2 — Pro-tier auto-detection (Q3): moot for this module by construction

Per the user's fleet-wide testing guidance (IMPL-0006 Q3 / filed as
[INV-0002](../../../../docs/investigation/0002-fleet-wide-localstack-pro-auto-detection-harness-for-tests.md)),
`tests-localstack/` suites should detect LocalStack tier (Pro vs
Community) at invocation time and skip Pro-only test cases when
running against Community.

For THIS module the question is moot:

1. The suite uses `var.organizations_org_id` (required input per
   IMPL-0006 Q2 (a)) instead of `data.aws_organizations_organization` —
   the Pro-only Organizations API is not touched at test time.
2. The ECR `CreateRepositoryCreationTemplate` API returns 501 on
   both LocalStack Pro and Community (Finding #1 is tier-agnostic).
   Both tiers land at the same plan-only smoke surface.

So the suite is **tier-agnostic by construction** — runs identically
against LocalStack Community (free-tier) and LocalStack Pro. The
fleet-wide Pro-detection harness (a `justfile` helper probing
`/_localstack/info`) lives outside this module and is the subject of
INV-0002.

### Finding #3 — KMS, IAM, and SSM surface for this module is fully covered

Although the apply path is blocked at the ECR creation templates
(Finding #1), LocalStack Pro 2026.5.0's KMS, IAM, and SSM coverage
is widely validated by the cluster / addons / managed-node-group /
pod-identity-access modules' `tests-localstack` suites.
`aws_kms_key`, `aws_kms_alias`, `aws_iam_role`,
`aws_iam_role_policy`, `aws_iam_policy`, and `aws_ssm_parameter`
apply cleanly against LocalStack in those modules.

When LocalStack lands the ECR API from Finding #1, the
pre-existing assertions in the commented `apply_default` run will
exercise:

- `aws_kms_key.ecr_oci[0].arn` populated
- `aws_kms_alias.ecr_oci[0].arn` populated
- `aws_iam_role.ecr_template.arn` populated
- `aws_ecr_repository_creation_template.helm_charts.id` populated
- `aws_ecr_repository_creation_template.tf_modules.id` populated
- `aws_iam_policy.oci_publisher.arn` populated

No separate workaround needed for these — they will pass on
uncomment.

### Out-of-scope of LocalStack apply (libtftest / sneakystack backlog, RFC-0001 §Phase 3)

Per DESIGN-0006 §Testing Strategy: these are real apply-time
invariants the AWS-side test cannot exercise without a real
publisher CI environment and downstream consumers, regardless of
LocalStack fidelity:

- **`helm push` through the create-on-push path.** DESIGN-0006's
  headline acceptance criterion is "a CI role pushes
  `helm-charts/billing-api:0.5.0-rc1` and ECR auto-creates the
  repo". This requires LocalStack to first land
  `CreateRepositoryCreationTemplate` (Finding #1) AND simulate the
  CREATE_ON_PUSH `applied_for` mode end-to-end — both gaps.
- **Auto-vivification of `helm-charts/*` / `tf-modules/*` repos.**
  The lifecycle policy and repository policy from the creation
  template only attach after the auto-created repo exists. This
  chain (push → repo materializes → template attaches → policies
  active) needs LocalStack to first implement
  `CreateRepositoryCreationTemplate`.
- **`aws:PrincipalOrgID` enforcement on cross-account pulls.** The
  org-wide pull policy embedded in both templates relies on STS-set
  request context (`aws:PrincipalOrgID`); validating this requires
  a real Organizations identity, out of scope for LocalStack.
- **Cross-account SSM `GetParameter` via resource-based policy.**
  The `ssm_org_read_policy_json` output is meant to be attached
  manually via `aws ssm put-resource-policy` post-apply (provider
  v6 has no `aws_ssm_resource_policy` resource — see IMPL-0006
  Phase 7 schema gap). Validating the cross-account read works
  needs a real second AWS account, out of scope for LocalStack.

## Workarounds in HCL (terraform test ergonomics)

This module reads no remote state and no setup fixture — so the
cross-module ergonomics findings from cluster / managed-node-group
/ addons / pod-identity-access don't apply here. The only ergonomic
notes:

- **STS GetCallerIdentity must reach a real endpoint at plan
  time.** The plan-only `tests/` files override
  `data.aws_caller_identity.current` to skip the call; the
  `tests-localstack/` file lets LocalStack's STS serve the call
  (real account ID returned, embedded in the IAM policy Resource
  ARNs).
- **`var.organizations_org_id` is supplied as a literal** in the
  `tests-localstack/` `variables` block (`o-tftest1234`) so the
  org-wide pull policy condition resolves at plan without invoking
  Organizations.

## When to re-run

- LocalStack Pro release bumps — re-run to check whether Finding
  #1's `CreateRepositoryCreationTemplate` API has landed.
- Module surface changes — any new ECR / KMS / IAM / SSM resource
  type appearing in this module re-opens the gap-discovery question.
- AWS announces backwards-incompatible changes to the ECR repository
  creation template API — same.
- Before any sneakystack work on this module — Finding #1 is the
  load-bearing question for whether sneakystack can exercise this
  module against LocalStack or needs a real AWS account.
