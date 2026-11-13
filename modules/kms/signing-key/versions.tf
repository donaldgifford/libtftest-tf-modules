#--------------------------------------------------------------
# Provider Versions
#--------------------------------------------------------------

terraform {
  # >= 1.9: signer_principal_arns' disjointness guard is a
  # CROSS-VARIABLE validation (it reads admin_principal_arns), which
  # Terraform only accepts from 1.9. Do not lower this floor.
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}
