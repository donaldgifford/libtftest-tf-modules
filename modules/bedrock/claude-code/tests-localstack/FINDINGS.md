<!-- markdownlint-disable-file MD025 MD041 MD013 -->
# tests-localstack: Findings

Gap-discovery write-ups for `modules/bedrock/claude-code` per RFC-0001 +
DESIGN-0009 §Testing Strategy and IMPL-0009 Phase 10 (Q9).

This document captures what LocalStack actually serves for the module's
AWS surface, the 501/NotImplemented gaps that surface during
`terraform test` against LocalStack, and the sneakystack backlog items
those gaps warrant.

## Test runs

| File | Run | Command | Coverage |
|------|-----|---------|----------|
| `setup.tftest.hcl` | `setup` | apply | Single stub S3 bucket — proves the LocalStack apply path reaches an available Community service |
| `apply_localstack.tftest.hcl` | `plan_smoke` | plan | Module plans against LocalStack endpoints with a 1-entry models map + `cost_allocation_tag_activation = "none"`: AIP, IAM user/policy, SNS topic, budget, and token alarm all wire at plan time |

Run with `just tf test-localstack bedrock/claude-code`. The recipe wires
`AWS_ENDPOINT_URL=http://localhost:4566` + fake credentials.

One `apply_default` run is preserved as commented HCL in
`apply_localstack.tftest.hcl` (re-enable per "When to re-run" below).

## Tier coverage

- **Verified tier**: LocalStack Community **3.8.1** (probe run on
  2026-06-02, `edition: community`).
- **Pro 2026.x**: not exercised. The current `localstack/localstack:latest`
  (`2026.3.1.dev190`) refuses to boot without a `LOCALSTACK_AUTH_TOKEN`,
  and no Pro license was available in the build environment. Community
  3.8.1 (the version `modules/efs/filesystem` was verified against) was
  pinned for the probe. Re-running this suite against Pro at production
  rollout is the validation step.

## Probe results (2026-06-02, Community 3.8.1)

Each call was issued directly against `http://localhost:4566` with the
`Authorization` header's credential scope naming the target service.

| Service / API | Result | Module resource affected |
|---------------|--------|--------------------------|
| `iam` (CreateUser, CreatePolicy, attach) | available | `aws_iam_user`, `aws_iam_policy`, `aws_iam_user_policy_attachment` |
| `iam:CreateServiceSpecificCredential` | HTTP 200 body `InternalFailure: "create_service_specific_credential action has not been implemented"` | **Go tool** (`bedrock-keyctl mint/rotate/revoke`) — not a module resource, but blocks Part II LocalStack integration testing |
| `sts:GetCallerIdentity` | available | `data.aws_caller_identity.current` |
| `s3` (CreateBucket) | available | fixture stub bucket only |
| `bedrock` (CreateInferenceProfile, `POST /inference-profiles`) | HTTP 500 `InternalError: "Unable to find operation for request to service bedrock"` — service registered, zero operations implemented | `aws_bedrock_inference_profile.this` |
| `budgets:DescribeBudgets` | HTTP 501 `"API for service 'budgets' not yet implemented or pro feature"` | `aws_budgets_budget.this` |
| `ce:ListCostAllocationTags` | HTTP 501 | `aws_ce_cost_allocation_tag.this` |
| `organizations:DescribeOrganization` | HTTP 501 `"API for service 'organizations' not yet implemented or pro feature"` | `data.aws_organizations_organization.current` (the `local`-mode guardrail) |

### Consequences for the suite

- The three load-bearing resources (AIP, Budget, CE cost-allocation
  tag) cannot be applied on Community 3.8.1 — they 500/501 on create.
  The module's reason to exist is those resources, so a partial apply
  is not meaningful. `plan_smoke` (plan-only) is the active signal:
  Bedrock/Budgets/CE resources do not call AWS at plan time, so the
  plan resolves cleanly.
- `data.aws_organizations_organization.current` 501s on read. Because
  the org data source is `count`-gated on `cost_allocation_tag_activation
  == "local"`, `plan_smoke` sets the variable to `"none"` so the data
  source is gated to count 0 and never read. (In `local` mode the plan
  would fail on the org read against Community.)
- `sts:GetCallerIdentity` is available, so `data.aws_caller_identity`
  resolves for real against LocalStack — no override needed in the
  LocalStack suite (unlike the plan-only `tests/` suite, which stubs it
  with `override_data`).

## Sneakystack backlog

Filed per RFC-0001 (one ticket per 501 that blocks an apply path this
module owns):

1. **bedrock control plane** — `CreateInferenceProfile` /
   `GetInferenceProfile` / `ListInferenceProfiles`. Needed to
   re-enable the `apply_default` run for `aws_bedrock_inference_profile`.
2. **budgets** — `CreateBudget` / `DescribeBudgets`. Needed for
   `aws_budgets_budget` apply.
3. **ce (Cost Explorer)** — `UpdateCostAllocationTagsStatus` /
   `ListCostAllocationTags`. Needed for `aws_ce_cost_allocation_tag`
   apply.
4. **organizations** — `DescribeOrganization`. Needed for the
   `local`-mode guardrail data source to resolve under apply.
5. **iam:CreateServiceSpecificCredential** (+ Update/Delete/List) —
   not a module resource, but the `bedrock-keyctl` Go tool's core IAM
   call. Tracked here because Part II's integration testing depends on
   it; until it lands, the Go tool is exercised only against
   hand-rolled mocks (IMPL-0009 Phase 19).

## When to re-run

Re-run `just tf test-localstack bedrock/claude-code` and re-probe the
table above when:

- LocalStack publishes Bedrock control-plane, Budgets, or Cost Explorer
  coverage on Community (watch
  <https://docs.localstack.cloud/references/coverage/>), or
- a Pro license becomes available in the build environment (set
  `LOCALSTACK_AUTH_TOKEN` and re-run against `localstack/localstack-pro`).

When the AIP + Budget + CE APIs land, uncomment the `apply_default` run
in `apply_localstack.tftest.hcl`; when Organizations also lands, switch
that run to `cost_allocation_tag_activation = "local"` against a seeded
org so the guardrail precondition exercises a real management-account
check.
