#--------------------------------------------------------------
# Provider Versions
#
# random powers the opt-in shard prefix (DESIGN-0019 / INV-0009 OQ 7)
# — the first random-provider use in the fleet.
#--------------------------------------------------------------

terraform {
  required_version = ">= 1.1"

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
