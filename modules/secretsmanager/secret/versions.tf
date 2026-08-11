#--------------------------------------------------------------
# Provider Versions
#
# required_version is ">= 1.11" — the fleet's FIRST 1.11 floor, and it
# is load-bearing: this module uses write-only arguments
# (aws_secretsmanager_secret_version.secret_string_wo), which Terraform
# introduced in 1.11 (ephemeral resources landed in 1.10). Do not
# "simplify" this back down to the fleet's usual ">= 1.1" — the module
# does not parse below 1.11. See DESIGN-0020 / INV-0010 F2.
#
# The random provider supplies ephemeral "random_password" — chosen over
# the aws provider's aws_secretsmanager_random_password precisely
# because it opens locally (no API call), keeping the generation path
# plan-testable offline (INV-0010 F3.3, resolution 3a).
#--------------------------------------------------------------

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}
