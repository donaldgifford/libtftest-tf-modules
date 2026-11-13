# Read-back fixture: resolves the alias the module created and the key
# behind it, so the suite asserts what KMS actually stored and serves,
# not what the module's own state says.

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

variable "alias_name" {
  type = string
}

data "aws_kms_alias" "this" {
  name = var.alias_name
}

data "aws_kms_key" "this" {
  key_id = data.aws_kms_alias.this.target_key_arn
}

output "target_key_arn" {
  value = data.aws_kms_alias.this.target_key_arn
}

output "key_usage" {
  value = data.aws_kms_key.this.key_usage
}

output "key_spec" {
  value = data.aws_kms_key.this.customer_master_key_spec
}
