<!-- markdownlint-disable-file MD025 MD041 -->
# `modules/bedrock/claude-code`

Claude Code on Amazon Bedrock — governed access, provisioning, and
per-team cost attribution. The module provisions one backing IAM user
with a least-privilege Bedrock-only policy, one application inference
profile (AIP) per `var.models` entry, a tag-filtered AWS Budget with
SNS + email (optional Slack) alerting, a per-AIP CloudWatch token-count
alarm, and conditional cost-allocation tag activation. It is
provider-agnostic at the Bedrock layer: the same resource set provisions
Anthropic, Amazon, or any third-party Bedrock model.

The credential the developer's Claude Code consumes
(`AWS_BEARER_TOKEN_BEDROCK`) is **deliberately not minted by Terraform** —
an IAM service-specific credential's one-time secret would land in state
in plaintext. Minting, rotation, and revocation live in the
[`bedrock-keyctl`](../../../tools/bedrock-keyctl/README.md) Go CLI, which
also owns per-provider model-access enablement. This module produces the
`iam_user_name` and `aip_arns` that the tool and downstream onboarding
stacks consume.

Implements
[IMPL-0009](../../../docs/impl/0009-claude-code-on-bedrock-module-go-tool-implementation.md)
/ [DESIGN-0009](../../../docs/design/0009-claude-code-on-bedrock-module-tool-and-enablement-contracts.md)
/ [RFC-0003](../../../docs/rfc/0003-claude-code-on-bedrock-governed-access-provisioning-and-cost.md).

See [USAGE.md](USAGE.md) for the generated input / output reference.

## Quickstart

Region defaults to `us-west-2` (DESIGN-0009 Q5 — the canonical Claude
Opus / Sonnet / Haiku region). Copy the canonical triple below; `model_id`
may be a bare foundation-model ID or a full ARN (the module constructs the
ARN from `region` when given a bare ID).

```hcl
module "platform_claude_code" {
  source = "git::https://github.com/your-org/libtftest-tf-modules.git//modules/bedrock/claude-code?ref=v1.0.0"

  region        = "us-west-2"
  budget_amount = 2000 # USD/month

  cost_tag = {
    key   = "Team"
    value = "platform-ai"
  }

  models = {
    opus   = { provider = "anthropic", model_id = "anthropic.claude-3-opus-20240229-v1:0" }
    sonnet = { provider = "anthropic", model_id = "anthropic.claude-3-5-sonnet-20241022-v2:0" }
    haiku  = { provider = "anthropic", model_id = "anthropic.claude-3-5-haiku-20241022-v1:0" }
  }

  alert_emails = ["platform-ai-oncall@your-org.example"]

  tags = {
    Environment = "production"
  }
}
```

`aip_arns["sonnet"]` feeds Claude Code's `ANTHROPIC_MODEL`;
`aip_arns["haiku"]` feeds `ANTHROPIC_SMALL_FAST_MODEL`. The IAM policy
scopes `bedrock:InvokeModel*` to exactly these AIP ARNs plus their backing
foundation-model ARNs.

### Multi-provider example

`provider` is one of the eight Bedrock vendors (`anthropic`, `amazon`,
`meta`, `mistral`, `cohere`, `ai21`, `stability`, `openai`). One AIP is
created per entry regardless of provider; only the *enablement* prereq
differs (see the IAM contract below).

```hcl
  models = {
    opus  = { provider = "anthropic", model_id = "anthropic.claude-3-opus-20240229-v1:0" }
    nova  = { provider = "amazon", model_id = "amazon.nova-pro-v1:0" }
    llama = { provider = "meta", model_id = "meta.llama3-1-70b-instruct-v1:0" }
  }
```

## IAM contract

The module manages the per-account declarative footprint; it does **not**
provision cross-account roles (DESIGN-0009 Q9). Operators supply the IAM
below via their org-foundations stack / IAM Identity Center / chosen
mechanism. Three scopes:

### 1. In-account (the principal applying this module)

- IAM: `CreateUser`, `CreatePolicy`, `AttachUserPolicy`.
- Bedrock: `CreateInferenceProfile`, `GetInferenceProfile`, `TagResource`.
- SNS, Budgets, CloudWatch alarms.
- Cost Explorer: `ce:UpdateCostAllocationTagsStatus` — only for
  `cost_allocation_tag_activation = "local"`.

`bedrock-keyctl` (not this module) additionally needs
`iam:CreateServiceSpecificCredential` / `UpdateServiceSpecificCredential` /
`DeleteServiceSpecificCredential` / `ListServiceSpecificCredentials` on the
backing user to mint/rotate/revoke the bearer token.

### 2. Enablement-principal (the principal running `enable-models`)

Per-provider deltas — this is the only place the provider matters:

| Path | Providers | Required permissions |
|------|-----------|----------------------|
| **A** | `anthropic` | `bedrock:PutUseCaseForModelAccess` (one-time form; cascades org-wide from the management account) |
| **B** | `amazon` | none — the Nova family is auto-enabled; the tool is a no-op |
| **C** | `meta`, `mistral`, `cohere`, `ai21`, `stability`, `openai` | `aws-marketplace:Subscribe`, `aws-marketplace:ViewSubscriptions`, and `bedrock:InvokeModel` (the no-op invocation that triggers first-invocation auto-subscribe) |

