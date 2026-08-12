# Metadata-only version probe for the apply suite (IMPL-0019 3.1/3.2,
# DESIGN-0020 OQ 6a).
#
# Deliberately uses aws_secretsmanager_secret_versions (plural — version
# METADATA only) and NOT the singular aws_secretsmanager_secret_version
# data source, which returns the secret value and would put it into the
# test run's transient state. The whole point of OQ 6a is that no value
# ever leaves Secrets Manager, even in tests.

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}

variable "secret_id" {
  description = "ARN of the secret whose version metadata to read."
  type        = string
  nullable    = false
}

data "aws_secretsmanager_secret_versions" "this" {
  secret_id = var.secret_id
}

locals {
  current = [
    for v in data.aws_secretsmanager_secret_versions.this.versions :
    v if contains(v.version_stages, "AWSCURRENT")
  ]
}

output "current_version_id" {
  description = "Version id currently staged AWSCURRENT (empty string when none — asserted against in the suite)."
  value       = length(local.current) > 0 ? local.current[0].version_id : ""
}

output "version_count" {
  description = "Total number of versions the API reports (informational — recorded in FINDINGS.md, not hard-asserted; stage-retention behavior is emulator-specific)."
  value       = length(data.aws_secretsmanager_secret_versions.this.versions)
}
