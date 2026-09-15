# Plain logging-target bucket owned by this suite's fixture. The
# mirror module names its sink explicitly (no remote-state read), so
# unlike s3/bucket's fixture there is no sink module to apply and no
# state key to seed — just a bucket whose name the suite passes as
# access_log_bucket.

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

resource "aws_s3_bucket" "target" {
  bucket        = "mirror-logs-target-${var.account_id}-${var.region}"
  force_destroy = true
}

output "target_bucket_name" {
  value = aws_s3_bucket.target.bucket
}
