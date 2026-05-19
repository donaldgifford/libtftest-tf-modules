# LocalStack apply findings — `ecr-pull-through-cache` module

Per [RFC-0001](../../../../docs/rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
§*`terraform test` as the gap-discovery tool*: the `tests-localstack/`
apply suite exists to surface what LocalStack Pro does and doesn't
serve for this module's AWS API surface. Each finding here either
documents a workaround in HCL or files a sneakystack / libtftest
backlog item.

## Environment captured at last run

- LocalStack Pro 2026.5.0 on `:4566`
- Date: 2026-05-15

## Findings

### Finding #1 — IMPL-0005 Phase 9 gap discovery: ECR pull-through cache and ECR repository creation template APIs both return 501

The `apply_localstack.tftest.hcl::apply_mixed` run was authored per
the IMPL-0005 Phase 9 spec but errors on three concrete AWS API
calls when applied against LocalStack Pro 2026.5.0:

- **`CreatePullThroughCacheRule`** (ECR)

  ```text
  Error: creating ECR Pull Through Cache Rule (ecr-public): operation
  error ECR: CreatePullThroughCacheRule, https response error
  StatusCode: 501, api error InternalFailure: The
  create_pull_through_cache_rule action has not been implemented
  ```

  Both upstream rules (`ecr-public` and `docker-hub`) fail
  identically.

- **`CreateRepositoryCreationTemplate`** (ECR)

  ```text
  Error: creating ECR Repository Creation Template (ROOT): operation
  error ECR: CreateRepositoryCreationTemplate, https response error
  StatusCode: 501, api error InternalFailure: The
  create_repository_creation_template action has not been implemented
  ```

These two APIs ARE the module's reason to exist; a partial apply
that skips them is not meaningful. The remaining
`aws_secretsmanager_secret` + `aws_secretsmanager_secret_version` +
`aws_iam_policy` resources would apply cleanly, but the gap is in
the ECR-side surface.

Per IMPL-0005 Phase 9 ("If any apply step 501s in LocalStack,
comment out that block, log the gap in FINDINGS.md, and proceed —
gap-discovery success per RFC-0001"), the apply run block is
preserved as commented-out HCL in
`apply_localstack.tftest.hcl`. Future LocalStack releases that
implement these two APIs can re-enable the apply suite by
uncomment-only.

The active suite is a `plan_smoke` run that exercises plan against
LocalStack — proves the provider endpoint resolution works
(STS GetCallerIdentity reachable, ECR resources validate at plan
time) and the module's plan-time shape matches expectations.

**Filed as sneakystack backlog**: implement
`ecr:CreatePullThroughCacheRule`,
`ecr:CreateRepositoryCreationTemplate`, and the corresponding
describe/delete actions in LocalStack Pro's ECR provider.

### Finding #2 — Secrets Manager and IAM surface for this module is fully covered

Although not exercised end-to-end (because the ECR resources 501
upstream of them in the apply graph), LocalStack Pro 2026.5.0's
Secrets Manager + IAM coverage is widely validated by the cluster,
addons, managed-node-group, and pod-identity-access modules'
`tests-localstack` suites. `aws_secretsmanager_secret`,
`aws_secretsmanager_secret_version`, and `aws_iam_policy` apply
cleanly against LocalStack in those modules.

When LocalStack lands the two ECR APIs from Finding #1, the
pre-existing assertions in the commented `apply_mixed` run will
exercise:

- `aws_secretsmanager_secret.upstream["docker-hub"].arn` populated
- `aws_secretsmanager_secret_version.upstream["docker-hub"].id`
  populated
- `aws_iam_policy.node_pull_through[0].arn` populated
- `output.cache_url_prefixes["docker-hub"]` matches the regional
  ECR URL shape

No separate workaround needed for these — they will pass on
uncomment.

### Out-of-scope of LocalStack apply (libtftest backlog, RFC-0001 §Phase 3)

Per DESIGN-0005 §Testing Strategy: these are real apply-time
invariants the AWS-side test cannot exercise without a real
Kubernetes data plane fronted by sneakystack, regardless of
LocalStack fidelity:

- **`crictl pull` through the cache URL.** The DESIGN's headline
  acceptance criterion is "a node can pull `nginx:1.27` through the
  cache URL". This requires LocalStack ECR to actually proxy to
  real upstream registries — almost certainly never on the
  LocalStack roadmap. Validating cache pull behavior end-to-end
  needs a real EKS cluster fronted by sneakystack.
- **Auto-vivification of pulled-through repositories.** ECR's
  pull-through cache lazily creates `<prefix>/<repo>` on first
  pull. The lifecycle policy from the creation template only
  applies after the auto-created repo exists. This chain (pull →
  repo materializes → template attaches → lifecycle policy active)
  needs LocalStack to first implement the cache rule (Finding #1)
  AND simulate the lazy-create — both gaps.
- **Operator credential rotation.** The placeholder secret bodies
  this module writes (`username = "REPLACE_ME"`) need real Docker
  Hub / GHCR credentials post-apply. ECR only validates the
  credential format on first pull-through attempt — exercising that
  is downstream of Finding #1 and out of scope here.

## Workarounds in HCL (terraform test ergonomics)

This module reads no remote state and no setup fixture — so the
cross-module ergonomics findings from cluster / managed-node-group
/ addons / pod-identity-access don't apply here. The only
ergonomic note:

- **STS GetCallerIdentity must reach a real endpoint at plan
  time.** The plan-only `tests/` files override
  `data.aws_caller_identity.current` to skip the call; the
  `tests-localstack/` file lets LocalStack's STS serve the call
  (real account ID returned, embedded in
  `cache_url_prefixes` + the IAM policy Resource ARN).

## When to re-run

- LocalStack Pro release bumps — re-run to check whether Finding
  #1's two missing APIs have landed.
- Module surface changes — any new ECR / Secrets Manager / IAM
  resource type appearing in this module re-opens the gap-discovery
  question.
- AWS announces backwards-incompatible changes to the ECR
  pull-through cache or creation template APIs — same.
- Before any sneakystack work on this module — Finding #1 is the
  load-bearing question for whether sneakystack can exercise this
  module against LocalStack or needs a real AWS account.
