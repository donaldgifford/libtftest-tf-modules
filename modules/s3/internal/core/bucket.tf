#--------------------------------------------------------------
# The bucket + fixed security baseline (DESIGN-0019 F2)
#
# Fixed (no variables): Block Public Access (all four flags),
# BucketOwnerEnforced ownership (ACLs disabled — the access-logs sink
# included: modern log delivery writes via the bucket-policy grant, not
# ACLs). Default-on, overridable: SSE-KMS with the AWS-managed aws/s3
# key + bucket key (CMK via encryption.kms_key_arn; SSE-S3 for the
# access-logs sink), MPU-abort lifecycle hygiene. Default-off:
# versioning (operator decision, INV-0009 F2).
#
# The composed-name precondition lives here (not a variable validation)
# because it spans name/name_override/account_id/region — the
# validation-split doctrine at the fleet's terraform floor.
#--------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", local.bucket_name))
      error_message = "Composed bucket name '${local.bucket_name}' must be 3-63 chars of lowercase alphanumerics + hyphens (alphanumeric ends; dots deliberately disallowed — they break virtual-hosted TLS). Shorten var.name (the account+region suffix and optional shard prefix count against the 63) or fix name_override."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.encryption.mode == "kms" ? "aws:kms" : "AES256"
      kms_master_key_id = var.encryption.kms_key_arn
    }

    # Bucket keys only apply to SSE-KMS (cuts KMS request cost); AWS
    # rejects the flag on AES256.
    bucket_key_enabled = var.encryption.mode == "kms"
  }

  lifecycle {
    precondition {
      condition     = var.encryption.kms_key_arn == null || var.encryption.mode == "kms"
      error_message = "encryption.kms_key_arn is only valid with encryption.mode = \"kms\" — SSE-S3 (mode \"s3\") cannot take a customer key."
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # Baseline hygiene: abandoned multipart uploads accrue storage cost
  # invisibly (no object exists until completion).
  rule {
    id     = "abort-incomplete-multipart-upload"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }

  dynamic "rule" {
    for_each = var.extra_lifecycle_rules

    content {
      id     = rule.value.id
      status = rule.value.enabled ? "Enabled" : "Disabled"

      filter {
        prefix = rule.value.prefix
      }

      dynamic "expiration" {
        for_each = rule.value.expiration_days != null ? [rule.value.expiration_days] : []

        content {
          days = expiration.value
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_version_expiration_days != null ? [rule.value.noncurrent_version_expiration_days] : []

        content {
          noncurrent_days = noncurrent_version_expiration.value
        }
      }
    }
  }

  # Noncurrent-version rules only make sense once versioning state is
  # settled; the provider recommends sequencing after the versioning
  # resource.
  depends_on = [aws_s3_bucket_versioning.this]
}
