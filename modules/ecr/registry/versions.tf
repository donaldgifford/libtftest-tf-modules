#--------------------------------------------------------------
# Provider Versions
#--------------------------------------------------------------

terraform {
  # >= 1.9, not the fleet's usual >= 1.1 floor: two guards are
  # CROSS-VARIABLE validations (consumer_accounts reads
  # pull_repository_prefixes; pull_repository_prefixes reads
  # protected_prefixes), which Terraform only accepts from 1.9. Below
  # that floor the guards stop being accepted rather than failing
  # loudly, so do not lower it (the network/security-group precedent).
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}