### 3. Cross-account (`enable-models --target-accounts=<id-list>`)

A role named `bedrock-enablement` (configurable via `--assume-role-name`)
in each target account, trusting the tooling-account principal, carrying
the enablement-principal permissions above subsetted to the provider mix
dispatched in that account. The tooling principal needs `sts:AssumeRole`
to each.

## Cost-allocation tag activation

`var.cost_tag` is the load-bearing attribution dimension (applied to the
IAM user, every AIP, the SNS topic, and the budget filter — not merged
from `var.tags`). `cost_allocation_tag_activation` controls whether
`cost_tag.key` is promoted to a cost-allocation dimension:

- **`local`** (default) — the module creates an
  `aws_ce_cost_allocation_tag`. Requires the account to be standalone or
  the org **management** account (Cost Explorer tag activation is a
  payer-account API).
- **`payer`** — the module ships no resource; activate manually in the
  management account using the `cost_tag_key` output:

  ```bash
  aws ce update-cost-allocation-tags-status --region us-east-1 \
    --cost-allocation-tags-status TagKey=Team,Status=Active
  ```

- **`none`** — skip activation entirely. The tag is still applied to
  resources; it is just not promoted to a billing dimension.

## Slack delivery

Email is always created (`alert_emails`). Slack is opt-in
(`slack_enabled = true`, which requires `slack_target` — enforced by a
`lifecycle.precondition`). Pick the mechanism with `slack_delivery`:

- **`chatbot`** (default) — `slack_target` is an AWS Chatbot HTTPS
  endpoint. Preferred when AWS Chatbot is available in your region and you
  want a managed, no-code path.
- **`lambda`** — `slack_target` is a relay Lambda ARN. Use when AWS
  Chatbot is unavailable in `region`, or you need custom formatting /
  routing. **Region caveat:** AWS Chatbot is not available in every
  region; if `region` lacks it, use `lambda` (the relay can live in any
  region and post to Slack over HTTPS).

## Operational gotchas

- **~24h Cost Explorer lag.** Tag-filtered budget data and cost reports
  trail real spend by up to a day. The per-AIP CloudWatch token-count
  alarm (`token_alarm_threshold`, default 1,000,000 tokens / 5 min) is the
  near-real-time tripwire that fires *ahead* of the billing lag — tune it
  to roughly a quarter of the daily budget at the model's per-Mtok rate.
- **AIP version sprawl.** Updating a `model_id` replaces the AIP. Long-
  lived Claude Code sessions pin the old AIP ARN until they refresh
  `settings.json`; coordinate model swaps with a session-refresh window.
- **Marketplace `Subscribe` on first invocation.** Third-party (Path C)
  models auto-subscribe on the *first* `InvokeModel` only if the calling
  principal holds `aws-marketplace:Subscribe`. Run
  `bedrock-keyctl enable-models` (which holds that permission) before
  developers first invoke, or the first call fails.

## Destroying this module

Revoke the bearer token **before** `terraform destroy`:

```bash
bedrock-keyctl revoke --user <iam_user_name> --credential-id <id> \
  --sink sm://<secret-name> --force
```

`terraform destroy` deletes the IAM user, but a service-specific
credential minted out-of-band by `bedrock-keyctl` is not in Terraform
state — destroying without revoking first orphans a live bearer token.
`revoke` deactivates and deletes the credential in IAM, then purges the
sink (IAM-before-sink), so no in-flight invocation can succeed against a
stale key.

## Tests

```bash
# Plan-only suite (~1.2s, no LocalStack):
just tf test bedrock/claude-code

# LocalStack gap-discovery probe (Bedrock/Budgets/CE/Organizations are
# 500/501 in Community 3.8.1 — see tests-localstack/FINDINGS.md):
just tf test-localstack bedrock/claude-code
```

## Module map

| File | Purpose |
|------|---------|
| `versions.tf` | Provider (`~> 6.2`) + Terraform (`>= 1.1`) pins |
| `variables.tf` | Full input contract |
| `main.tf` | Provider-agnostic entrypoint |
| `locals.tf` | `account_id`, `cost_tag_map`, derived `user_name`, `aip_arns`, `model_fm_arns`, budget notifications |
| `iam.tf` | IAM user + least-privilege invoke policy (`AllowAipInvoke` + optional `DenyEverythingElse`) |
| `inference_profiles.tf` | `aws_bedrock_inference_profile` for_each over `var.models` |
| `budget.tf` | Tag-filtered `aws_budgets_budget` (ACTUAL thresholds + FORECASTED) |
| `alerting.tf` | SNS topic + email/Slack subscriptions |
| `cloudwatch.tf` | Per-AIP token-count `aws_cloudwatch_metric_alarm` |
| `cost_allocation.tf` | Gated `aws_ce_cost_allocation_tag` (`local` mode) |
| `outputs.tf` | Consumer-contract outputs (`aip_arns`, `iam_user_name`, …) |
| `tests/` | Plan-only `terraform test` suite |
| `tests-localstack/` | Gap-discovery probe + FINDINGS.md |
