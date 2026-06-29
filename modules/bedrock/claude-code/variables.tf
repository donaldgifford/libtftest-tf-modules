#--------------------------------------------------------------
# Required inputs
#
# region carries a default per DESIGN-0009 Q5 ("required-with-default"
# is the fleet posture for region inputs), but the cost-attribution
# inputs (cost_tag, budget_amount) are genuinely required — the module
# is a cost-governance wrapper, so there is no sensible default for the
# attribution dimension or the spend ceiling.
#--------------------------------------------------------------

variable "region" {
  description = "AWS region the Bedrock application inference profiles, IAM user, budget, and alerting resources live in. Defaults to us-west-2 (DESIGN-0009 Q5 canonical Claude Opus/Sonnet/Haiku region). Has a default but is conceptually required — 'required-with-default' is the fleet posture for region inputs."
  type        = string
  default     = "us-west-2"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]$", var.region))
    error_message = "region must match ^[a-z]{2}-[a-z]+-[0-9]$ (e.g. us-west-2)."
  }

  nullable = false
}

variable "cost_tag" {
  description = "The load-bearing cost-allocation tag pair applied to the IAM user/policy, every AIP, the SNS topic, and the budget filter. key/value flow from here (NOT merged from var.tags) because this is an attribution dimension, not a generic tag. The key is also what gets activated as a cost-allocation tag when cost_allocation_tag_activation = 'local'."
  type = object({
    key   = string
    value = string
  })

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_:-]{0,127}$", var.cost_tag.key))
    error_message = "cost_tag.key must match ^[A-Za-z][A-Za-z0-9_:-]{0,127}$ (AWS tag-key shape: 1-128 chars, first char alphabetic)."
  }

  validation {
    condition     = length(var.cost_tag.value) > 0
    error_message = "cost_tag.value must be a non-empty string (it seeds the IAM user name and every resource's attribution tag)."
  }

  nullable = false
}

variable "budget_amount" {
  description = "Monthly spend ceiling in USD for the cost-allocation-tag-filtered AWS Budget. Notifications fire at var.budget_thresholds_percent of this amount (ACTUAL) plus var.budget_forecast_threshold_percent (FORECASTED)."
  type        = number

  validation {
    condition     = var.budget_amount > 0
    error_message = "budget_amount must be greater than 0 (USD)."
  }

  nullable = false
}

#--------------------------------------------------------------
# Optional inputs
#--------------------------------------------------------------

variable "alert_emails" {
  description = "Email addresses subscribed to the SNS alert topic (budget thresholds + per-AIP token alarms fan out here). One aws_sns_topic_subscription per entry. Defaults to [] — the topic is still created so consumers can attach their own subscriber types via the sns_topic_arn output."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alert_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e))])
    error_message = "Each alert_emails entry must be a plausible email address (local@domain.tld)."
  }

  nullable = false
}

variable "models" {
  description = "Map of AIP logical name -> { provider, model_id } provisioning one aws_bedrock_inference_profile per entry. provider is the model vendor (one of the eight Bedrock providers); model_id is the backing foundation-model ARN or ID the AIP copies from. Provider-agnostic — the same resource set works for every provider. Defaults to {} (DESIGN-0009 Q3); copy the canonical us-west-2 Claude triple from the README."
  type = map(object({
    provider = string
    model_id = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.models : contains(
        ["anthropic", "amazon", "meta", "mistral", "cohere", "ai21", "stability", "openai"],
        v.provider
      )
    ])
    error_message = "Each models entry's provider must be one of: anthropic, amazon, meta, mistral, cohere, ai21, stability, openai."
  }

  validation {
    condition     = alltrue([for k, v in var.models : length(v.model_id) > 0])
    error_message = "Each models entry's model_id must be a non-empty string (the backing foundation-model ARN/ID the AIP copies from)."
  }

  nullable = false
}

variable "cost_allocation_tag_activation" {
  description = "How the cost_tag.key gets activated as a cost-allocation tag. 'local' (default) creates an aws_ce_cost_allocation_tag in this account (requires the account to be standalone or the org management account). 'payer' means the operator activates it manually in the management account (README documents the recipe; this module ships no resource). 'none' skips activation entirely (the tag is still applied; just not promoted to a cost-allocation dimension)."
  type        = string
  default     = "local"

  validation {
    condition     = contains(["local", "payer", "none"], var.cost_allocation_tag_activation)
    error_message = "cost_allocation_tag_activation must be one of: local, payer, none."
  }

  nullable = false
}

