---
id: DESIGN-0009
title: "Claude Code on Bedrock module, tool, and enablement contracts"
status: Draft
author: Donald Gifford
created: 2026-05-31
---
<!-- markdownlint-disable-file MD025 MD041 -->

# DESIGN 0009: Claude Code on Bedrock module, tool, and enablement contracts

**Status:** Draft
**Author:** Donald Gifford
**Date:** 2026-05-31

<!--toc:start-->
- [Overview](#overview)
- [Goals and Non-Goals](#goals-and-non-goals)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
- [Background](#background)
- [Detailed Design](#detailed-design)
  - [1. Terraform module (bedrock-claude-code)](#1-terraform-module-bedrock-claude-code)
    - [Member-account resources](#member-account-resources)
    - [Cost-allocation tag activation (conditional)](#cost-allocation-tag-activation-conditional)
    - [Payer-account component (separate state/stack, used when activation = payer)](#payer-account-component-separate-statestack-used-when-activation--payer)
  - [2. Go tool (bedrock-keyctl — working name)](#2-go-tool-bedrock-keyctl--working-name)
    - [Subcommands](#subcommands)
  - [3. Prerequisite: per-provider model access enablement](#3-prerequisite-per-provider-model-access-enablement)
    - [Common ground (post Sept/Oct 2025)](#common-ground-post-septoct-2025)
    - [Path A: Anthropic (use-case form)](#path-a-anthropic-use-case-form)
    - [Path B: Amazon (no-op)](#path-b-amazon-no-op)
    - [Path C: Third-party Marketplace providers (Meta / Mistral / Cohere / AI21 / Stability / OpenAI*)](#path-c-third-party-marketplace-providers-meta--mistral--cohere--ai21--stability--openai)
    - [Cross-account targeting (orthogonal to provider dispatch)](#cross-account-targeting-orthogonal-to-provider-dispatch)
    - [First-invocation Marketplace auto-enable note](#first-invocation-marketplace-auto-enable-note)
- [API / Interface Changes](#api--interface-changes)
- [Data Model](#data-model)
- [Testing Strategy](#testing-strategy)
- [Migration / Rollout Plan](#migration--rollout-plan)
- [Open Questions](#open-questions)
  - [Q1 — Dedicated account vs shared? — RESOLVED (single-account default)](#q1--dedicated-account-vs-shared--resolved-single-account-default)
  - [Q2 — Vault or Secrets Manager as the canonical sink? — RESOLVED (Secrets Manager)](#q2--vault-or-secrets-manager-as-the-canonical-sink--resolved-secrets-manager)
  - [Q3 — CloudWatch token-metric alarm in v1 or later? — RESOLVED (yes, v1)](#q3--cloudwatch-token-metric-alarm-in-v1-or-later--resolved-yes-v1)
  - [Q4 — Per-developer vs single shared credential? — RESOLVED (single credential for v1)](#q4--per-developer-vs-single-shared-credential--resolved-single-credential-for-v1)
  - [Q5 — Region + model matrix — RESOLVED (us-west-2 + Claude Opus/Sonnet/Haiku in v1; multi-provider support in tool from Day 1)](#q5--region--model-matrix--resolved-us-west-2--claude-opussonnethaiku-in-v1-multi-provider-support-in-tool-from-day-1)
  - [Q6 — SNS → Slack delivery mechanism — RESOLVED (optional, off by default)](#q6--sns--slack-delivery-mechanism--resolved-optional-off-by-default)
  - [Q7 — Tag-activation precondition: skip-on-org-data-failure semantics — RESOLVED (a)](#q7--tag-activation-precondition-skip-on-org-data-failure-semantics--resolved-a)
  - [Q8 — bedrock-keyctl Go module location — RESOLVED (b, sibling under tools/)](#q8--bedrock-keyctl-go-module-location--resolved-b-sibling-under-tools)
  - [Q9 — Cross-account role provisioning — RESOLVED (out of module scope; document IAM contract only)](#q9--cross-account-role-provisioning--resolved-out-of-module-scope-document-iam-contract-only)
  - [Q10 — Org-mode form re-submission semantics — RESOLVED (defer; document StackSet path as future work)](#q10--org-mode-form-re-submission-semantics--resolved-defer-document-stackset-path-as-future-work)
- [Related Work](#related-work)
- [References](#references)
<!--toc:end-->

## Overview

Implementation contracts for [RFC-0003](../rfc/0003-claude-code-on-bedrock-governed-access-provisioning-and-cost.md):
the Terraform module that provisions the declarative footprint, the Go tool
that mints/rotates the Bedrock credential and submits the Anthropic use-case
form, and the current state of model-access enablement (the prerequisite).
This document defines interfaces and responsibilities, not the code itself.

## Goals and Non-Goals

### Goals

- Define the Terraform module's inputs, outputs, and resource set.
- Define the Go tool's CLI surface, the AWS APIs it calls, and where it writes.
- Capture the *current* (post Sept/Oct 2025) model-access reality and the
  exact automation path for the one remaining manual step.
- Make the split between "declarative in Terraform" and "imperative in the Go
  tool" explicit and justified.
- **Multi-provider model support.** Bedrock hosts foundation models from
  multiple providers (Anthropic, Amazon, Meta, Mistral, Cohere, AI21,
  Stability, and — pending catalog confirmation — OpenAI). Each provider
  has its own enablement path; the Go tool dispatches by provider and the
  Terraform module's AIP resource is provider-agnostic.

### Non-Goals

- Shipping the Terraform HCL or Go source (out of scope by request).
- Team-wide OIDC/SSO federation (RFC-0003 Phase 3).
- Provisioned throughput, guardrails, or model-invocation logging design.

## Background

In a shared account, Bedrock on-demand spend is unattributable without a
deliberate mechanism. The two mechanisms are application inference profiles
(AIPs) with cost-allocation tags, and IAM-principal cost allocation. Claude
Code accepts an AIP ARN as its model identifier and resolves it via
`bedrock:GetInferenceProfile`, which is what lets AIP tags carry the
attribution. The credential is a long-term Bedrock API key — an IAM user plus
an IAM service-specific credential whose secret is shown exactly once.

## Detailed Design

### 1. Terraform module (`bedrock-claude-code`)

A single module, applied per target account. Cost-allocation tag activation
is conditional: the module can activate the tag **locally** (for a standalone
account or the org management account), or defer to a separate
**payer-account** component (for a member account inside an organization).
CUR export, when used, lives in the payer component. This lets the same
module serve a quick single-account setup and a full org topology without
forking.

#### Member-account resources

- `aws_iam_user` — the credential's backing user. Tagged with the
  cost-allocation tag set so IAM-principal allocation can attribute to it.
- `aws_iam_policy` + `aws_iam_user_policy_attachment` — customer-managed,
  least-privilege. Allows `bedrock:InvokeModel`,
  `bedrock:InvokeModelWithResponseStream`, and `bedrock:GetInferenceProfile`
  with `Resource` scoped to **every AIP ARN provisioned by this module**
  (one entry per `var.models` value) plus the foundation-model ARNs the
  profiles wrap. Provider-agnostic — the policy doesn't differentiate
  Anthropic from Amazon from third-party at the Bedrock-invocation
  layer; Bedrock's IAM check operates on the model/AIP ARN. Explicitly
  does **not** attach `AmazonBedrockLimitedAccess`. Optionally an
  explicit `Deny` for anything outside Bedrock.
- `aws_bedrock_inference_profile` (one per model) — `model_source` set to the
  cross-region inference profile / FM ARN; `tags` carry the cost-allocation
  set. Output the AIP ARNs for use as `ANTHROPIC_MODEL` /
  `ANTHROPIC_SMALL_FAST_MODEL`.
- `aws_sns_topic` + `aws_sns_topic_subscription` — alert fan-out. Email
  subscription is always created; the Slack subscription is gated on
  `var.slack_enabled` (default `false`) per Q6. The Chatbot-vs-Lambda-relay
  delivery mechanism is deferred — when `slack_enabled = true`, the
  operator selects via a sub-variable (`slack_delivery = "chatbot" |
  "lambda"`, default `chatbot` when supported in the target region).
  Documenting the two options without locking a Day-1 default keeps the
  v1 surface minimal.
- `aws_budgets_budget` (cost type) — `cost_filter` on the cost-allocation
  `TagKeyValue`; `notification` blocks at 50/80/100% `ACTUAL` and 100%
  `FORECASTED`, subscribers = the SNS topic. Note: tag-filtered budgets only
  see costs incurred *after* tag activation.
- `aws_cloudwatch_metric_alarm` — on Bedrock per-AIP token-count metrics
  for near-real-time volume signal ahead of billing. **Included in v1 per
  Q3** (not deferred): billing's 24h lag is a known weakness of
  budget-only alerting; the token-count metric closes the gap and is
  cheap to provision alongside the AIPs.

#### Cost-allocation tag activation (conditional)

Controlled by the `cost_allocation_tag_activation` input (`local` | `payer` |
`none`):

- `local` (**default** — per Q1 resolution: optimize for the standalone /
  dedicated-account case) — the module creates `aws_ce_cost_allocation_tag`
  in *this* account. Valid only when the account is standalone or is the
  org management account, because activating a user-defined cost-allocation
  tag is a payer-account operation; in a member account the API has no
  effect. This is the convenient path for a single-account or
  dedicated-account setup.
- `payer` — the module activates nothing; the separate payer
  component (below) owns activation. Set explicitly when the target is a
  member account inside an organization.
- `none` — skip activation entirely (tag already active, or account-level
  budgeting makes per-tag attribution unnecessary).

Gating pattern (resource present only in `local` mode):

```hcl
resource "aws_ce_cost_allocation_tag" "this" {
  count   = var.cost_allocation_tag_activation == "local" ? 1 : 0
  tag_key = var.cost_tag.key
  status  = "Active"
}
```

Optional guardrail: a `precondition` that fails the apply when `local` is
selected but `data.aws_caller_identity.current.account_id` is not the
organization's management account (resolved via
`data.aws_organizations_organization`), to catch a `local` run misapplied in
a member account. **Per Q7 resolution (a):** when the
`data.aws_organizations_organization` lookup fails (the account is not part
of an org, or the principal lacks `organizations:DescribeOrganization`),
treat as standalone-account and skip the check. Permissive default —
standalone-account use is the v1 happy path per Q1, so the precondition
should not block it on a confusing org-API error.

#### Payer-account component (separate state/stack, used when activation = `payer`)

- `aws_ce_cost_allocation_tag` in the management/payer account (or a
  one-time CLI/console activation if provider support lags). Required for
  the tag to appear in Cost Explorer/CUR and for tag-filtered budgets to
  work.
- `aws_bcmdataexports_export` (optional) — CUR 2.0 export; enable
  caller-identity (IAM principal) allocation columns for the second
  attribution lens.

**Module inputs (sketch):**

```hcl
variable "models" {
  description = "Foundation models to expose as AIPs. Logical name → provider + model identifier. Provider drives the Go tool's enablement dispatch (Anthropic → use-case form; Amazon → no-op auto-enabled; third-party → Marketplace subscribe). Model identifier is either a foundation-model ARN OR a system-defined cross-region inference profile ARN."
  type = map(object({
    provider = string  # "anthropic" | "amazon" | "meta" | "mistral" | "cohere" | "ai21" | "stability" | "openai"
    model_id = string  # FM ARN or cross-region inference profile ARN
  }))
}

# Plus: cost_tag (key + value), cost_allocation_tag_activation
# (local|payer|none, default local per Q1), budget_amount + thresholds,
# alert_emails, slack_enabled (default false per Q6), slack_target +
# slack_delivery (consumed only when slack_enabled = true),
# key_expiry_days (passed to Go tool for documentation),
# region (default us-west-2 per Q5).
```

The `provider` field is required-explicit (not inferred from the model
ARN's provider segment) so the operator's intent is auditable and the
Go tool's dispatch routing is fail-loud on typos. Variable validation
rejects unknown provider values.

**Module outputs:** `iam_user_name`, `iam_user_arn`, `aip_arns` (map),
`sns_topic_arn`, `budget_name`. Deliberately **no** credential output — the
secret is never produced by Terraform.

**Explicitly not in Terraform:** the service-specific credential (the bearer
token). Minting it in Terraform would persist the one-time secret in state.

### 2. Go tool (`bedrock-keyctl` — working name)

Interface-driven, minimal-dependency (Uber style), AWS SDK v2. Wraps the IAM
and Bedrock calls behind small interfaces so the secret sink (Vault vs
Secrets Manager) and the AWS surface are both mockable for tests.

#### Subcommands

- `mint --user <name> --expiry-days 90 --sink vault://path|sm://name` Calls
  `iam.CreateServiceSpecificCredential` with
  `ServiceName=bedrock.amazonaws.com` and `CredentialAgeDays`. Captures the
  one-time `ServiceApiKeyValue` and writes it to the configured sink. Prints
  the credential ID and expiry; never prints the secret.
- `rotate --user <name> --expiry-days 90` Uses the two-keys-per-user
  allowance: mint the new key into the sink, verify a test invocation, then
  `update-service-specific-credential --status Inactive` on the old and
  finally delete it after a grace window. Zero-downtime.
- `revoke --user <name> --credential-id <id>` Deactivate then delete a
  specific credential.
- `enable-models --models <list> --target-accounts <mode>` Runs the
  per-provider enablement dispatch over `<list>`. Each model carries its
  provider; the tool routes to the right enablement path (see §3 for the
  per-provider mechanics).

  ```text
  enable-models routing:

    anthropic.* ─► PutUseCaseForModelAccess (one-time form)
    amazon.*    ─► no-op (Nova et al. auto-enabled, AWS-owned)
    meta.*      ─┐
    mistral.*   ─│
    cohere.*    ─┼─► MarketplaceEnablement
    ai21.*      ─│   (ensures the principal can call
    stability.* ─│    aws-marketplace:Subscribe; first
    openai.**   ─┘    invocation auto-enables — see §3)
  ```

  `*openai`: included as a generic Marketplace-subscribe target pending
  Bedrock catalog confirmation (Q5). If/when OpenAI ships on Bedrock with
  its own use-case form (akin to Anthropic), a dedicated provider branch
  lands in the tool — file as a v1.1 IMPL.

  `<mode>` selects the cross-account targeting strategy (independent of
  the per-provider dispatch above):

  - `current` (default) — run in the account the tool is invoked from.
    Simplest case; one account, no cross-account hops.
  - `org-management` — run against the org management account.
    **Anthropic enablement cascades to every member account** at the
    `PutUseCaseForModelAccess` layer; other providers' enablement paths
    do NOT cascade — they're per-account by AWS API design (no cascade
    exists for Marketplace subscribe). For non-Anthropic providers, the
    `org-management` mode is effectively a no-op + a printed warning;
    use `<account-id-list>` instead.
  - `<account-id-list>` — comma-separated list of target account IDs. The
    tool AssumeRoles into each account in turn and runs the per-provider
    dispatch there. The only mode that gives real per-account targeting
    for non-Anthropic providers. Configurable assume-role name
    (`--assume-role-name`, default `bedrock-enablement`).

  All modes are idempotent — safe to re-run. Per-model results print as
  a table (model, provider, action taken, outcome).

**Where it runs:** `mint`/`rotate`/`revoke` in the target member account;
`enable-models` runs from whatever account holds the AssumeRole grants for
its targeting mode (management account for `org-management`, a tooling
account with cross-account roles for `<account-id-list>`, or any account
for `current`). The principal running `enable-models` needs Marketplace
permissions (`aws-marketplace:Subscribe`) the first time a model is
enabled in an account.

**Secret sinks:** Vault (preferred — matches the JIT-secrets pattern; a KV
path the developer's environment reads at session start) or AWS Secrets
Manager (AWS-native alternative). The sink is an interface; adding a third
is a new implementation, not a rewrite.

### 3. Prerequisite: per-provider model access enablement

This is the answer to "can the prereq be automated?" — and it varies by
provider. The Go tool's `enable-models` subcommand dispatches to one of
three enablement paths based on the model's `provider` field.

#### Common ground (post Sept/Oct 2025)

- **Manual enablement is gone.** Bedrock retired the Model Access page and
  auto-enables serverless foundation models by default in all commercial
  regions. The `PutFoundationModelEntitlement` IAM permission and its API
  were retired and no longer have any effect. Access is now governed by
  IAM policies, SCPs, and AWS Marketplace permissions — there is nothing
  to "turn on" per model in the old sense.

#### Path A: Anthropic (use-case form)

- **The one remaining step:** Anthropic models, though enabled by default,
  require a one-time use-case form before first invocation. Submitted via
  `PutUseCaseForModelAccess` (Go SDK / CLI).
- **No first-class Terraform resource** for the form — Terraform could
  only invoke it as a `null_resource` + `local-exec` side effect, which
  is not real state management. The Go tool's `enable-models` owns it.
- **Org cascade applies here:** submitting the form at the management
  account cascades approval to all member accounts (cascade happens via
  API only, not the console). For 200+ account orgs this is the
  high-value move — one call instead of per-account submissions.

#### Path B: Amazon (no-op)

- Amazon-owned models (Nova family) are auto-enabled in all commercial
  regions with no use-case form and no Marketplace subscribe required.
  The tool's `enable-models` skips them silently and prints a "no action
  needed" row in the result table.

#### Path C: Third-party Marketplace providers (Meta / Mistral / Cohere / AI21 / Stability / OpenAI*)

- These providers' models route through AWS Marketplace. The first
  invocation in an account auto-subscribes the principal to the model's
  Marketplace listing **IF** the principal has
  `aws-marketplace:Subscribe`. No use-case form is involved.
- The Go tool's enablement step for these providers is therefore a
  pre-flight check, not a side effect: verify the principal has
  `aws-marketplace:Subscribe`, and either (a) trigger a no-op
  `bedrock:InvokeModel` to force the auto-subscribe, or (b) explicitly
  call `aws-marketplace:Subscribe` if the API allows non-invocation
  subscribe (catalog state at v1 ship time decides which sub-path —
  documented in the IMPL doc).
- **No org cascade.** AWS Marketplace subscribe is per-account by API
  design; `--target-accounts=org-management` does not propagate.
  Use `--target-accounts=<account-id-list>` for fleet enablement.
- *OpenAI*: included as a generic Marketplace-subscribe target pending
  Bedrock catalog confirmation (Q5). If OpenAI on Bedrock ships with its
  own use-case form (parallel to Anthropic's), a Path D is added in a
  follow-up IMPL.

#### Cross-account targeting (orthogonal to provider dispatch)

Independent of the per-provider path (A/B/C above), the tool supports
three cross-account targeting modes via `--target-accounts`. The
applicability differs by provider:

| Mode | Anthropic | Amazon | Third-party (incl. OpenAI*) |
|------|-----------|--------|------------------------------|
| `current` | ✓ submit in this account | ✓ no-op | ✓ subscribe in this account |
| `org-management` | ✓ **cascades** org-wide via the form's management-account behavior | ✓ no-op | ✗ no cascade — prints warning, suggests `<account-id-list>` |
| `<account-id-list>` | ✓ AssumeRole loop, submit per account | ✓ no-op | ✓ AssumeRole loop, subscribe per account |

Three operational patterns the targeting modes support:

- **SCP negation** (operationally simplest at scale): submit Anthropic
  via `--target-accounts=org-management` (cheap cascade), then `Deny`
  `bedrock:InvokeModel` and optionally `aws-marketplace:Subscribe` via
  SCPs attached to OUs / accounts that should NOT use Bedrock. Inverts
  the targeting model: enable broadly, deny narrowly. Best for "enable
  in most accounts" topologies.
- **Per-account AssumeRole loop** (real per-account targeting):
  `--target-accounts=<account-id-list>` does AssumeRole into each
  account. Best for "enable in 5 of 200" topologies + the ONLY way to
  scope third-party-provider enablement per-account (since their
  enablement doesn't cascade). Cost: N API calls + N pre-provisioned
  cross-account roles + the principal needs `sts:AssumeRole` to each
  target.
- **Marketplace-permission gating** (layered defense): deny
  `aws-marketplace:Subscribe` at the OU level. Blocks first-invocation
  auto-enable even when other enablement steps succeeded. Useful as
  belt-and-suspenders with SCP negation.

**Important API constraint:** `PutUseCaseForModelAccess` takes a single
`formData` payload — there is **no `Accounts` / `TargetAccounts` list
parameter**. The Anthropic "cascade" is a side effect of running the
API at the management account; the form submission itself is
single-account-scoped, and the management-account variant is
org-wide-or-nothing. Marketplace subscribe has no equivalent cascade
mechanism at all — every account stands alone.

#### First-invocation Marketplace auto-enable note

Across all three paths, the first `bedrock:InvokeModel` call in an
account auto-subscribes to the model's Marketplace listing if the
calling principal has `aws-marketplace:Subscribe`. The Go tool's
enablement steps either pre-trigger this (Path C) or leave it to
runtime (Path A / Path B when the developer's first call lands). The
developer principal does NOT need `aws-marketplace:Subscribe` — that
permission lives with the tool's enablement principal.

## API / Interface Changes

**Claude Code environment / `~/.claude/settings.json`** (Anthropic-only —
Claude Code consumes Anthropic models exclusively):

- `CLAUDE_CODE_USE_BEDROCK=1`
- `AWS_REGION=<region>` — required; Claude Code does not read this from the
  AWS config file.
- `ANTHROPIC_MODEL=<primary AIP ARN>` and
  `ANTHROPIC_SMALL_FAST_MODEL=<small/fast AIP ARN>` — AIP ARNs (the
  Anthropic Claude entries from `var.models`), not raw model IDs, so
  usage carries the cost-allocation tags.
- `AWS_BEARER_TOKEN_BEDROCK=<token>` — sourced from Secrets Manager
  (default) or Vault, not committed.

**Non-Anthropic model consumption.** The module's `var.models` map can
include non-Anthropic providers (Amazon Nova, Meta Llama, etc.) — their
AIP ARNs are emitted in the module's `aip_arns` output, but Claude Code
itself does not consume them. Other tooling in the consumer environment
(custom SDKs, agentic frameworks, batch jobs) reads `aip_arns` and uses
the appropriate AWS SDK invocation against those AIP ARNs. Same
cost-attribution model (AIP tags + IAM principal) covers all providers
because the tagging is provider-agnostic.

**Go tool CLI:** `mint`, `rotate`, `revoke`, `enable-models` as above —
provider-aware dispatch per §Detailed Design §2.

## Data Model

**Cost-allocation tag schema (single source of truth):**

| Key | Example value | Purpose |
|-----|---------------|---------|
| `app` | `claude-code` | Primary attribution dimension; budget filter |
| `cost-center` | `<team/cc>` | Chargeback grouping |
| `env` | `dev` / `shared` | Optional split |

The same key/value set is applied to every AIP and to the backing IAM user,
so both the AIP-tag lens and the IAM-principal lens resolve to the same
bucket.

**Secret layout:** `vault://secret/claude-code/bedrock/<account>/<user>` (or
the equivalent Secrets Manager name), value = the bearer token; metadata =
credential ID + expiry for the rotation job.

## Testing Strategy

- Reuse the existing `tftest`/`libtftest` Terratest harness with LocalStack
  for the IAM/SNS/Budgets surface. Bedrock inference profiles, IAM
  service-specific credentials for `bedrock.amazonaws.com`, and Budgets are
  likely gaps in LocalStack community — route those through `sneakystack`
  so the module plan/apply path is exercisable without real AWS spend.
- Go tool: unit-test against mocked IAM/Bedrock/sink interfaces; assert the
  secret is never logged and that `rotate` only deletes the old credential
  after the new one verifies.
- Integration: a sandbox account run that mints a short-expiry key, invokes
  once through an AIP, and confirms the tag surfaces in Cost Explorer
  (allow ~24h).

## Migration / Rollout Plan

1. Tag activation: either set `cost_allocation_tag_activation = "local"` for
   a standalone/management account, or apply the payer component in the
   management account. Then submit model access: `enable-models
   --org-management`.
2. Member account: `terraform apply` the module (IAM user, AIPs, SNS,
   budget).
3. `mint` the key into Vault/SM; distribute the settings file.
4. Force a low test threshold; confirm email + Slack alerts fire.
5. Schedule `rotate` ahead of expiry.

## Open Questions

All ten resolved 2026-06-01 and folded into the §Detailed Design above.

### Q1 — Dedicated account vs shared? — RESOLVED (single-account default)

**Resolved:** module defaults `cost_allocation_tag_activation = "local"`
(the standalone / dedicated-account happy path). Operators flip to
`"payer"` explicitly when targeting a member account inside an org.
Optimizes the input surface for the v1 use case (a single Claude Code
account) while preserving the org-member path as a non-default escape
hatch.

### Q2 — Vault or Secrets Manager as the canonical sink? — RESOLVED (Secrets Manager)

**Resolved:** AWS Secrets Manager is the documented default
(`mint --sink sm://name`). README + tool help text recommend it; Vault
stays supported via the `--sink vault://path` interface for operators
who run Vault. SM-as-default keeps the v1 setup AWS-native (no Vault
dependency for accounts that don't run it) and aligns with the
account-scoped IAM model the rest of the module assumes.

### Q3 — CloudWatch token-metric alarm in v1 or later? — RESOLVED (yes, v1)

**Resolved:** `aws_cloudwatch_metric_alarm` ships in v1. Budgets'
~24h billing lag is the known weakness of budget-only alerting; the
token-count metric closes the gap with near-real-time volume signal
and is cheap to provision alongside the AIPs. No reason to defer.

### Q4 — Per-developer vs single shared credential? — RESOLVED (single credential for v1)

**Resolved:** single shared credential is the v1 scope. Confirms
RFC-0003 §Problem Statement and the §Implementation Phase 3 trigger:
Phase 3 federation activates when team-wide adoption demands
per-developer attribution — until then, one credential, one rotation
schedule, one revocation surface. v1's IAM + rotation infrastructure
sizes for ~1 credential, not N.

### Q5 — Region + model matrix — RESOLVED (us-west-2 + Claude Opus/Sonnet/Haiku in v1; multi-provider support in tool from Day 1)

**Resolved:**

- **Region:** `us-west-2` (module default for `var.region`). Highest
  Bedrock model availability across Anthropic variants; matches
  Anthropic's own dedicated-account guidance for Claude Code on
  Bedrock.
- **Anthropic model set (v1 default `models` input):** Claude Opus,
  Sonnet, and Haiku (the three Claude tiers covering capability vs
  cost). Each gets its own AIP + tag set; `ANTHROPIC_MODEL` points at
  Sonnet (balanced) by default + `ANTHROPIC_SMALL_FAST_MODEL` at
  Haiku. The default `models` map ships pre-populated with these
  three entries; operators add/remove via the input.
- **Multi-provider support in the Go tool from v1:** per the
  refinement landed in §Detailed Design §2 + §3, `enable-models`
  dispatches by provider — Anthropic (use-case form), Amazon (no-op),
  third-party Marketplace (Meta / Mistral / Cohere / AI21 / Stability /
  OpenAI). The Terraform module's AIP creation is provider-agnostic;
  only the Go tool's enablement step varies. Operators can populate
  the `models` map with mixed providers from Day 1.
- **OpenAI GPT 5.5:** included as a generic Marketplace-subscribe
  target in the tool's dispatch table, but **not in the v1 default
  `models` map** pending Bedrock catalog confirmation. AWS Bedrock's
  catalog as of the design author's knowledge horizon (Jan 2026) did
  not host OpenAI GPT models. If GPT 5.5 ships on Bedrock with a
  use-case form (parallel to Anthropic's), a Path D is added in a
  follow-up IMPL. Until catalog state is confirmed, the tool's
  `openai` provider entry routes to the generic Marketplace-subscribe
  path. Operators who add `{ provider = "openai", model_id = "..." }`
  to the `models` map opt into this best-guess routing.

### Q6 — SNS → Slack delivery mechanism — RESOLVED (optional, off by default)

**Resolved:** Slack delivery is opt-in via `var.slack_enabled` (default
`false`). v1 ships with email subscription only. When the operator
sets `slack_enabled = true`, a `var.slack_delivery` sub-variable
selects between `"chatbot"` (default when supported in the target
region) and `"lambda"` (opt-in for regions without Chatbot support).
The Chatbot-vs-Lambda decision itself is documented in the README but
not locked at the module-default layer — operators pick when they opt
in. Possibly defer Slack entirely; revisit if v1 operators ask for it.

### Q7 — Tag-activation precondition: skip-on-org-data-failure semantics — RESOLVED (a)

**Resolved:** treat `data.aws_organizations_organization` lookup
failure as "standalone account, skip the precondition check."
Permissive interpretation — pairs with Q1's standalone-account default
and avoids exposing the v1 happy path to a confusing org-API error.
The strict alternative (b — fail loud on lookup failure) is recorded
in the §Detailed Design's guardrail comment as the future-strict
posture if member-account misuse becomes a recurring issue.

### Q8 — `bedrock-keyctl` Go module location — RESOLVED (b, sibling under `tools/`)

**Resolved:** the Go tool lives at `tools/bedrock-keyctl/` in this
repo. Shares the modules-repo CI surface (Go gates + golangci-lint +
govulncheck + go-licenses per INV-0003 §CI/CD direction); ships in
lockstep with the Terraform module so a coupled update lands in one
PR. Does not block on (and is not absorbed by) the planned per-module
versioning Go CLI from INV-0003's sibling RFC — both Go binaries can
co-exist under `tools/` once the versioning CLI ships.

### Q9 — Cross-account role provisioning — RESOLVED (out of module scope; document IAM contract only)

**Resolved:** the `bedrock-claude-code` module does **not** ship a
cross-account role-provisioning variant. Operators are assumed to
provision the required IAM (both in-account and cross-account) via
their org-foundations stack / IAM Identity Center / chosen mechanism.
The module's README documents the required IAM contract:

- **In-account permissions** (the principal applying the module):
  IAM (`CreateUser`, `CreatePolicy`, `AttachUserPolicy`,
  `CreateServiceSpecificCredential`), Bedrock
  (`CreateInferenceProfile`, `GetInferenceProfile`, `TagResource`),
  SNS, Budgets, Cost Explorer (`UpdateCostAllocationTagsStatus` for
  `local` mode), CloudWatch alarms.
- **Enablement-principal permissions** (the principal running
  `enable-models`, in-account OR cross-account):
  - Anthropic provider: `bedrock:PutUseCaseForModelAccess`.
  - Amazon provider: none (no-op).
  - Third-party providers (Meta, Mistral, Cohere, AI21, Stability,
    OpenAI*): `aws-marketplace:Subscribe`,
    `aws-marketplace:ViewSubscriptions`, and
    `bedrock:InvokeModel` (for the no-op invocation that triggers
    first-invocation auto-subscribe; if the IMPL elects the explicit
    `aws-marketplace:Subscribe` call path instead, `InvokeModel`
    drops off).
- **Cross-account permissions** (when the Go tool's
  `--target-accounts=<account-id-list>` mode is used): a role named
  `bedrock-enablement` (configurable) in each target account, trusting
  the tooling-account principal, with the enablement-principal
  permissions above (subsetted to the provider mix the tool dispatches
  in that account).

Standardizes on the documented contract; keeps the module focused on
the per-account declarative footprint.

### Q10 — Org-mode form re-submission semantics — RESOLVED (defer; document StackSet path as future work)

**Resolved:** v1 does not handle org-growth events
(member-account additions after the cascade). Operators re-run
`enable-models --target-accounts=org-management` manually when an org
grows, or run it per-new-account via
`--target-accounts=<single-account-id>`. The README documents that the
production-grade answer is **AWS CloudFormation StackSets** (or a
Terragrunt equivalent) registering the enablement as an
auto-deploy-on-new-account stack, but that is **out of scope for v1**.
Surface this as a follow-up work item once v1 is in production and
org-growth events become a recurring pain point.

## Related Work

- [INV-0003](../investigation/0003-cicd-options-for-a-terraform-modules-monorepo.md)'s sibling RFC scopes a separate Go CLI for per-module versioning + changelog + HCL-parsed reverse-deps + stub generation. The `bedrock-keyctl` tool described here is the second Go CLI in this repo's pipeline; both could share infrastructure (AWS SDK v2 wiring, mock-friendly interface patterns, signed-release pipeline, Renovate annotations). Q8 above tracks the consolidation decision.
- [ADR-0001](../adr/0001-cross-module-composition-via-terraformremotestate.md) — the cross-module remote-state composition pattern. The `bedrock-claude-code` module's outputs (`iam_user_name`, `aip_arns`, `sns_topic_arn`) follow this contract so future consumers (e.g. a developer-onboarding Terraform stack that reads the AIP ARNs and writes `~/.claude/settings.json` files via a different mechanism) can compose.

## References

- [RFC-0003](../rfc/0003-claude-code-on-bedrock-governed-access-provisioning-and-cost.md) — Claude Code on Bedrock: governed access provisioning and cost tracking
- AWS: simplified Bedrock model access; retirement of Model Access page and `PutFoundationModelEntitlement`
- AWS: `PutUseCaseForModelAccess`; org management-account cascade for Anthropic models
- AWS: Bedrock cost allocation by IAM principal (Apr 2026); application inference profiles + cost-allocation tags
- Anthropic: Claude Code on Amazon Bedrock settings and dedicated-account guidance
- Terraform AWS provider: `aws_bedrock_inference_profile`, `aws_budgets_budget`, `aws_ce_cost_allocation_tag`, `aws_bcmdataexports_export`
