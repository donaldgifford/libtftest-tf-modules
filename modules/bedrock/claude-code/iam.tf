# IAM user + least-privilege customer-managed policy for Claude Code on
# Bedrock.
#
# We deliberately do NOT attach the AWS-managed AmazonBedrockLimitedAccess
# policy. That managed policy grants bedrock:* across ALL models and
# inference profiles in the account — the opposite of the per-team,
# per-AIP scoping this module exists to enforce (DESIGN-0009 §1). The
# customer-managed policy below scopes invoke permissions to exactly the
# AIPs (and their backing foundation models) this module provisions, and
# the optional Deny statement (var.deny_non_bedrock) blocks the bearer
# token from being reused for any non-Bedrock AWS operation. The absence
# of the managed policy is the security control, not an oversight.

resource "aws_iam_user" "this" {
  name = local.user_name

  tags = merge(var.tags, local.cost_tag_map)
}

data "aws_iam_policy_document" "bedrock_invoke" {
  # AllowAipInvoke — invoke + describe scoped to this module's AIPs and
  # their backing foundation models. Gated on a non-empty models map so
  # an instantiate-as-default (empty models) plan does not emit a
  # statement with an empty Resource list. Bedrock checks IAM against
  # both the AIP ARN and the wrapped FM ARN, hence both appear here.
  dynamic "statement" {
    for_each = length(var.models) > 0 ? [1] : []

    content {
      sid    = "AllowAipInvoke"
      effect = "Allow"
      actions = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:GetInferenceProfile",
      ]
      resources = concat(values(local.aip_arns), local.model_fm_arns)
    }
  }

  # DenyEverythingElse — belt-and-suspenders so the bearer token cannot
  # be reused by spawned subprocesses for non-Bedrock operations
  # (RFC-0003 threat model). NotAction keeps bedrock:* + the identity
  # self-check callable; everything else is denied on every resource.
  dynamic "statement" {
    for_each = var.deny_non_bedrock ? [1] : []

    content {
      sid    = "DenyEverythingElse"
      effect = "Deny"
      not_actions = [
        "bedrock:*",
        "sts:GetCallerIdentity",
      ]
      resources = ["*"]
    }
  }
}

resource "aws_iam_policy" "bedrock_invoke" {
  name   = "${aws_iam_user.this.name}-bedrock-invoke"
  policy = data.aws_iam_policy_document.bedrock_invoke.json

  tags = merge(var.tags, local.cost_tag_map)

  # Defense in depth alongside the var.models variable validation —
  # catches a provider slipping through if the variable validation is
  # ever loosened or bypassed by a future refactor.
  lifecycle {
    precondition {
      condition = alltrue([
        for k, v in var.models : contains(
          ["anthropic", "amazon", "meta", "mistral", "cohere", "ai21", "stability", "openai"],
          v.provider
        )
      ])
      error_message = "Every var.models entry's provider must be one of the eight supported Bedrock providers (anthropic, amazon, meta, mistral, cohere, ai21, stability, openai)."
    }
  }
}

resource "aws_iam_user_policy_attachment" "this" {
  user       = aws_iam_user.this.name
  policy_arn = aws_iam_policy.bedrock_invoke.arn
}
