#--------------------------------------------------------------
# Composed bucket policy (DESIGN-0019 F2 + OQ 4b)
#
# Fixed statements (reserved sids, always rendered):
#   DenyInsecureTransport — HTTPS-only (aws:SecureTransport = false)
#   DenyOldTls            — TLS >= 1.2 (s3:TlsVersion < 1.2)
# Opt-in (reserved sid, rendered when allowed_vpc_endpoint_ids set):
#   DenyOutsideVpce       — deny unless aws:SourceVpce is in the list
# Then internal_policy_statements append ADDITIVELY — the merge cannot
# remove or replace the baseline (reserved sids rejected by the
# variable validation), per DESIGN-0019 OQ 4b.
#
# Injected statements name resources as SUFFIXES of the bucket ARN
# ("" = the bucket, "/*" = objects) because an input literally
# referencing this module's own bucket_arn output would be a
# module-boundary cycle.
#--------------------------------------------------------------

data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyOldTls"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "NumericLessThan"
      variable = "s3:TlsVersion"
      values   = ["1.2"]
    }
  }

  dynamic "statement" {
    for_each = length(var.allowed_vpc_endpoint_ids) > 0 ? [1] : []

    content {
      sid       = "DenyOutsideVpce"
      effect    = "Deny"
      actions   = ["s3:*"]
      resources = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      condition {
        test     = "StringNotEquals"
        variable = "aws:SourceVpce"
        values   = var.allowed_vpc_endpoint_ids
      }
    }
  }

  dynamic "statement" {
    for_each = var.internal_policy_statements

    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = [for s in statement.value.resource_suffixes : "${aws_s3_bucket.this.arn}${s}"]

      dynamic "principals" {
        for_each = statement.value.principals

        content {
          type        = principals.key
          identifiers = principals.value
        }
      }

      dynamic "condition" {
        for_each = statement.value.conditions

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  # Attach after PAB so there is no window with a policy but no
  # public-access guardrails.
  depends_on = [aws_s3_bucket_public_access_block.this]
}
