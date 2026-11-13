#--------------------------------------------------------------
# Provider Versions
#--------------------------------------------------------------

terraform {
  # >= 1.9: the writer/intake disjointness guard and the prefix-overlap
  # guard are CROSS-VARIABLE validations, which Terraform only accepts
  # from 1.9. Below that floor they stop being accepted rather than
  # erroring loudly. Do not lower it.
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}
