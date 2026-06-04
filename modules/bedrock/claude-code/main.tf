# Claude Code on Bedrock — governed access, provisioning, and cost
#
# Per-account Terraform module implementing DESIGN-0009 / RFC-0003. It
# provisions the AWS-API surface that lets a fleet consume Claude Code
# through Amazon Bedrock with governed access and per-team cost
# attribution:
#
#   * An IAM user + least-privilege customer-managed policy scoped to the
#     application inference profiles (AIPs) this module creates. The
#     module does NOT mint the service-specific credential (the bearer
#     token Claude Code reads via AWS_BEARER_TOKEN_BEDROCK) — that is
#     minted out-of-band by the bedrock-keyctl Go tool so the secret
#     never touches Terraform state (DESIGN-0009 §2).
#   * One aws_bedrock_inference_profile per var.models entry, each
#     carrying the cost-allocation tag. Provider-agnostic: the IAM policy
#     and AIPs operate on the model/AIP ARN, not the provider, so the
#     same resource set works for Anthropic, Amazon, Meta, Mistral,
#     Cohere, AI21, Stability, and OpenAI models.
#   * Cost governance — conditional cost-allocation tag activation, a
#     tag-filtered AWS Budget with actual + forecasted thresholds, an
#     SNS topic with email (and optional Slack) subscriptions, and a
#     per-AIP CloudWatch token-count alarm for near-real-time signal
#     ahead of the ~24h Cost Explorer billing lag.
#
# Resources are split across cost_allocation.tf, iam.tf,
# inference_profiles.tf, alerting.tf, budget.tf, and cloudwatch.tf. The
# identity-class data sources live in cost_allocation.tf alongside the
# tag-activation guardrail.
