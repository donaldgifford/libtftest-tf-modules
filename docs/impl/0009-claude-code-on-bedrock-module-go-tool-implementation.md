---
id: IMPL-0009
title: "Claude Code on Bedrock module + Go tool implementation"
status: Draft
author: Donald Gifford
created: 2026-06-01
---
<!-- markdownlint-disable-file MD025 MD041 -->

# IMPL 0009: Claude Code on Bedrock module + Go tool implementation

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-06-01

<!--toc:start-->
- [Objective](#objective)
- [Scope](#scope)
  - [In Scope](#in-scope)
  - [Out of Scope](#out-of-scope)
- [Implementation Phases](#implementation-phases)
  - [Part I — Terraform module (modules/bedrock/claude-code)](#part-i--terraform-module-modulesbedrockclaude-code)
    - [Phase 1: Module scaffolding + variable surface](#phase-1-module-scaffolding--variable-surface)
      - [Tasks](#tasks)
      - [Success Criteria](#success-criteria)
    - [Phase 2: Cost-allocation tag activation (conditional)](#phase-2-cost-allocation-tag-activation-conditional)
      - [Tasks](#tasks-1)
      - [Success Criteria](#success-criteria-1)
    - [Phase 3: IAM user + customer-managed policy](#phase-3-iam-user--customer-managed-policy)
      - [Tasks](#tasks-2)
      - [Success Criteria](#success-criteria-2)
    - [Phase 4: Bedrock application inference profiles (AIPs)](#phase-4-bedrock-application-inference-profiles-aips)
      - [Tasks](#tasks-3)
      - [Success Criteria](#success-criteria-3)
    - [Phase 5: SNS topic + email subscription + optional Slack](#phase-5-sns-topic--email-subscription--optional-slack)
      - [Tasks](#tasks-4)
      - [Success Criteria](#success-criteria-4)
    - [Phase 6: AWS Budgets (tag-filtered)](#phase-6-aws-budgets-tag-filtered)
      - [Tasks](#tasks-5)
      - [Success Criteria](#success-criteria-5)
    - [Phase 7: CloudWatch token-metric alarm](#phase-7-cloudwatch-token-metric-alarm)
      - [Tasks](#tasks-6)
      - [Success Criteria](#success-criteria-6)
    - [Phase 8: Outputs (consumer contract)](#phase-8-outputs-consumer-contract)
      - [Tasks](#tasks-7)
      - [Success Criteria](#success-criteria-7)
    - [Phase 9: terraform test plan-only suite](#phase-9-terraform-test-plan-only-suite)
      - [Tasks](#tasks-8)
      - [Success Criteria](#success-criteria-8)
    - [Phase 10: tests-localstack/ gap-discovery suite](#phase-10-tests-localstack-gap-discovery-suite)
      - [Tasks](#tasks-9)
      - [Success Criteria](#success-criteria-9)
  - [Part II — Go tool (tools/bedrock-keyctl)](#part-ii--go-tool-toolsbedrock-keyctl)
    - [Phase 11: Tool scaffolding + module wiring + interfaces](#phase-11-tool-scaffolding--module-wiring--interfaces)
      - [Tasks](#tasks-10)
      - [Success Criteria](#success-criteria-10)
    - [Phase 12: Secret-sink implementations (Secrets Manager + Vault)](#phase-12-secret-sink-implementations-secrets-manager--vault)
      - [Tasks](#tasks-11)
      - [Success Criteria](#success-criteria-11)
    - [Phase 13: mint subcommand](#phase-13-mint-subcommand)
      - [Tasks](#tasks-12)
      - [Success Criteria](#success-criteria-12)
    - [Phase 14: rotate subcommand](#phase-14-rotate-subcommand)
      - [Tasks](#tasks-13)
      - [Success Criteria](#success-criteria-13)
    - [Phase 15: revoke subcommand](#phase-15-revoke-subcommand)
      - [Tasks](#tasks-14)
      - [Success Criteria](#success-criteria-14)
    - [Phase 16: enable-models — provider dispatch (Path A Anthropic + Path B Amazon)](#phase-16-enable-models--provider-dispatch-path-a-anthropic--path-b-amazon)
      - [Tasks](#tasks-15)
      - [Success Criteria](#success-criteria-15)
    - [Phase 17: enable-models — Path C (third-party Marketplace)](#phase-17-enable-models--path-c-third-party-marketplace)
      - [Tasks](#tasks-16)
      - [Success Criteria](#success-criteria-16)
    - [Phase 18: enable-models — cross-account targeting (--target-accounts)](#phase-18-enable-models--cross-account-targeting---target-accounts)
      - [Tasks](#tasks-17)
      - [Success Criteria](#success-criteria-17)
    - [Phase 19: Go unit tests (mocked interfaces)](#phase-19-go-unit-tests-mocked-interfaces)
      - [Tasks](#tasks-18)
      - [Success Criteria](#success-criteria-18)
  - [Part III — Docs + CI + closeout](#part-iii--docs--ci--closeout)
    - [Phase 20: README, USAGE, IAM contract docs, CLAUDE.md update](#phase-20-readme-usage-iam-contract-docs-claudemd-update)
      - [Tasks](#tasks-19)
      - [Success Criteria](#success-criteria-19)
- [File Changes](#file-changes)
- [Testing Plan](#testing-plan)
- [Dependencies](#dependencies)
- [Open Questions](#open-questions)
  - [Q1 — Terraform module directory placement — RESOLVED (a)](#q1--terraform-module-directory-placement--resolved-a)
  - [Q2 — awsbedrockinference_profile resource schema verification — RESOLVED (a)](#q2--awsbedrockinferenceprofile-resource-schema-verification--resolved-a)
  - [Q3 — Default var.models map shape — RESOLVED (a)](#q3--default-varmodels-map-shape--resolved-a)
  - [Q4 — CloudWatch token-metric alarm dimensions — RESOLVED (a)](#q4--cloudwatch-token-metric-alarm-dimensions--resolved-a)
  - [Q5 — Secrets Manager payload shape — RESOLVED (a)](#q5--secrets-manager-payload-shape--resolved-a)
  - [Q6 — Go module placement under tools/bedrock-keyctl — RESOLVED (a)](#q6--go-module-placement-under-toolsbedrock-keyctl--resolved-a)
  - [Q7 — Vault sink client library — RESOLVED (c)](#q7--vault-sink-client-library--resolved-c)
  - [Q8 — Marketplace subscribe sub-path in Path C — RESOLVED (a)](#q8--marketplace-subscribe-sub-path-in-path-c--resolved-a)
  - [Q9 — tests-localstack/ posture for Bedrock resources — RESOLVED (a)](#q9--tests-localstack-posture-for-bedrock-resources--resolved-a)
  - [Q10 — Slack-delivery sub-variable enforcement — RESOLVED (a)](#q10--slack-delivery-sub-variable-enforcement--resolved-a)
  - [Q11 — mint --expiry-days default — RESOLVED (a)](#q11--mint---expiry-days-default--resolved-a)
  - [Q12 — rotate grace window before deleting the old key — RESOLVED (a)](#q12--rotate-grace-window-before-deleting-the-old-key--resolved-a)
  - [Q13 — enable-models default --target-accounts mode — RESOLVED (a)](#q13--enable-models-default---target-accounts-mode--resolved-a)
  - [Q14 — Sandbox-account integration test in v1? — RESOLVED (out-of-repo manual)](#q14--sandbox-account-integration-test-in-v1--resolved-out-of-repo-manual)
  - [Q15 — bedrock-keyctl release artifact strategy — RESOLVED (a)](#q15--bedrock-keyctl-release-artifact-strategy--resolved-a)
- [References](#references)
<!--toc:end-->

## Objective

Ship the two artifacts defined in [DESIGN-0009](../design/0009-claude-code-on-bedrock-module-tool-and-enablement-contracts.md):

1. **Terraform module** at `modules/bedrock/claude-code/` (subject to Q1) —
   provisions IAM user + customer-managed policy, one Bedrock application
   inference profile (AIP) per entry in `var.models`, SNS topic + email
   (optionally Slack) subscription, tag-filtered AWS Budgets,
   per-AIP CloudWatch token-metric alarm, and conditional cost-allocation
   tag activation. **Provider-agnostic at the Bedrock layer** — same
   resource set works for Anthropic, Amazon, Meta, Mistral, Cohere,
   AI21, Stability, and (best-guess) OpenAI models because the module's
   IAM policy and AIP resources operate on the model/AIP ARN, not the
   provider.
2. **Go tool** `bedrock-keyctl` at `tools/bedrock-keyctl/` — four
   subcommands (`mint`, `rotate`, `revoke`, `enable-models`). `mint` /
   `rotate` / `revoke` manage the IAM service-specific credential for
   `bedrock.amazonaws.com` (the bearer token Claude Code consumes via
   `AWS_BEARER_TOKEN_BEDROCK`); the credential's one-time secret is
   written to a sink (Secrets Manager default, Vault supported) and
   never touches Terraform state. `enable-models` dispatches by
   provider (Path A Anthropic use-case form, Path B Amazon no-op, Path C
   third-party Marketplace) with three cross-account targeting modes
   (`current`, `org-management`, `<account-id-list>`).

**Implements:** [DESIGN-0009](../design/0009-claude-code-on-bedrock-module-tool-and-enablement-contracts.md)
**Drives:** [RFC-0003](../rfc/0003-claude-code-on-bedrock-governed-access-provisioning-and-cost.md)
Phases 1 and 2 (Phase 3 federation is explicit follow-up, not v1).

## Scope

### In Scope

- `modules/bedrock/claude-code/` (per Q1) — full per-account Terraform
  module: IAM user + policy + service-specific credential association
  (the IAM user only; the credential itself is minted out-of-band by
  the Go tool per DESIGN-0009 §2), one `aws_bedrock_inference_profile`
  per `var.models` entry, SNS topic + email subscription, gated Slack
  subscription, `aws_budgets_budget` with 50/80/100% actual + 100%
  forecasted thresholds, per-AIP `aws_cloudwatch_metric_alarm` on
  Bedrock token-count metrics, conditional `aws_ce_cost_allocation_tag`
  activation (`local` mode only — `payer` mode is a separate stack
  documented in README, not a resource set this module owns).
- `tools/bedrock-keyctl/` (per Q6) — Go CLI with four subcommands per
  DESIGN-0009 §2. AWS SDK v2 for IAM + Bedrock + STS + (Path C) AWS
  Marketplace + (cross-account) STS AssumeRole. Sink interface with
  two implementations (AWS Secrets Manager default, HashiCorp Vault
  opt-in). Provider-dispatch logic for `enable-models` covering all
  three paths.
- `terraform test` plan-only suite per ADR-0013 / RFC-0001 + a
  `tests-localstack/` gap-discovery suite per IMPL-0005 Phase 9 pattern
  (Bedrock resource gaps documented, full apply preserved as
  commented HCL for re-enable when LocalStack lands the APIs).
- Go unit tests against mocked interfaces (IAM client, Bedrock client,
  Marketplace client, STS client, sink). Mocks are hand-rolled per the
  Uber style guide and libtftest's interface-first pattern.
- README documenting: required IAM contract per DESIGN-0009 Q9 (the
  three permission scopes — in-account, enablement-principal,
  cross-account), the payer-account component sketch
  (one-time CLI/console activation in the management account when the
  target account is an org member), the canonical `models` map for
  us-west-2 Claude Opus/Sonnet/Haiku per DESIGN-0009 Q5, and the
  AIP-ARN-to-Claude-Code settings.json mapping.

### Out of Scope

- The payer-account component itself (separate stack documented in
  README; not a sub-module). DESIGN-0009 §1 explicitly carves this out.
- OIDC/SSO federation (RFC-0003 Phase 3). v1 is the long-term single
  credential.
- AWS Backup, KMS-encryption-at-rest for the Bedrock model invocations
  themselves (Bedrock service-level concerns; not module scope).
- AWS CloudFormation StackSets for org-growth auto-enablement
  (DESIGN-0009 Q10 — explicit follow-up).
- Bedrock guardrails, provisioned throughput, and model-invocation
  logging design (DESIGN-0009 §Non-Goals).
- A Lambda secret-rotation handler. v1 rotation is operator-triggered
  via `bedrock-keyctl rotate`.
- An end-to-end sandbox-account integration test that mints a key,
  invokes through an AIP, and waits for Cost Explorer to surface the
  tag (~24h). DESIGN-0009 §Testing Strategy lists this as future work;
  flagged as Q14 below.

## Implementation Phases

Each phase builds on the previous one. A phase is complete when all its
tasks are checked off, its success criteria are met, and a conventional
commit has landed.

Quality gates per the donald-loop directive:

- **Terraform phases** (Part I): after each task —
  `just tf fmt bedrock/claude-code`, `just tf lint bedrock/claude-code`,
  `just tf validate bedrock/claude-code`. After each phase that touches
  HCL with a corresponding test, `just tf test bedrock/claude-code`
  must pass.
- **Go phases** (Part II): after each task — `gofmt -s -w`,
  `golangci-lint run`, `go vet ./...`, `go test ./...`. After each
  phase, run `govulncheck ./...` + `go-licenses check ./...` (matches
  the libtftest CI gates carried in this repo per CLAUDE.md §CI
  caveat).
- **Conventional commit per numbered task.** Same per-task commit
  cadence as IMPL-0007 / IMPL-0008.

---

### Part I — Terraform module (`modules/bedrock/claude-code`)

#### Phase 1: Module scaffolding + variable surface

Establish file layout (`main.tf`, `variables.tf`, `versions.tf`,
`locals.tf`, `outputs.tf`, `.tflint.hcl`, `.terraform-docs.yml`,
`README.md` stub) and the full input contract. No resources yet —
just surface area + validations.

##### Tasks

- [x] Create `modules/bedrock/` parent directory; create
      `modules/bedrock/claude-code/` sub-directory (subject to Q1).
- [x] Copy `.terraform-docs.yml` + `.tflint.hcl` verbatim from
      `modules/efs/filesystem/` per the per-module conventions in
      CLAUDE.md.
- [x] Author `versions.tf` pinning `hashicorp/aws ~> 6.2`,
      Terraform `>= 1.1`.
- [x] Author `variables.tf` with the full DESIGN-0009 input contract:
  - Required: `region` (default `"us-west-2"` per DESIGN-0009 Q5
    — has a default, so technically optional; "required-with-default"
    is the recommended posture for region inputs across the fleet);
    `cost_tag` (object with `key` + `value`); `budget_amount` (USD);
    `alert_emails` (list).
  - Required-conditional: `models` (map per DESIGN-0009 §1 sketch —
    typed `map(object({ provider = string, model_id = string }))`).
    See Q3 for default.
  - Optional: `cost_allocation_tag_activation` ∈ `{"local","payer","none"}`,
    default `"local"` per DESIGN-0009 Q1.
  - Optional: `slack_enabled` (default `false` per DESIGN-0009 Q6);
    `slack_delivery` ∈ `{"chatbot","lambda"}`, default `"chatbot"`,
    consumed only when `slack_enabled = true` (see Q10 for
    enforcement strategy); `slack_target` (channel ARN or webhook
    URL — interpretation depends on `slack_delivery`).
  - Optional: `budget_thresholds_percent` (list, default
    `[50, 80, 100]`); `budget_forecast_threshold_percent`
    (default `100`).
  - Optional: `key_expiry_days` (default `90`) — passed-through to
    README/Go-tool documentation only; the module does not mint the
    key.
  - Optional: `tags` (map, default `{}`) — merged into every resource;
    note the cost-allocation tag's key/value flows from `var.cost_tag`
    separately and is *not* merged from `var.tags` (it's a load-bearing
    attribution dimension, not a generic tag).
- [x] Each variable carries `description`, `type`, `default` (optional
      only), `validation` block where shape-constrained, and
      `nullable = false` AFTER `validation` per the custom tflint
      `variable_attribute_order` rule.
- [x] Validation blocks for:
  - `region`: regex `^[a-z]{2}-[a-z]+-[0-9]$`.
  - `cost_allocation_tag_activation`: `contains(["local","payer","none"], var.cost_allocation_tag_activation)`.
  - `slack_delivery`: `contains(["chatbot","lambda"], var.slack_delivery)`.
  - `models`: every value's `provider` is in the eight-element
    allowed set
    `["anthropic","amazon","meta","mistral","cohere","ai21","stability","openai"]`;
    every `model_id` is a non-empty string.
  - `budget_amount`: `> 0`.
  - `budget_thresholds_percent`: each entry in `[1, 100]`.
  - `cost_tag.key`: non-empty, matches `^[A-Za-z][A-Za-z0-9_:-]{0,127}$`
    (AWS tag-key shape — 128 char max, first char alphabetic).
- [x] Stub `main.tf`, `locals.tf`, `outputs.tf` with header comments
      (resources land in Phase 2+).
- [x] Create `modules/bedrock/claude-code/README.md` stub
      (one-line pointer to `USAGE.md`).

##### Success Criteria

- `just tf validate bedrock/claude-code` succeeds.
- `just tf fmt bedrock/claude-code` reports no diffs.
- Custom tflint rules pass (zero `terraform_tautological_naming` /
  `variable_attribute_order` / `resource_parameter_order` violations);
  stock `terraform_unused_declarations` warnings on vars wired in later
  phases are expected.
- `terraform-docs .` renders all inputs into `USAGE.md`.

---

#### Phase 2: Cost-allocation tag activation (conditional)

The `aws_ce_cost_allocation_tag` resource gated on
`cost_allocation_tag_activation == "local"` per DESIGN-0009 §1.
This is Phase 2 (not later) because every downstream resource's tag
set references `var.cost_tag.key` and we want a single failure point
if the tag key is bad.

##### Tasks

- [x] Add `data.aws_caller_identity.current` (used here for the
      future precondition + later by IAM scope) — ADR-0001 carve-out
      for identity-class data sources.
- [x] Add `data.aws_organizations_organization.current` with
      `count = var.cost_allocation_tag_activation == "local" ? 1 : 0`
      — used by the optional precondition guardrail in DESIGN-0009 §1.
      Wrapped in `try()` for the permissive Q7 semantics
      (lookup-failure-treated-as-standalone).
- [x] Create `modules/bedrock/claude-code/cost_allocation.tf`:
  - `aws_ce_cost_allocation_tag.this`:
    - `count = var.cost_allocation_tag_activation == "local" ? 1 : 0`.
    - `tag_key = var.cost_tag.key`.
    - `status = "Active"`.
  - `lifecycle.precondition` on the resource: warns (not blocks) when
    `local` is selected but the caller account doesn't appear to be
    the org management account. Per DESIGN-0009 Q7 — permissive
    interpretation: skip on org-API lookup failure.
- [x] Populate `locals.tf` with `local.account_id =
      data.aws_caller_identity.current.account_id` (Phase 3 IAM
      policy scopes off this) and `local.cost_tag_map = { (var.cost_tag.key) = var.cost_tag.value }`
      (re-used by IAM user tags, AIP tags, Budget filter — single
      source-of-truth for the tag pair).

##### Success Criteria

- `just tf validate bedrock/claude-code` succeeds.
- Test fixture (Phase 9): `cost_allocation_tag_activation = "local"`
  produces 1 `aws_ce_cost_allocation_tag` resource; `"payer"` and
  `"none"` produce 0.
- Permissive precondition: with org lookup failure mocked, plan
  succeeds with a warning.

---

#### Phase 3: IAM user + customer-managed policy

The credential's backing IAM user + the least-privilege policy
attached. Per DESIGN-0009 §1: provider-agnostic at the Bedrock-invoke
layer; scoped to the AIP ARNs this module provisions.

##### Tasks

- [x] Create `modules/bedrock/claude-code/iam.tf`:
  - `aws_iam_user.this`:
    - `name = "${var.identifier_prefix}-claude-code"` (or `var.cost_tag.value`
      if no separate identifier — confirm in Phase 1 var design;
      cleanest is a dedicated `var.user_name` with default null
      → falls back to `"${var.cost_tag.value}-claude-code"`).
    - `tags = merge(var.tags, local.cost_tag_map)` — load-bearing for
      IAM-principal cost allocation per DESIGN-0009 §Background.
  - `data.aws_iam_policy_document.bedrock_invoke`:
    - Statement 1 (`AllowAipInvoke`): actions
      `["bedrock:InvokeModel","bedrock:InvokeModelWithResponseStream","bedrock:GetInferenceProfile"]`;
      resources = the AIP ARNs from `aws_bedrock_inference_profile.this[*].arn`
      (forward reference resolved by Phase 4) **plus** the backing FM
      ARNs from each `var.models[k].model_id` (Bedrock evaluates IAM
      against both the AIP and the wrapped FM at invocation time).
      Effect: `Allow`.
    - Statement 2 (`DenyEverythingElse`, optional gated on
      `var.deny_non_bedrock`, default `true`): NotAction
      `["bedrock:*","sts:GetCallerIdentity"]`; Resource `"*"`;
      Effect: `Deny`. Belt-and-suspenders against the bearer token
      being used as a generic AWS credential — matches the
      RFC-0003 §Proposed Solution claim ("cannot be reused by spawned
      subprocesses for non-Bedrock operations").
  - `aws_iam_policy.bedrock_invoke`:
    - `name = "${aws_iam_user.this.name}-bedrock-invoke"`.
    - `policy = data.aws_iam_policy_document.bedrock_invoke.json`.
    - `tags = merge(var.tags, local.cost_tag_map)`.
  - `aws_iam_user_policy_attachment.this`:
    - `user = aws_iam_user.this.name`.
    - `policy_arn = aws_iam_policy.bedrock_invoke.arn`.
- [x] Add explicit "we do NOT attach `AmazonBedrockLimitedAccess`" note
      as a top-of-file comment in `iam.tf` — DESIGN-0009 §1 calls this
      out as an intentional contrast, and the comment documents *why*
      the absence is deliberate (the only allowed "why" comment per
      CLAUDE.md guidance).
- [x] Add explicit precondition: every `var.models[k].provider` is in
      the eight-provider allowed set (defense in depth alongside the
      Phase 1 variable validation — covers the case where validation
      is silently bypassed by a future provider change).

##### Success Criteria

- `just tf validate bedrock/claude-code` succeeds.
- Test fixture (Phase 9): 3-entry `models` map (one per Claude tier)
  produces 1 IAM user + 1 IAM policy with exactly 6 resource ARNs (3
  AIPs + 3 FMs) in the Allow statement; cost tag appears in user tags.

---

#### Phase 4: Bedrock application inference profiles (AIPs)

One AIP per `var.models` entry. Each carries the cost-allocation tag
set + any user tags. Per DESIGN-0009 §1 + Q5.

##### Tasks

- [x] **Pre-task: Resolve Q2** — verify against `hashicorp/aws ~> 6.2`
      provider schema docs that the resource is named
      `aws_bedrock_inference_profile` with attribute `model_source`
      (or whatever the actual v6 schema uses).
      [Provider docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
      Update Phase 4 tasks once Q2 resolves.
- [x] Create `modules/bedrock/claude-code/inference_profiles.tf`:
  - `aws_bedrock_inference_profile.this`:
    - `for_each = var.models`.
    - `name = each.key`.
    - `model_source { copy_from = each.value.model_id }` (subject to Q2
      schema verification — actual block name may differ).
    - `tags = merge(var.tags, local.cost_tag_map)`.
- [x] Populate `locals.tf` with
      `local.aip_arns = { for k, v in aws_bedrock_inference_profile.this : k => v.arn }`
      — single source for Phase 3 IAM scoping (forward reference at
      use site, no second alias).
- [x] Wire `local.aip_arns` into the Phase 3 IAM policy document's
      Resource list (the forward reference from Phase 3 resolves here).

##### Success Criteria

- `just tf validate bedrock/claude-code` succeeds.
- Test fixture (Phase 9): 3-entry `models` map → 3 AIPs, each with the
  cost-tag pair in `tags`; `local.aip_arns` keyed by the map's logical
  names.

---

#### Phase 5: SNS topic + email subscription + optional Slack

Alerting fan-out per DESIGN-0009 §1. Email is always created; Slack
gated on `var.slack_enabled`.

##### Tasks

- [x] Create `modules/bedrock/claude-code/alerting.tf`:
  - `aws_sns_topic.alerts`:
    - `name = "${aws_iam_user.this.name}-alerts"`.
    - `tags = merge(var.tags, local.cost_tag_map)`.
  - `aws_sns_topic_subscription.email`:
    - `for_each = toset(var.alert_emails)`.
    - `topic_arn = aws_sns_topic.alerts.arn`.
    - `protocol = "email"`.
    - `endpoint = each.value`.
  - `aws_sns_topic_subscription.slack[0]` (count-gated on
    `var.slack_enabled`):
    - `topic_arn = aws_sns_topic.alerts.arn`.
    - `protocol = var.slack_delivery == "lambda" ? "lambda" : "https"`
      (Chatbot fronted by HTTPS endpoint; Lambda relay subscription
      points at a Lambda ARN).
    - `endpoint = var.slack_target`.
    - `lifecycle.precondition` enforcing
      `!var.slack_enabled || var.slack_target != null` (cross-var
      invariant — Q10).

##### Success Criteria

- `just tf validate bedrock/claude-code` succeeds.
- Test fixture (Phase 9): two-entry `alert_emails` list → 2 email
  subscriptions; `slack_enabled = false` (default) → 0 Slack
  subscriptions; `slack_enabled = true, slack_target = "..."` → 1
  Slack subscription.
- Slack precondition negative: `slack_enabled = true,
  slack_target = null` rejected at plan.

---

#### Phase 6: AWS Budgets (tag-filtered)

Budget scoped to the cost-allocation tag per DESIGN-0009 §1. Thresholds
default to 50/80/100% actual + 100% forecasted.

##### Tasks

- [x] Create `modules/bedrock/claude-code/budget.tf`:
  - `aws_budgets_budget.this`:
    - `name = "${aws_iam_user.this.name}-budget"`.
    - `budget_type = "COST"`.
    - `limit_amount = tostring(var.budget_amount)`.
    - `limit_unit = "USD"`.
    - `time_unit = "MONTHLY"`.
    - `cost_filter { name = "TagKeyValue"; values = ["user:${var.cost_tag.key}$${var.cost_tag.value}"] }`
      (AWS CE tag filter uses `user:<key>$<value>` shape for
      user-defined cost-allocation tags).
    - Dynamic `notification` blocks: one per element in
      `var.budget_thresholds_percent` with
      `notification_type = "ACTUAL"`, plus one extra block with
      `notification_type = "FORECASTED"` at
      `var.budget_forecast_threshold_percent`. Each block sets
      `comparison_operator = "GREATER_THAN"`, `threshold_type = "PERCENTAGE"`,
      `subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]`.

##### Success Criteria

- `just tf validate bedrock/claude-code` succeeds.
- Test fixture (Phase 9): default 3-threshold + 1-forecast → 4
  notification blocks; budget `limit_amount` flows from
  `var.budget_amount`; tag filter assembled correctly from
  `var.cost_tag`.

---

#### Phase 7: CloudWatch token-metric alarm

Per-AIP near-real-time signal ahead of budget billing (24h lag) per
DESIGN-0009 §1 + Q3 resolution. One alarm per AIP.

##### Tasks

- [x] Create `modules/bedrock/claude-code/cloudwatch.tf`:
  - `aws_cloudwatch_metric_alarm.token_count`:
    - `for_each = aws_bedrock_inference_profile.this`.
    - `alarm_name = "${aws_iam_user.this.name}-${each.key}-tokens"`.
    - `metric_name` + `namespace` + `dimensions` per Q4 resolution
      (token-count metric on `AWS/Bedrock` namespace, AIP-keyed
      dimension).
    - `statistic = "Sum"`.
    - `period = 300`, `evaluation_periods = 1` (single 5-minute
      bucket; intentionally aggressive — earlier signal beats false
      positives at this stage).
    - `threshold = var.token_alarm_threshold` (new var; default per
      Q4 follow-up — likely a per-AIP-per-period token count that
      maps loosely to "1/4 of the daily budget at $X/Mtok burn").
    - `comparison_operator = "GreaterThanThreshold"`.
    - `alarm_actions = [aws_sns_topic.alerts.arn]`.
    - `tags = merge(var.tags, local.cost_tag_map)`.

##### Success Criteria

- `just tf validate bedrock/claude-code` succeeds.
- Test fixture (Phase 9): 3-AIP map → 3 alarms; each alarm's
  dimension references the corresponding AIP's name / ARN.

---

#### Phase 8: Outputs (consumer contract)

Stable surface; renaming or removing an output breaks downstream
remote-state consumers (notably the future developer-onboarding stack
that reads `aip_arns` and writes Claude Code's settings.json per
DESIGN-0009 §Related Work).

##### Tasks

- [x] Author `modules/bedrock/claude-code/outputs.tf`:
  - `iam_user_name` — for the Go tool's `--user` flag.
  - `iam_user_arn` — IAM-principal cost allocation pivot.
  - `aip_arns` — map keyed by `var.models` logical name → AIP ARN.
    The load-bearing output: developer-onboarding stack reads this
    to populate `ANTHROPIC_MODEL` / `ANTHROPIC_SMALL_FAST_MODEL`.
  - `sns_topic_arn` — for future consumers wanting to add their own
    subscriber type.
  - `budget_name` — for cross-stack budget refs.
  - `cost_tag_key` / `cost_tag_value` — passthroughs for the
    payer-account component to activate (when
    `cost_allocation_tag_activation = "payer"`, the operator runs
    `aws ce update-cost-allocation-tags-status` in the management
    account using these values; README documents the recipe).
- [x] Explicitly **NO `bedrock_api_key`-style output.** DESIGN-0009 §1:
      "Deliberately no credential output — the secret is never produced
      by Terraform." Add a top-of-file `outputs.tf` comment documenting
      this absence with a pointer to the Go tool.
- [x] Re-run `terraform-docs .` to render outputs into `USAGE.md`.

##### Success Criteria

- `just tf validate bedrock/claude-code` succeeds.
- Every output has a `description`.
- `USAGE.md` regenerated cleanly.
- Grep `outputs.tf` returns zero hits for `bedrock_api_key`, `secret`,
  `credential` — the "no credentials in TF state" invariant.

---

#### Phase 9: `terraform test` plan-only suite

Per ADR-0013 + RFC-0001, the plan-only suite is the baseline. No
LocalStack required; runs in seconds. Mirrors the structure used in
IMPL-0007 / IMPL-0008.

##### Tasks

- [x] Create `modules/bedrock/claude-code/tests/` directory.
- [x] Author `tests/default.tftest.hcl`:
  - Default inputs (us-west-2, empty `models` map per Q3
    recommendation, default thresholds).
  - Asserts: 1 IAM user + 1 IAM policy + 1 attachment + 1 SNS topic +
    0 email subscriptions (var defaults to empty) + 0 Slack +
    0 AIPs + 0 alarms + 1 budget + 1 cost-allocation tag
    (`local` mode default).
  - `override_data` stubs for
    `data.aws_caller_identity.current` (account_id) and
    `data.aws_organizations_organization.current` (id, master_account_id).
- [x] Author `tests/models_map.tftest.hcl`:
  - 3-entry `models` map covering Anthropic Claude Opus/Sonnet/Haiku.
  - Asserts: 3 AIPs, 3 alarms, IAM policy Resource list has 6 ARNs
    (3 AIPs + 3 FMs), AIP names match map keys.
- [x] Author `tests/multi_provider.tftest.hcl`:
  - 4-entry `models` map: anthropic.opus + amazon.nova +
    meta.llama + openai.gpt55 (per DESIGN-0009 Q5 — Day-1
    multi-provider).
  - Asserts: 4 AIPs (provider-agnostic creation); cost tags applied
    uniformly.
- [x] Author `tests/cost_allocation_modes.tftest.hcl`:
  - 3 runs: `local` (default — 1 tag resource), `payer` (0 tag
    resources), `none` (0 tag resources).
- [x] Author `tests/slack.tftest.hcl`:
  - 4 runs: default (no Slack); `slack_enabled = true,
    slack_delivery = "chatbot", slack_target = "https://..."` (1
    Slack sub with `protocol = "https"`); `slack_enabled = true,
    slack_delivery = "lambda", slack_target = "arn:...lambda:..."`
    (1 Slack sub with `protocol = "lambda"`); negative — Slack
    precondition (Q10): `slack_enabled = true, slack_target = null`
    rejected at plan.
- [x] Author `tests/budget.tftest.hcl`:
  - Default thresholds → 3 actual + 1 forecasted notification blocks.
  - Custom thresholds `[25, 75]` + forecast `90` → 2 actual + 1
    forecasted blocks.
- [x] Author `tests/validation.tftest.hcl` with `expect_failures` on:
  - `var.region = "invalid-region"`.
  - `var.cost_allocation_tag_activation = "wrong"`.
  - `var.slack_delivery = "teams"`.
  - `var.models = { x = { provider = "nonexistent", model_id = "..." } }`
    (provider validation negative).
  - `var.budget_amount = 0`.
  - `var.budget_thresholds_percent = [150]`.
  - `var.cost_tag.key = ""`.
- [x] All test files supply `override_data` for both data sources to
      avoid real AWS lookups before var validation fires (IMPL-0007
      Phase 9 lesson).

##### Success Criteria

- `just tf test bedrock/claude-code` passes all runs.
- Total wall-clock time < 5 seconds.

---

#### Phase 10: `tests-localstack/` gap-discovery suite

Per IMPL-0005 Phase 9 fall-back pattern: Bedrock resources are likely
501 on LocalStack Pro 2026.5.0 (Bedrock is an opaque managed service
with no obvious LocalStack mock surface). Author the suite with
commented apply blocks and an active `plan_smoke` run; document
findings.

##### Tasks

- [x] Create `modules/bedrock/claude-code/tests-localstack/` directory.
- [x] Author `tests-localstack/setup.tftest.hcl` building the fixture:
  - S3 bucket for stub state (unused for this module — Bedrock is
    fleet-shared, no upstream remote-state reads needed) — actually
    the simplest possible fixture; no VPC, no cluster, no other
    state.
- [x] Author `tests-localstack/apply_localstack.tftest.hcl`:
  - `plan_smoke` run (active): plans the module against LocalStack
    endpoints with a 1-entry `models` map. Verifies provider endpoint
    resolution + plan-time validation only.
  - `apply_default` run (commented per IMPL-0005 Phase 9 pattern):
    full module apply against LocalStack. Re-enable when LocalStack
    lands `aws_bedrock_inference_profile` + AWS Budgets +
    cost-allocation tag activation.
- [x] Author `tests-localstack/FINDINGS.md` documenting the gaps —
      per the IMPL-0005 / IMPL-0006 / IMPL-0008 pattern. Specifically
      capture:
  - LocalStack Pro tier verification (does Pro 2026.5.0 stub Bedrock
    at all, or only Community-no-op?).
  - `aws_bedrock_inference_profile` status (likely 501).
  - `aws_ce_cost_allocation_tag` status (potentially supported per CE
    APIs in LocalStack; verify).
  - `aws_budgets_budget` status.
  - IAM service-specific credential for `bedrock.amazonaws.com`
    status — this is the one the Go tool exercises; module doesn't
    create it but the LocalStack gap is relevant to Part II's
    integration testing.

##### Success Criteria

- `just tf test-localstack bedrock/claude-code` passes the
  `plan_smoke` run.
- FINDINGS.md committed with concrete LocalStack 2026.5.0 test
  results (not just "is likely 501" — actually run it).
- Sneakystack backlog filed for any 501s discovered.

---

### Part II — Go tool (`tools/bedrock-keyctl`)

#### Phase 11: Tool scaffolding + module wiring + interfaces

Establish the Go module + interface surface that the four subcommands
share. Mock-friendly per DESIGN-0009 §2 (Uber-style minimal-dependency,
SDK v2, interfaces around IAM/Bedrock/sink).

##### Tasks

- [x] Create `tools/bedrock-keyctl/` directory.
- [x] Run `go mod init` per Q6 resolution (module path TBD on Q6
      resolution).
- [x] Add dependencies (constrain to AWS SDK v2 + minimal others —
      target ≤ 5 direct deps per Uber-style minimalism):
  - `github.com/aws/aws-sdk-go-v2/...` (config, credentials/stscreds,
    service/iam, service/bedrock, service/bedrockruntime,
    service/secretsmanager, service/marketplacecatalog, service/sts).
  - `github.com/spf13/cobra` for CLI scaffolding (consistency with
    other Go CLIs in the donaldgifford-tooling space — `docz`,
    `forge`).
  - **No** `github.com/hashicorp/vault/api` in v1 per Q7
    resolution (c) — Vault sink deferred to v1.1.
- [x] Author the interface surface at `tools/bedrock-keyctl/internal/awsapi/`:
  - `IAMClient` — `CreateServiceSpecificCredential`,
    `UpdateServiceSpecificCredential`, `DeleteServiceSpecificCredential`,
    `ListServiceSpecificCredentials`.
  - `BedrockClient` — `PutUseCaseForModelAccess`, `InvokeModel`
    (the no-op for Path C invocation-trigger), `GetInferenceProfile`.
  - `MarketplaceClient` — `Subscribe`, `DescribeSubscriptions`
    (Q8 may collapse these).
  - `STSClient` — `AssumeRole`, `GetCallerIdentity`.
- [x] Author `tools/bedrock-keyctl/internal/sink/`:
  - `Sink` interface with `Write(ctx, key, payload []byte) error`
    + `Read(ctx, key) ([]byte, error)` + `Delete(ctx, key) error`.
  - Phase 12 ships the two implementations.
- [x] Author `tools/bedrock-keyctl/cmd/root.go` with cobra root command
      + global flags (`--region`, `--log-level`, `--dry-run`).
- [x] Add `tools/bedrock-keyctl/main.go` with the cobra Execute
      bootstrap.

##### Success Criteria

- `go build ./tools/bedrock-keyctl/...` succeeds.
- `golangci-lint run ./tools/bedrock-keyctl/...` clean (subject to
  Q6 — config inheritance from root `.golangci.yml` may need
  per-tool override).
- `go test ./tools/bedrock-keyctl/...` runs (zero tests yet — passes
  trivially).

---

#### Phase 12: Secret-sink implementation (Secrets Manager only)

Per Q7 resolution (c): v1 ships Secrets Manager only; Vault sink
deferred to v1.1. The `Sink` interface stays generic so the second
implementation lands without a rewrite — only a new file +
`ParseURI` wiring.

##### Tasks

- [x] Author `tools/bedrock-keyctl/internal/sink/secretsmanager.go`:
  - `SecretsManagerSink` implementing `Sink`.
  - `Write`: `CreateSecret` on first write, `PutSecretValue`
    on subsequent (the SM API for value rotation; `UpdateSecret`
    is for metadata).
  - Payload shape per Q5 resolution (a): JSON envelope
    `{"bedrock_api_key": "<token>", "credential_id": "<id>", "expires_at": "<iso8601>"}`.
  - Backed by the SDK v2 `secretsmanager.Client`.
- [x] Author `tools/bedrock-keyctl/internal/sink/parse.go`:
  - `ParseURI(uri string) (Sink, key string, err error)` — accepts
    `sm://<secret-name>` only in v1; explicitly rejects `vault://`
    with the message "Vault sink not yet implemented (deferred to
    v1.1); use sm://." Per Q7 resolution (c).
  - Unit test: parse a fixed set of valid + invalid URIs including
    the `vault://` rejection case.
- [x] Add `tools/bedrock-keyctl/internal/sink/sink_test.go` with
      table-driven tests using a mock AWS SecretsManager client.

##### Success Criteria

- `go test ./tools/bedrock-keyctl/internal/sink/...` passes.
- Round-trip test: write → read → delete cycle works against the
  mocked SM client.
- `ParseURI` rejects `vault://` with the deferral message and
  rejects unsupported schemes with a clear error including the
  v1-supported set (`sm://` only).

---

#### Phase 13: `mint` subcommand

Per DESIGN-0009 §2: calls `iam.CreateServiceSpecificCredential` with
`ServiceName=bedrock.amazonaws.com`, captures the one-time
`ServiceApiKeyValue`, writes to the sink. Never prints the secret.

##### Tasks

- [x] Author `tools/bedrock-keyctl/cmd/mint.go`:
  - Flags: `--user <name>` (required), `--expiry-days <int>`
    (default per Q11), `--sink <uri>` (required).
  - Behavior:
    1. Parse `--sink` via `sink.ParseURI`.
    2. Call `IAMClient.CreateServiceSpecificCredential` with
       `ServiceName = "bedrock.amazonaws.com"`,
       `CredentialAgeDays = <expiry-days>`.
    3. Capture `ServiceApiKeyValue` from response (one-time
       visible).
    4. Build the payload per Q5; call `sink.Write`.
    5. Print credential ID + expiry to stdout. **Never print
       `ServiceApiKeyValue`.**
- [ ] Assertion in test suite (Phase 19): grep stdout for any 40+
      char base64-ish string and fail loudly. Belt-and-suspenders
      against future log-statement regressions.

##### Success Criteria

- `bedrock-keyctl mint --user X --expiry-days 90 --sink sm://test`
  against mocked IAM + SM:
  - Calls `CreateServiceSpecificCredential` once with the right
    `ServiceName`.
  - Writes exactly once to the sink.
  - Stdout contains credential ID + expiry; does NOT contain the
    secret.

---

#### Phase 14: `rotate` subcommand

Two-key allowance per DESIGN-0009 §2: mint new key → verify test
invocation → deactivate old → delete old after grace window.
Zero-downtime contract.

##### Tasks

- [ ] Author `tools/bedrock-keyctl/cmd/rotate.go`:
  - Flags: `--user <name>` (required), `--expiry-days <int>`
    (default per Q11), `--sink <uri>` (required),
    `--grace-period <duration>` (default per Q12 — Go duration
    string like `"5m"`).
  - Behavior:
    1. `ListServiceSpecificCredentials` on the user → find the
       active Bedrock credential ID.
    2. `CreateServiceSpecificCredential` → capture new secret.
    3. Write new secret to sink (overwrites).
    4. Verify new credential: `BedrockClient.GetInferenceProfile`
       call using the new token (proves the credential is active).
    5. `UpdateServiceSpecificCredential(Status=Inactive)` on the
       old.
    6. Sleep for `--grace-period` (allows long-lived Claude Code
       sessions to pick up the new secret from the sink on next
       refresh).
    7. `DeleteServiceSpecificCredential` on the old.
  - **Failure semantics:** if step 4 fails (verification), delete
    the NEW credential and leave the old one Active. If step 5+
    fail, the new credential is active and the old is still
    Active — operator runs `rotate` again or `revoke --credential-id`.
- [ ] Test: simulate step-4 failure → assert new credential is
      deleted, old is still Active in the mocked IAM state.

##### Success Criteria

- Happy path: new key minted, verified, written to sink; old key
  deactivated then deleted. Mock asserts exact sequence of IAM
  calls.
- Verification-failure path: new credential cleaned up, old still
  Active.
- `--grace-period 0` short-circuits the sleep (for tests; document
  this in `--help`).

---

#### Phase 15: `revoke` subcommand

Targeted deactivate + delete of a specific credential. Per DESIGN-0009
§2.

##### Tasks

- [ ] Author `tools/bedrock-keyctl/cmd/revoke.go`:
  - Flags: `--user <name>` (required),
    `--credential-id <id>` (required), `--sink <uri>` (optional —
    when set, deletes the secret from the sink AFTER the credential
    is deleted from IAM).
  - Behavior:
    1. `UpdateServiceSpecificCredential(Status=Inactive)` on the
       credential.
    2. `DeleteServiceSpecificCredential`.
    3. If `--sink` provided: `sink.Delete`. (Order matters — IAM
       first ensures no in-flight invocation succeeds against a
       sink-only-deleted key.)
- [ ] Add `--force` flag for skipping confirmation when run
      non-interactively (CI / scripts).

##### Success Criteria

- Mocked IAM: exact sequence inactive→delete→sink-delete on a
  3-step happy path.
- `--sink` omitted → 2-step IAM-only revoke; no sink call.

---

#### Phase 16: `enable-models` — provider dispatch (Path A Anthropic + Path B Amazon)

The dispatch routing per DESIGN-0009 §3. Path A submits the use-case
form; Path B is a no-op printing "no action needed."

##### Tasks

- [ ] Author `tools/bedrock-keyctl/cmd/enable_models.go`:
  - Flags: `--models <list>` (required — comma-separated
    `<provider>.<model_id>` pairs OR JSON file path via `@file.json`),
    `--target-accounts <mode>` (default per Q13).
  - Parse `--models` into `[]ModelSpec{provider, model_id}`.
  - For `--target-accounts = current`: dispatch each model to its
    provider path. Phase 17 + 18 add Path C + the cross-account
    modes.
- [ ] Author `tools/bedrock-keyctl/internal/enablement/anthropic.go`:
  - `EnableAnthropic(ctx, BedrockClient, model_id) Result` —
    calls `PutUseCaseForModelAccess` with the standard form payload
    (use-case description, company name, intended-use field — see
    Q-not-included note: the form's required fields are SDK-defined,
    not a Q here. The IMPL author hardcodes a sensible
    "internal Claude Code usage" payload; operators override via
    `--use-case-payload @file.json` in v1.1).
  - Idempotent: catch `AlreadyExists`-style errors and return
    `Outcome=NoActionNeeded`.
- [ ] Author `tools/bedrock-keyctl/internal/enablement/amazon.go`:
  - `EnableAmazon(ctx, model_id) Result` — returns
    `Outcome=NoActionNeeded` with the message "Amazon models
    auto-enabled in all commercial regions; no action required."
- [ ] Add result-table printing: model | provider | action |
      outcome. Tab-aligned for readability.

##### Success Criteria

- Mocked Bedrock client:
  - Anthropic dispatch: `PutUseCaseForModelAccess` called once per
    model.
  - Amazon dispatch: zero AWS calls; "no action" row printed.
  - Idempotency: re-invocation with same models produces
    `Outcome=NoActionNeeded` for Anthropic too.

---

#### Phase 17: `enable-models` — Path C (third-party Marketplace)

Per DESIGN-0009 §3 Path C — six providers: Meta, Mistral, Cohere,
AI21, Stability, OpenAI*. Two sub-paths per Q8: explicit
`aws-marketplace:Subscribe` OR no-op `bedrock:InvokeModel` to
auto-trigger.

##### Tasks

- [ ] Author `tools/bedrock-keyctl/internal/enablement/marketplace.go`:
  - `EnableMarketplace(ctx, MarketplaceClient, BedrockClient, model_id) Result`
    — Q8 resolution determines call sequence:
    1. If Q8.a (explicit subscribe): `MarketplaceClient.Subscribe`
       (or equivalent — confirm against `aws-marketplace`
       SDK v2 surface) on the model's catalog product ID.
    2. If Q8.b (invocation-trigger): no-op
       `BedrockClient.InvokeModel` with a 1-byte input designed to
       trigger auto-subscribe without consuming meaningful tokens.
       (Document the unavoidable ~1 token cost; v1 acceptable.)
  - Idempotency: catch `AlreadySubscribed`-style errors → return
    `Outcome=NoActionNeeded`.
- [ ] Wire Path C into the Phase 16 dispatch table for the six
      provider keys.
- [ ] Add `--marketplace-subscribe-path explicit|invocation` global
      flag that overrides Q8's default for operators who need to
      flip it without rebuilding.

##### Success Criteria

- Mocked Marketplace + Bedrock clients:
  - 6-provider test sweep: each provider routes to Path C.
  - Idempotency: re-running with already-subscribed models →
    `NoActionNeeded`.

---

#### Phase 18: `enable-models` — cross-account targeting (`--target-accounts`)

Per DESIGN-0009 §3 cross-account matrix. Three modes:
`current` (Phase 16/17 default), `org-management` (Anthropic cascade,
warnings for non-Anthropic), `<account-id-list>` (AssumeRole loop).

##### Tasks

- [ ] Author `tools/bedrock-keyctl/internal/targeting/targeting.go`:
  - `ResolveTargets(ctx, STSClient, mode string) ([]Target, error)`:
    - `mode = "current"` → one Target: this account's credentials,
      no AssumeRole.
    - `mode = "org-management"` → one Target: this account
      (assumed to already be management — printed warning if not),
      with metadata flagging "Anthropic-only-cascades."
    - `mode = "<comma-list-of-account-ids>"` → N Targets, each
      with `AssumeRole(arn:aws:iam::<acct>:role/<--assume-role-name>)`.
  - `--assume-role-name` flag default `"bedrock-enablement"` per
    DESIGN-0009 §2.
- [ ] Update Phase 16/17 dispatch to iterate over Targets, swapping
      the client constructor's credentials per Target.
- [ ] Path C + `--target-accounts = org-management` → print a
      WARNING row in the result table per DESIGN-0009 §3 matrix
      ("third-party providers don't cascade — use account-id-list").
- [ ] Add idempotency-check optimization: for `<account-id-list>`,
      query Marketplace `DescribeSubscriptions` per account first
      and skip already-subscribed models.

##### Success Criteria

- Mocked STS + multi-account test fixture:
  - `current` → 0 AssumeRole calls.
  - `org-management` → 0 AssumeRole calls + correct cascade-only-Anthropic
    warning for non-Anthropic providers.
  - `<account-id-list>` → N AssumeRole calls, each followed by
    per-target dispatch.

---

#### Phase 19: Go unit tests (mocked interfaces)

Comprehensive test coverage across the four subcommands + dispatch
paths. Target: >80% per the CI quality gate, no exceptions for the
secret-handling paths.

##### Tasks

- [ ] Author `tools/bedrock-keyctl/internal/awsapi/mock_iam.go` —
      mock `IAMClient` with in-memory credential state.
- [ ] Author `tools/bedrock-keyctl/internal/awsapi/mock_bedrock.go` —
      mock `BedrockClient` recording PutUseCaseForModelAccess calls
      + serving Invoke + GetInferenceProfile.
- [ ] Author `tools/bedrock-keyctl/internal/awsapi/mock_marketplace.go`
      — mock `MarketplaceClient`.
- [ ] Author `tools/bedrock-keyctl/internal/awsapi/mock_sts.go` —
      mock `STSClient` returning a configured AssumeRole envelope.
- [ ] Author `tools/bedrock-keyctl/internal/sink/mock_sink.go` —
      in-memory `Sink` for cross-cutting sink behavior assertions.
- [ ] Cover the secret-never-logged invariant: a test that wraps
      stdout/stderr and asserts no key value ever appears.
- [ ] Cover the `rotate` zero-downtime contract: assert the exact
      IAM call sequence under happy path AND under
      verification-failure path.
- [ ] Cover all three `--target-accounts` modes with the
      multi-account fixture.

##### Success Criteria

- `go test -cover ./tools/bedrock-keyctl/...` reports ≥80%
  coverage across all packages.
- `govulncheck ./...` clean.
- `go-licenses check ./...` clean.

---

### Part III — Docs + CI + closeout

#### Phase 20: README, USAGE, IAM contract docs, CLAUDE.md update

##### Tasks

- [ ] Author `modules/bedrock/claude-code/README.md`:
  - Two-paragraph overview + RFC/DESIGN/IMPL links.
  - Quickstart instantiation (us-west-2, Claude Opus/Sonnet/Haiku
    via DESIGN-0009 Q5's canonical AIP setup).
  - Multi-provider example: anthropic + amazon + meta in one
    `models` map.
  - IAM contract section (DESIGN-0009 Q9): three permission scopes
    spelled out — in-account, enablement-principal, cross-account.
    Pin Path-A vs Path-B vs Path-C IAM permission deltas explicitly.
  - "Cost-allocation tag activation" section walking the three
    modes (`local` / `payer` / `none`) and exactly what command
    to run in the management account for `payer` mode (since the
    module itself doesn't ship that resource).
  - Slack delivery section: when to pick Chatbot vs Lambda;
    region-availability caveat.
  - Operational gotchas: ~24h Cost Explorer lag, AIP version sprawl
    behavior, Marketplace Subscribe permission requirement for first
    invocation.
  - "Destroying this module" warning — IAM credentials should be
    revoked first via `bedrock-keyctl revoke` to avoid orphaned
    bearer tokens.
- [ ] Author `tools/bedrock-keyctl/README.md`:
  - Build + install instructions (`go install ./...`).
  - Subcommand reference (mint / rotate / revoke / enable-models)
    with the canonical invocations from DESIGN-0009 §2.
  - Cross-account setup recipe: the `bedrock-enablement` role's
    trust policy + permissions per provider mix.
  - Sink configuration: SM URI format only in v1 (Vault deferred
    to v1.1 per Q7); the secret payload shape per Q5 (JSON envelope).
  - **Manual sandbox-account verification recipe** per Q14: operator
    steps to mint a short-expiry key in a sandbox account, invoke
    once through an AIP, and confirm the cost-allocation tag
    surfaces in Cost Explorer after ~24h. This recipe lives in
    the README only — explicitly NOT a Phase / CI job per Q14.
- [ ] Regenerate `modules/bedrock/claude-code/USAGE.md` via
      `just tf docs bedrock/claude-code`.
- [ ] Update `docs/impl/README.md` (docz auto-updates).
- [ ] Update root `CLAUDE.md`:
  - Add `modules/bedrock/claude-code` to the §Repository purpose
    module inventory.
  - Add a `modules/bedrock/claude-code` shape section per the
    existing pattern (cluster, addons, ecr, rds-serverless,
    efs-filesystem).
  - Add `tools/bedrock-keyctl` as a new top-level entry under a
    new §Tooling sub-section (since this is the repo's first
    in-tree Go CLI under `tools/`).
- [ ] Run `just docs lint` — ensure new docs pass markdownlint with
      zero findings on new files (pre-existing findings on IMPL-0007
      / 0008 are not in scope).

##### Success Criteria

- All READMEs render correctly.
- `USAGE.md` is current.
- `CLAUDE.md` updated.
- `just docs lint` clean for IMPL-0009, README, USAGE files added
  in this implementation.
- IMPL-0009 marked Completed in frontmatter + docz regenerates
  README index.

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `modules/bedrock/claude-code/main.tf` | Create | Module root with provider-agnostic resources |
| `modules/bedrock/claude-code/variables.tf` | Create | Full input contract |
| `modules/bedrock/claude-code/versions.tf` | Create | `aws ~> 6.2`, terraform `>= 1.1` |
| `modules/bedrock/claude-code/locals.tf` | Create | `account_id`, `cost_tag_map`, `aip_arns` |
| `modules/bedrock/claude-code/outputs.tf` | Create | Consumer contract (no secrets) |
| `modules/bedrock/claude-code/cost_allocation.tf` | Create | Conditional tag activation |
| `modules/bedrock/claude-code/iam.tf` | Create | User + customer-managed policy + attachment |
| `modules/bedrock/claude-code/inference_profiles.tf` | Create | AIPs (for_each over `var.models`) |
| `modules/bedrock/claude-code/alerting.tf` | Create | SNS + email + gated Slack |
| `modules/bedrock/claude-code/budget.tf` | Create | Budget + tag filter + notifications |
| `modules/bedrock/claude-code/cloudwatch.tf` | Create | Per-AIP token-count alarms |
| `modules/bedrock/claude-code/.terraform-docs.yml` | Create | Per-module terraform-docs config (copied) |
| `modules/bedrock/claude-code/.tflint.hcl` | Create | Per-module tflint config (copied) |
| `modules/bedrock/claude-code/README.md` | Create | Module README + IAM contract |
| `modules/bedrock/claude-code/USAGE.md` | Create | terraform-docs-generated |
| `modules/bedrock/claude-code/tests/*.tftest.hcl` | Create | Plan-only test suite |
| `modules/bedrock/claude-code/tests-localstack/*.tftest.hcl` | Create | Gap-discovery suite |
| `modules/bedrock/claude-code/tests-localstack/FINDINGS.md` | Create | LocalStack gap analysis |
| `tools/bedrock-keyctl/go.mod` | Create | Go module (path subject to Q6) |
| `tools/bedrock-keyctl/main.go` | Create | Cobra Execute bootstrap |
| `tools/bedrock-keyctl/cmd/*.go` | Create | root, mint, rotate, revoke, enable_models |
| `tools/bedrock-keyctl/internal/awsapi/*.go` | Create | IAM/Bedrock/Marketplace/STS interfaces + mocks |
| `tools/bedrock-keyctl/internal/sink/*.go` | Create | Sink interface + SM impl (Vault deferred to v1.1 per Q7) |
| `tools/bedrock-keyctl/internal/enablement/*.go` | Create | Anthropic / Amazon / Marketplace dispatch |
| `tools/bedrock-keyctl/internal/targeting/*.go` | Create | Cross-account target resolution |
| `tools/bedrock-keyctl/README.md` | Create | CLI reference + cross-account setup |
| `CLAUDE.md` | Modify | Add module + tool inventory entries |
| `docs/impl/README.md` | Modify | docz regen |
| `docs/impl/0009-claude-code-on-bedrock-module-go-tool-implementation.md` | Modify | Status → Completed at end |

## Testing Plan

- **Plan-only `terraform test`** per ADR-0013: covers IAM shape, AIP
  cardinality, alerting subscriptions, budget thresholds + tag filter,
  CloudWatch alarm cardinality, Slack precondition, validation negatives,
  cost-allocation activation modes.
- **`tests-localstack/` gap-discovery suite** per IMPL-0005 Phase 9
  pattern: `plan_smoke` active; full apply commented for re-enable when
  LocalStack supports Bedrock + Budgets + CE tag activation. Document
  gaps in `FINDINGS.md` and file sneakystack backlog items.
- **Go unit tests** against mocked IAM / Bedrock / Marketplace / STS /
  Sink interfaces. Target ≥80% coverage. Key invariants tested:
  - Secret never appears in stdout/stderr (regression-proof against
    future log additions).
  - `rotate` zero-downtime contract (sequence + failure rollback).
  - All three `--target-accounts` modes route correctly.
  - Path A / B / C dispatch covers all eight providers exactly once
    per model spec.
- **Sandbox-account end-to-end** (Q14): out of scope for this repo
  entirely. Operator runs the manual recipe (documented in the tool
  README) against the sandbox environment after v1 ships; NOT in CI,
  NOT a Phase 21 here. Anything more durable lives in a separate
  integration-test harness outside this monorepo.

## Dependencies

- [DESIGN-0009](../design/0009-claude-code-on-bedrock-module-tool-and-enablement-contracts.md)
  — the source contract.
- [RFC-0003](../rfc/0003-claude-code-on-bedrock-governed-access-provisioning-and-cost.md)
  — the parent decision.
- AWS provider `hashicorp/aws ~> 6.2` (existing fleet pin).
- AWS SDK v2 — IAM, Bedrock, BedrockRuntime, SecretsManager, STS,
  MarketplaceCatalog services.
- `github.com/spf13/cobra` for CLI scaffolding.
- (Deferred to v1.1 per Q7 resolution (c)) `github.com/hashicorp/vault/api`
  — Vault sink ships in a follow-up IMPL, not v1.
- mise-pinned tools: golangci-lint, govulncheck, go-licenses (already
  in `mise.toml` per the libtftest-shaped CI carryover).

## Open Questions

All fifteen resolved 2026-06-01 (operator answers
`1a 2a 3a 4a 5a 6a 7c 8a 9a 10a 11a 12a 13a 14-out-of-repo 15a`).
Resolutions folded into the §Implementation Phases above.

---

### Q1 — Terraform module directory placement — RESOLVED (a)

**Resolved:** module lives at `modules/bedrock/claude-code/`.
Establishes a new `modules/bedrock/` top-level service directory
matching the `modules/eks` / `modules/ecr` / `modules/rds` /
`modules/efs` pattern. Leaves room for siblings like
`modules/bedrock/guardrails/` or `modules/bedrock/logging-bucket/`
if more Bedrock surface area lands.

Where does the Terraform module live in the modules tree?

- **(a) `modules/bedrock/claude-code/`** — recommended. Establishes a
  new `modules/bedrock/` top-level service directory (matches the
  `modules/eks/` / `modules/ecr/` / `modules/rds/` / `modules/efs/`
  pattern: AWS service as top-level, role/purpose as sub-directory).
  Leaves room for siblings like `modules/bedrock/guardrails/` or
  `modules/bedrock/logging-bucket/` if future Bedrock surface area
  lands in the repo. Reads naturally in `just tf <action>
  bedrock/claude-code`.
- (b) `modules/bedrock-claude-code/` — flat, no top-level Bedrock
  service. Smaller blast radius today but loses the multi-module-
  service pattern the fleet already uses.
- (c) `modules/ai/claude-code/` — abstract over the cloud service
  ("AI" not "Bedrock"). Loses the AWS-API-surface-as-directory
  invariant.
- (d) `modules/claude-code/` (no Bedrock implied) — vague; collides
  with non-Bedrock Claude Code consumers (e.g. direct Anthropic API,
  if that ever lands here).
- (other) ___

### Q2 — `aws_bedrock_inference_profile` resource schema verification — RESOLVED (a)

**Resolved:** Phase 4 begins with a pre-task that verifies the exact
resource name + block shape against `hashicorp/aws ~> 6.2` provider
docs before authoring the AIP HCL. If v6.2 lacks the resource,
escalate to Q2.b (`null_resource` + `local-exec` fallback) — not
to a provider-version bump (the fleet pin is `~> 6.2`).

DESIGN-0009 §1 names the resource `aws_bedrock_inference_profile` with
attribute `model_source`. The actual `hashicorp/aws ~> 6.2` provider
may use a different name or block shape (e.g., `aws_bedrockagent_*`
namespace, or `model_source { copy_from = "..." }` block vs scalar
`model_source = "..."`).

- **(a) Verify against `hashicorp/aws ~> 6.2` provider docs before
  Phase 4** — recommended. Update the Phase 4 task list with the
  exact resource name + block shape once verified. If the resource is
  absent from v6.2, escalate (Q2.b) before Phase 4 starts.
- (b) Ship a `null_resource` + `local-exec` AWS CLI wrapper as a
  fallback if the v6.2 provider lacks the resource. Last resort —
  loses Terraform state management for the AIPs but unblocks v1.
- (c) Pin to a newer provider version (e.g., `~> 6.5+`) if v6.2
  predates the AIP resource. Conflicts with the fleet-wide `~> 6.2`
  pin; would need fleet-wide bump.
- (d) Use the `awscc/aws_bedrock_application_inference_profile`
  (CloudControl) provider as a parallel provider. Adds a provider
  dependency; not on the paved road.
- (other) ___

### Q3 — Default `var.models` map shape — RESOLVED (a)

**Resolved:** `var.models` defaults to `{}` (empty map). The
canonical us-west-2 Claude Opus/Sonnet/Haiku triple is documented
in README as the copy-paste starting point per DESIGN-0009 Q5.
Empty-default posture matches the defensive pattern used
elsewhere (e.g., `var.access_points = {}` in EFS) — no
surprise IAM scope or AIP creation on first apply.

DESIGN-0009 Q5 lists us-west-2 + Claude Opus/Sonnet/Haiku as the
canonical v1 default. Should the module ship with these three
entries pre-populated as the default value of `var.models`?

- **(a) Default to `{}` (empty map); document the canonical
  three-entry map in README** — recommended. A Day-1 empty map gives
  a cleaner default (no surprise IAM scope, no surprise AIP creation
  on first apply). Consumers copy-paste from README. Matches the
  defensive-default posture used elsewhere (e.g.,
  `var.access_points = {}` in EFS).
- (b) Pre-populate with the three Claude tiers — friendlier
  first-apply experience but couples the module's default to
  specific Bedrock model ARNs that may rotate (model IDs include
  date strings).
- (c) Pre-populate with cross-region inference profile IDs (e.g.,
  `us.anthropic.claude-3-opus-20240229-v1:0`) — region-agnostic but
  still couples to model versions.
- (d) Reject empty `models` map at variable validation (force the
  operator to supply something). Loses the "instantiate-as-default"
  smoke-test path.
- (other) ___

### Q4 — CloudWatch token-metric alarm dimensions — RESOLVED (a)

**Resolved:** per-AIP via `inferenceProfileArn` dimension on the
`AWS/Bedrock` namespace. Gives the finest-grained signal and
matches the per-AIP cost attribution story. Phase 7 verifies the
actual CloudWatch metric AWS emits for AIPs before authoring;
if `inferenceProfileArn` isn't a valid dimension, file as a Phase 7
follow-up (the metric still ships; dimension scope just degrades).

DESIGN-0009 §1 + Q3 ship the alarm in v1 but doesn't pin the metric
dimensions. Per-AIP attribution requires a dimension that scopes the
metric to a specific inference profile.

- **(a) Per-AIP via `inferenceProfileArn` dimension on
  `AWS/Bedrock`** — recommended IF the metric supports it. Gives the
  finest-grained signal and matches the per-AIP cost attribution
  story. Requires verifying the actual CloudWatch metric AWS emits
  for AIPs.
- (b) Account-wide via no dimension — coarsest signal, simplest;
  loses per-AIP visibility (which is the whole point of per-AIP
  AIPs).
- (c) Per-FM-ARN via `modelId` dimension — emits a signal at the
  foundation-model layer but loses the AIP→tag attribution link.
- (d) Drop the CloudWatch alarm from v1 entirely (revisit DESIGN-0009
  Q3 resolution) — closes the billing-lag gap differently; we lose
  the early signal.
- (other) ___

### Q5 — Secrets Manager payload shape — RESOLVED (a)

**Resolved:** JSON envelope —
`{"bedrock_api_key": "<token>", "credential_id": "<id>", "expires_at": "<iso8601>"}`.
Single SM secret carries the token + rotation metadata co-located
so `rotate` doesn't need a parallel state store. Phase 12's
`secretsmanager.go` implements this shape; the consumer (Claude
Code via `AWS_BEARER_TOKEN_BEDROCK`) reads only the
`bedrock_api_key` field — the env-resolving step is the operator's
responsibility per README.

DESIGN-0009 §Data Model implies `vault://secret/.../user` with the
secret value as the bearer token. SM has the same value+name shape
but adds a per-secret JSON convention for storing structured data.

- **(a) JSON envelope:
  `{"bedrock_api_key": "<token>", "credential_id": "<id>", "expires_at": "<iso8601>"}`**
  — recommended. Single SM secret carries token + metadata co-located
  so the rotation job doesn't need a parallel state store.
- (b) Plain string (the token only); metadata stored separately in a
  sibling SM secret or in IAM tags on the credential — pure but
  requires two SM reads per rotation.
- (c) JSON envelope plus IAM credential-tag mirror — both stores; over-engineered for v1.
- (d) AWS-managed rotation metadata only (use Secrets Manager's
  native version tracking) — loses the operator-visible
  expires_at without extra API calls.
- (other) ___

### Q6 — Go module placement under `tools/bedrock-keyctl` — RESOLVED (a)

**Resolved:** separate `go.mod` at `tools/bedrock-keyctl/go.mod`
with module path
`github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl`.
Tools-directory convention; isolates the tool's dependency graph
from the libtftest test code at `modules/eks/cluster/test/`.
Enables independent release cadence per Q15.

DESIGN-0009 Q8 placed the tool at `tools/bedrock-keyctl/`. The Go
module path + `go.mod` layout has its own decision space.

- **(a) Separate `go.mod` at `tools/bedrock-keyctl/go.mod`, module
  path `github.com/donaldgifford/libtftest-tf-modules/tools/bedrock-keyctl`**
  — recommended. Tools-directory convention (matches Kubernetes /
  many large Go monorepos: each tool is its own module). Keeps the
  tool's dependency graph isolated from the libtftest test code at
  `modules/eks/cluster/test/`. Enables independent vendoring +
  release cadence per Q15.
- (b) Share `go.mod` with the existing libtftest test code at the
  repo root or under `modules/eks/cluster/test/go.mod` — couples the
  tool's dependency upgrades to the test harness's.
- (c) New root `go.mod` shared across all future Go tooling — anticipates
  the per-module versioning Go CLI from INV-0003's sibling RFC, but
  prematurely couples two unrelated tools.
- (d) Go workspaces (`go.work` at the repo root) — pure best-of-both;
  adds workspace tooling overhead that the libtftest harness doesn't
  currently use.
- (other) ___

### Q7 — Vault sink client library — RESOLVED (c)

**Resolved:** Vault sink **deferred to v1.1**. Phase 12 ships
Secrets Manager only; `sink.ParseURI` explicitly rejects `vault://`
with the deferral message ("Vault sink not yet implemented
(deferred to v1.1); use sm://."). Reduces v1 scope; `Sink` interface
stays generic so the Vault implementation lands without a rewrite.
The `vault/api` library decision is itself deferred to the v1.1
IMPL.

DESIGN-0009 §2 lists Vault as a supported sink (Secrets Manager is
the documented default per Q2). If we ship the Vault sink in v1, which
client library?

- **(a) `github.com/hashicorp/vault/api`** — recommended. Official
  client, AWS SDK v2-style ergonomics, KV v2 path-aware.
- (b) HTTP direct (`net/http` + token in `X-Vault-Token` header) —
  zero dependency but every KV v2 nuance reimplemented (lease, TTL,
  CAS, response envelope shape).
- (c) Defer Vault sink to v1.1 — Phase 12 ships SM only;
  `sink.ParseURI` rejects `vault://` with "Vault sink not yet
  implemented; use sm://." Reduces v1 scope.
- (d) `github.com/hashicorp/vault-client-go` (newer, code-generated
  client) — modern but smaller community; less battle-tested.
- (other) ___

### Q8 — Marketplace subscribe sub-path in Path C — RESOLVED (a)

**Resolved:** try explicit `aws-marketplace:Subscribe` first; fall
back to no-op `bedrock:InvokeModel` if the API rejects
non-listing-context calls. `--marketplace-subscribe-path` flag
overrides per-invocation (default `auto`; alternatives `explicit`
/ `invocation`). Phase 17 implements the dispatch + fallback logic.

DESIGN-0009 §3 Path C notes the v1 ship-time choice between (a)
explicit `aws-marketplace:Subscribe` call and (b) no-op
`bedrock:InvokeModel` to trigger auto-enable. Catalog state at
ship time decides which.

- **(a) Try (a) explicit subscribe via `aws-marketplace:Subscribe`
  first; fall back to (b) invocation-trigger if the API rejects
  non-listing-context calls** — recommended. Operator-deterministic
  outcome on the happy path; graceful degradation if AWS hasn't
  exposed a callable subscribe API for Bedrock catalog entries.
  `--marketplace-subscribe-path` flag overrides per-invocation.
- (b) Always (b) invocation-trigger — guaranteed to work (auto-enable
  is a hard contract per AWS docs) but adds ~1 token cost per
  enablement run. Acceptable for v1.
- (c) Always (a) explicit subscribe — bet that the API exists for
  Bedrock catalog entries; fail loud if not. Cleaner if it works.
- (d) Ship Path C as a manual prerequisite (no automation) — operator
  invokes the model once by hand to trigger auto-enable. Loses the
  fleet-wide pattern's value.
- (other) ___

### Q9 — `tests-localstack/` posture for Bedrock resources — RESOLVED (a)

**Resolved:** Plan-only-active + commented apply per IMPL-0005
Phase 9 pattern. `tests-localstack/setup.tftest.hcl` builds the
fixture; `apply_localstack.tftest.hcl` runs an active `plan_smoke`
alongside a commented `apply_default` (re-enable when LocalStack
lands the Bedrock APIs). `FINDINGS.md` documents each 501 with
concrete LocalStack 2026.5.0 verification; sneakystack backlog
items filed per 501.

LocalStack Pro 2026.5.0's coverage of Bedrock is unknown. The previous
five modules followed IMPL-0005's Phase 9 fall-back pattern when
LocalStack 501'd on key resources.

- **(a) Plan-only-active + commented apply (IMPL-0005 Phase 9
  pattern); document gaps in FINDINGS.md; file sneakystack backlog
  items per 501** — recommended. Battle-tested pattern across five
  prior modules; preserves the apply path for re-enable when
  LocalStack lands the APIs.
- (b) Skip `tests-localstack/` entirely for v1 — Bedrock is so
  service-managed that LocalStack support is plausibly far away;
  saves the FINDINGS.md authoring effort.
- (c) Run a `setup.tftest.hcl` against LocalStack but skip the module
  apply — proves provider endpoint resolution only; the weakest of
  the three options.
- (d) Use a Bedrock-stubbing sidecar (`sneakystack` or similar) to
  back the LocalStack endpoint with hand-rolled responses — defers
  the entire `tests-localstack` to a future IMPL.
- (other) ___

### Q10 — Slack-delivery sub-variable enforcement — RESOLVED (a)

**Resolved:** `lifecycle.precondition` on the Slack subscription
resource itself enforces the cross-variable invariant
`slack_enabled = true → slack_target != null`. Matches the
EFS / RDS / EKS-cluster pattern for cross-variable invariants
that Terraform 1.1 `variable.validation` can't express. Phase 5
authors the precondition; Phase 9 covers the negative path.

DESIGN-0009 Q6 ships Slack as opt-in via `var.slack_enabled`. The
cross-variable invariant `slack_enabled = true → slack_target != null`
needs an enforcement point — terraform 1.1 `variable.validation` can't
reference other vars.

- **(a) `lifecycle.precondition` on the Slack subscription resource
  itself** — recommended. Catches the misconfiguration at plan time
  on the resource that needs the target; matches the EFS / RDS
  pattern for cross-variable invariants.
- (b) Module-level `validation` (terraform 1.9+) — fleet pins to
  `>= 1.1`; would require bumping the fleet floor or carrying a
  version-conditional validation.
- (c) Silent ignore (just don't create the Slack subscription if
  target is null) — loses the loud-failure signal.
- (d) Compile-time via `terraform init` failure (impossible in v1.1
  but mention as the "ideal" alternative).
- (other) ___

### Q11 — `mint --expiry-days` default — RESOLVED (a)

**Resolved:** 90 days. Matches the DESIGN-0009 §2 example and
RFC-0003's "short expiry + rotation" prose. Long enough that
operators don't drown in rotation; short enough that a leak's
blast-radius window is bounded.

DESIGN-0009 §2 example shows `--expiry-days 90`. Per RFC-0003's
"short expiry + rotation" risk mitigation.

- **(a) 90 days** — recommended. Matches the DESIGN example + RFC
  prose. Long enough that operators don't drown in rotation; short
  enough that a leak's blast-radius window is bounded.
- (b) 60 days — slightly more aggressive; matches some compliance
  frameworks (PCI-DSS 90-day rotation, hardened to 60).
- (c) 30 days — most aggressive; pairs well with a scheduled rotation
  job (RFC-0003 Phase 3 backlog) but is operator-friction-heavy at v1.
- (d) Operator-required (no default) — forces the operator to think
  about expiry. Adds friction; doesn't pair well with the "default to
  the happy path" posture across other modules.
- (other) ___

### Q12 — `rotate` grace window before deleting the old key — RESOLVED (a)

**Resolved:** 5-minute default for `--grace-period`. Long enough
for any in-flight session refresh; short enough that the rotation
completes within a typical scheduled job's 15-minute window. Phase
14 wires the `--grace-period` flag with Go duration parsing;
`0` short-circuits the sleep for tests (documented in `--help`).

DESIGN-0009 §2 specifies "delete it after a grace window" without
naming the duration. Long-lived Claude Code sessions read the secret
periodically from the sink.

- **(a) `5m` default** — recommended. Long enough for any in-flight
  session refresh; short enough that the rotation completes within a
  scheduled job's typical 15-minute window. CLI flag
  `--grace-period`.
- (b) `15m` default — extra-safe; risks the rotation window stretching
  across an hourly cron boundary.
- (c) `0` default (immediate delete) — zero downtime contract relies
  on sinks being consulted at every invocation, which is not
  Claude Code's pattern (it caches the env-var-resolved token for the
  session lifetime). Risks active sessions failing.
- (d) Configurable per `--grace-period`, no default (force operator to
  set) — adds friction without much safety gain over (a).
- (other) ___

### Q13 — `enable-models` default `--target-accounts` mode — RESOLVED (a)

**Resolved:** default is `current`. Single-account is the v1 happy
path per DESIGN-0009 Q1 / Q4. `current` reads naturally as "do it
here." Phase 16 wires the default; Phase 18 implements `org-management`
and `<account-id-list>` modes.

When the operator runs `bedrock-keyctl enable-models --models ...`
without `--target-accounts`, what's the default?

- **(a) `current`** — recommended. Single-account is the v1 happy
  path per DESIGN-0009 Q1 / Q4. `--target-accounts=current` reads
  naturally as "do it here."
- (b) `org-management` — only safe when the tool runs from the
  management account; surprise blast radius if defaulted in a member
  account.
- (c) No default (require explicit `--target-accounts`) — forces the
  operator to think about scope. Adds friction.
- (d) Auto-detect: read `aws_caller_identity` + `aws_organizations` to
  infer (`current` if not management, `org-management` if
  management). Magic behavior; surprising.
- (other) ___

### Q14 — Sandbox-account integration test in v1? — RESOLVED (out-of-repo manual)

**Resolved:** out of scope for this repo and for CI entirely.
The sandbox-account end-to-end (mint → invoke → confirm Cost
Explorer tag) is run **manually by an operator against the
sandbox environment first**, NOT as a CI job in this repo and
NOT shipped as a Phase 21 task here. The tool's README documents
the manual recipe (steps to mint a short-expiry key, invoke via
an AIP, and verify Cost Explorer surfaces the cost-allocation
tag after ~24h). Anything more durable than the manual recipe
lives outside this repo (e.g., a dedicated sandbox-tests repo,
or wherever the org's integration-test harness lives) — explicitly
not this monorepo's scope.

DESIGN-0009 §Testing Strategy lists a sandbox-account end-to-end
(mint → invoke → wait for Cost Explorer tag) as a step. Real AWS
spend + ~24h Cost Explorer lag.

- **(a) Out of scope for v1; file as IMPL-0009.1 follow-up** —
  recommended. Cost + latency make this a poor fit for the per-task
  iteration loop. Document the manual recipe in the tool README so
  an operator can run it once after v1 ships.
- (b) Include as Phase 21, gated behind an explicit `RUN_E2E=1` env
  var — runs only when an operator opts in. CI never runs it.
- (c) Include as Phase 21, with a scheduled nightly CI job that
  mints a short-expiry key in a dedicated sandbox account — most
  thorough but adds CI infrastructure work.
- (d) Skip permanently; rely on plan-only + Go unit tests — loses the
  one signal that proves the full RFC-0003 success criteria
  (cost-allocation tags actually showing up in Cost Explorer).
- (other) ___

### Q15 — `bedrock-keyctl` release artifact strategy — RESOLVED (a)

**Resolved:** defer binary releases to a follow-up IMPL once
INV-0003's sibling RFC lands the CI overhaul. v1 is
`go install ./...` only — anyone with Go installed can build the
binary. Aligns the binary-release decision with the broader
per-module versioning Go CLI's release pipeline so we don't
duplicate goreleaser config (per CLAUDE.md §CI caveat:
inherited goreleaser config is stale and being rewritten).

The libtftest CI carryover (per CLAUDE.md §CI caveat) suggests
goreleaser was contemplated. Does `bedrock-keyctl` ship binaries?

- **(a) Defer binary releases to a follow-up IMPL once INV-0003's
  sibling RFC lands CI overhaul** — recommended. v1 is
  `go install ./...` only (anyone with Go installed can build it).
  Aligns the binary-release decision with the broader per-module
  versioning Go CLI's release pipeline so we don't duplicate
  goreleaser config.
- (b) Ship binaries via goreleaser per-tag (resurrect the inherited
  goreleaser config for this specific tool only) — gets the artifact
  to operators without Go installed.
- (c) Ship a container image via the org's ECR (`modules/ecr/org-registry`)
  — eats our own dog food; needs a CI pipeline to publish to.
- (d) Hybrid: `go install` for developers + goreleaser binaries for
  operators — most flexible, most pipeline work.
- (other) ___

## References

- [DESIGN-0009](../design/0009-claude-code-on-bedrock-module-tool-and-enablement-contracts.md)
  — module, tool, and enablement contracts
- [RFC-0003](../rfc/0003-claude-code-on-bedrock-governed-access-provisioning-and-cost.md)
  — Claude Code on Bedrock: governed access, provisioning, cost tracking
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md)
  — cross-module composition via remote state (the output contract
  for `aip_arns` follows this pattern)
- [ADR-0013](../adr/0013-use-terraform-test-for-plan-time-module-invariants.md)
  — `terraform test` as plan-only baseline
- [ADR-0014](../adr/0014-use-libtftest-for-apply-time-runtime-validation-without-aws.md)
  — libtftest as apply-time runtime validation
- [RFC-0001](../rfc/0001-module-testing-strategy-terraform-test-as-baseline-libtftest.md)
  — module testing strategy
- [INV-0003](../investigation/0003-cicd-options-for-a-terraform-modules-monorepo.md)
  — CI/CD direction; the per-module versioning Go CLI sibling RFC
  (Q15)
- IMPL-0005 Phase 9 fall-back pattern — LocalStack gap-discovery
  template (Q9)
- AWS docs: `aws_bedrock_inference_profile`, `aws_budgets_budget`,
  `aws_ce_cost_allocation_tag`, `aws_cloudwatch_metric_alarm`,
  IAM service-specific credentials for `bedrock.amazonaws.com`
