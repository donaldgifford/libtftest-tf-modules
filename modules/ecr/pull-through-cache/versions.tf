#--------------------------------------------------------------
# Provider Versions
#--------------------------------------------------------------

terraform {
  # >= 1.11 because credentials.tf seeds the upstream-credential
  # placeholder through the write-only secret_string_wo argument
  # (write-only arguments landed in Terraform 1.11). Do not simplify
  # back down to the fleet floor.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}
