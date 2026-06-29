<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
| aws | ~> 6.2 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.47.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_bedrock_inference_profile.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/bedrock_inference_profile) | resource |
| [aws_budgets_budget.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget) | resource |
| [aws_ce_cost_allocation_tag.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ce_cost_allocation_tag) | resource |
| [aws_cloudwatch_metric_alarm.token_count](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_policy.bedrock_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_user.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user) | resource |
| [aws_iam_user_policy_attachment.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user_policy_attachment) | resource |
| [aws_sns_topic.alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_subscription.email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_sns_topic_subscription.slack](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.bedrock_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_organizations_organization.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/organizations_organization) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alert\_emails | Email addresses subscribed to the SNS alert topic (budget thresholds + per-AIP token alarms fan out here). One aws\_sns\_topic\_subscription per entry. Defaults to [] — the topic is still created so consumers can attach their own subscriber types via the sns\_topic\_arn output. | `list(string)` | `[]` | no |
| budget\_amount | Monthly spend ceiling in USD for the cost-allocation-tag-filtered AWS Budget. Notifications fire at var.budget\_thresholds\_percent of this amount (ACTUAL) plus var.budget\_forecast\_threshold\_percent (FORECASTED). | `number` | n/a | yes |
| budget\_forecast\_threshold\_percent | Percentage of var.budget\_amount at which the single FORECASTED-spend budget notification fires. Defaults to 100 — warn when AWS forecasts month-end spend will hit the ceiling. | `number` | `100` | no |
| budget\_thresholds\_percent | Percentages of var.budget\_amount at which ACTUAL-spend budget notifications fire. Defaults to [50, 80, 100]. Each entry produces one notification block fanned out to the SNS topic. | `list(number)` | ```[ 50, 80, 100 ]``` | no |
| cost\_allocation\_tag\_activation | How the cost\_tag.key gets activated as a cost-allocation tag. 'local' (default) creates an aws\_ce\_cost\_allocation\_tag in this account (requires the account to be standalone or the org management account). 'payer' means the operator activates it manually in the management account (README documents the recipe; this module ships no resource). 'none' skips activation entirely (the tag is still applied; just not promoted to a cost-allocation dimension). | `string` | `"local"` | no |
| cost\_tag | The load-bearing cost-allocation tag pair applied to the IAM user/policy, every AIP, the SNS topic, and the budget filter. key/value flow from here (NOT merged from var.tags) because this is an attribution dimension, not a generic tag. The key is also what gets activated as a cost-allocation tag when cost\_allocation\_tag\_activation = 'local'. | ```object({ key = string value = string })``` | n/a | yes |
| deny\_non\_bedrock | When true (default), the IAM policy carries an explicit Deny on everything outside bedrock:* and sts:GetCallerIdentity — belt-and-suspenders so the bearer token cannot be reused by spawned subprocesses for non-Bedrock AWS operations (RFC-0003 threat model). Set false only if a consumer legitimately needs the credential broader, which is strongly discouraged. | `bool` | `true` | no |
| key\_expiry\_days | Documentation-only passthrough for the bedrock-keyctl tool's --expiry-days default (90 per DESIGN-0009 Q11). The Terraform module does NOT mint the IAM service-specific credential; this surfaces the expected rotation cadence in module docs/outputs so the operator-facing contract is co-located. Changing it has no effect on any resource. | `number` | `90` | no |
| models | Map of AIP logical name -> { provider, model\_id } provisioning one aws\_bedrock\_inference\_profile per entry. provider is the model vendor (one of the eight Bedrock providers); model\_id is the backing foundation-model ARN or ID the AIP copies from. Provider-agnostic — the same resource set works for every provider. Defaults to {} (DESIGN-0009 Q3); copy the canonical us-west-2 Claude triple from the README. | ```map(object({ provider = string model_id = string }))``` | `{}` | no |
| region | AWS region the Bedrock application inference profiles, IAM user, budget, and alerting resources live in. Defaults to us-west-2 (DESIGN-0009 Q5 canonical Claude Opus/Sonnet/Haiku region). Has a default but is conceptually required — 'required-with-default' is the fleet posture for region inputs. | `string` | `"us-west-2"` | no |
| slack\_delivery | Slack delivery mechanism, consumed only when slack\_enabled = true. 'chatbot' (default) fronts an AWS Chatbot HTTPS endpoint; 'lambda' points the subscription at a relay Lambda ARN. Interpretation of var.slack\_target depends on this value. | `string` | `"chatbot"` | no |
| slack\_enabled | When true, the module adds a second SNS subscription delivering alerts to Slack via var.slack\_delivery. Default false — operators opt in deliberately (email is always created). Requires var.slack\_target to be set (enforced by a lifecycle.precondition per DESIGN-0009 Q10). | `bool` | `false` | no |
| slack\_target | The Slack delivery endpoint, consumed only when slack\_enabled = true. Interpreted per var.slack\_delivery: an AWS Chatbot HTTPS endpoint URL for 'chatbot', or a relay Lambda ARN for 'lambda'. Must be non-null whenever slack\_enabled = true (enforced by lifecycle.precondition). | `string` | `null` | no |
| tags | AWS resource tags applied to every taggable resource (IAM user, IAM policy, AIPs, SNS topic, CloudWatch alarms). The cost-allocation tag pair from var.cost\_tag is merged in separately and is NOT sourced from this map — it is a load-bearing attribution dimension, not a generic tag. | `map(string)` | `{}` | no |
| token\_alarm\_threshold | Per-AIP CloudWatch token-count alarm threshold — the Sum of Bedrock token-count metrics over a single 5-minute period that trips the alarm. Defaults to 1,000,000 tokens/5min, a deliberately aggressive near-real-time tripwire that fires well ahead of the ~24h Cost Explorer billing lag. Tune to roughly a quarter of the daily budget at the model's per-Mtok burn rate. | `number` | `1000000` | no |
| user\_name | Optional explicit name for the backing IAM user. When null (default), the module derives it as '<cost\_tag.value>-claude-code'. Supply an explicit name when the derived value would collide or violate site IAM-naming policy. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| aip\_arns | Map of var.models logical name -> application inference profile ARN. The load-bearing output: the developer-onboarding stack reads this to populate Claude Code's settings.json (ANTHROPIC\_MODEL / ANTHROPIC\_SMALL\_FAST\_MODEL) and the IAM policy scopes invoke permissions to these ARNs. |
| budget\_name | Name of the tag-filtered AWS Budget. Useful for cross-stack references and for operators inspecting budget state via the AWS CLI. |
| cost\_tag\_key | The cost-allocation tag key (var.cost\_tag.key). Passthrough for the payer-account component: when cost\_allocation\_tag\_activation = 'payer', the operator runs `aws ce update-cost-allocation-tags-status` in the management account with this key (README documents the recipe). |
| cost\_tag\_value | The cost-allocation tag value (var.cost\_tag.value). Passthrough surfacing the attribution dimension's value alongside cost\_tag\_key for the payer-account activation recipe and for downstream cost-report tooling. |
| iam\_user\_arn | ARN of the backing IAM user — the IAM-principal pivot for cost allocation and for scoping cross-account trust policies. |
| iam\_user\_name | Name of the backing IAM user. Pass to the bedrock-keyctl tool's --user flag to mint/rotate/revoke the bearer token (the service-specific credential for bedrock.amazonaws.com). |
| key\_expiry\_days | Expected bearer-token rotation cadence in days (var.key\_expiry\_days, default 90 per DESIGN-0009 Q11). Passthrough only — Terraform does not mint the credential; this co-locates the operator-facing contract so the bedrock-keyctl tool / onboarding stack can read the intended --expiry-days from remote state. |
| sns\_topic\_arn | ARN of the alert SNS topic. Consumers wanting to attach their own subscriber type (PagerDuty, a custom Lambda, a second Slack workspace) reference this directly rather than re-deriving it. |
<!-- END_TF_DOCS -->