variable "user_name" {
  description = "Optional explicit name for the backing IAM user. When null (default), the module derives it as '<cost_tag.value>-claude-code'. Supply an explicit name when the derived value would collide or violate site IAM-naming policy."
  type        = string
  default     = null
}

variable "deny_non_bedrock" {
  description = "When true (default), the IAM policy carries an explicit Deny on everything outside bedrock:* and sts:GetCallerIdentity — belt-and-suspenders so the bearer token cannot be reused by spawned subprocesses for non-Bedrock AWS operations (RFC-0003 threat model). Set false only if a consumer legitimately needs the credential broader, which is strongly discouraged."
  type        = bool
  default     = true

  nullable = false
}

variable "slack_enabled" {
  description = "When true, the module adds a second SNS subscription delivering alerts to Slack via var.slack_delivery. Default false — operators opt in deliberately (email is always created). Requires var.slack_target to be set (enforced by a lifecycle.precondition per DESIGN-0009 Q10)."
  type        = bool
  default     = false

  nullable = false
}

variable "slack_delivery" {
  description = "Slack delivery mechanism, consumed only when slack_enabled = true. 'chatbot' (default) fronts an AWS Chatbot HTTPS endpoint; 'lambda' points the subscription at a relay Lambda ARN. Interpretation of var.slack_target depends on this value."
  type        = string
  default     = "chatbot"

  validation {
    condition     = contains(["chatbot", "lambda"], var.slack_delivery)
    error_message = "slack_delivery must be one of: chatbot, lambda."
  }

  nullable = false
}

variable "slack_target" {
  description = "The Slack delivery endpoint, consumed only when slack_enabled = true. Interpreted per var.slack_delivery: an AWS Chatbot HTTPS endpoint URL for 'chatbot', or a relay Lambda ARN for 'lambda'. Must be non-null whenever slack_enabled = true (enforced by lifecycle.precondition)."
  type        = string
  default     = null
}

variable "budget_thresholds_percent" {
  description = "Percentages of var.budget_amount at which ACTUAL-spend budget notifications fire. Defaults to [50, 80, 100]. Each entry produces one notification block fanned out to the SNS topic."
  type        = list(number)
  default     = [50, 80, 100]

  validation {
    condition     = alltrue([for t in var.budget_thresholds_percent : t >= 1 && t <= 100])
    error_message = "Each budget_thresholds_percent entry must be in the range [1, 100]."
  }

  nullable = false
}

variable "budget_forecast_threshold_percent" {
  description = "Percentage of var.budget_amount at which the single FORECASTED-spend budget notification fires. Defaults to 100 — warn when AWS forecasts month-end spend will hit the ceiling."
  type        = number
  default     = 100

  validation {
    condition     = var.budget_forecast_threshold_percent >= 1 && var.budget_forecast_threshold_percent <= 100
    error_message = "budget_forecast_threshold_percent must be in the range [1, 100]."
  }

  nullable = false
}

variable "token_alarm_threshold" {
  description = "Per-AIP CloudWatch token-count alarm threshold — the Sum of Bedrock token-count metrics over a single 5-minute period that trips the alarm. Defaults to 1,000,000 tokens/5min, a deliberately aggressive near-real-time tripwire that fires well ahead of the ~24h Cost Explorer billing lag. Tune to roughly a quarter of the daily budget at the model's per-Mtok burn rate."
  type        = number
  default     = 1000000

  validation {
    condition     = var.token_alarm_threshold > 0
    error_message = "token_alarm_threshold must be greater than 0 (tokens per 5-minute period)."
  }

  nullable = false
}

variable "key_expiry_days" {
  description = "Documentation-only passthrough for the bedrock-keyctl tool's --expiry-days default (90 per DESIGN-0009 Q11). The Terraform module does NOT mint the IAM service-specific credential; this surfaces the expected rotation cadence in module docs/outputs so the operator-facing contract is co-located. Changing it has no effect on any resource."
  type        = number
  default     = 90

  validation {
    condition     = var.key_expiry_days > 0
    error_message = "key_expiry_days must be greater than 0 (days)."
  }

  nullable = false
}

variable "tags" {
  description = "AWS resource tags applied to every taggable resource (IAM user, IAM policy, AIPs, SNS topic, CloudWatch alarms). The cost-allocation tag pair from var.cost_tag is merged in separately and is NOT sourced from this map — it is a load-bearing attribution dimension, not a generic tag."
  type        = map(string)
  default     = {}

  nullable = false
}
