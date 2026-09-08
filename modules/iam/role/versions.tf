#--------------------------------------------------------------
# Provider Versions
#
# The fleet floor holds at >= 1.1: every validation in this module is
# single-variable (no cross-variable rule needs TF 1.9 — contrast
# network/security-group's world-open guard, IMPL-0023 OQ 1a).
#--------------------------------------------------------------

terraform {
  required_version = ">= 1.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}
