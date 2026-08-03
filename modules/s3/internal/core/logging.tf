#--------------------------------------------------------------
# Server-access-logging wiring (DESIGN-0019 F4, core side)
#
# The caller pre-resolves WHERE to log (remote-state lookup / explicit
# override / disabled — the tri-state lives in the purpose modules,
# where the ADR-0020 key assertion needs a root-module data source).
# This module only wires the resolved target: logging = null means no
# logging resource at all. A null prefix defaults to
# "<this bucket's final name>/" so the sink self-organizes by source —
# resolved HERE because only the core knows the composed name (the
# shard prefix is unknown until apply).
#--------------------------------------------------------------

resource "aws_s3_bucket_logging" "this" {
  count = var.logging != null ? 1 : 0

  bucket        = aws_s3_bucket.this.id
  target_bucket = var.logging.target_bucket
  target_prefix = coalesce(var.logging.prefix, "${local.bucket_name}/")

  lifecycle {
    precondition {
      condition     = var.logging.target_bucket != local.bucket_name
      error_message = "logging.target_bucket must not be this bucket's own name ('${local.bucket_name}') — self-logging loops log deliveries into themselves. The access-logs sink module has no logging surface for exactly this reason."
    }
  }
}
