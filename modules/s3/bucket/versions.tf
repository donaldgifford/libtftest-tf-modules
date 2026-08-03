#--------------------------------------------------------------
# Provider Versions
#
# Every resource lives in the internal core (../internal/core), but the
# root module MUST still declare the aws requirement: without it,
# terraform test cannot bind a test-file provider "aws" block to the
# configuration and every plan run fails resolving real credentials.
# random stays undeclared — it needs no configuration, so the child's
# ~> 3.7 constraint aggregates through init on its own.
#--------------------------------------------------------------

terraform {
  required_version = ">= 1.1"

  required_providers {
    # No direct aws resource here, but the declaration is load-bearing:
    # it binds the plan suites' test-file provider "aws" blocks (and
    # inherits down to the core), so it must stay.
    # tflint-ignore: terraform_unused_required_providers
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}
