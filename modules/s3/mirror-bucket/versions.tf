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
  # >= 1.9 — NOT the fleet's usual >= 1.1 floor, and NOT arbitrary.
  #
  # The lock-coherence guard is a CROSS-VARIABLE validation: a
  # condition on var.object_lock_retention_days that also reads
  # var.enable_object_lock. Terraform only permits a validation block
  # to reference another variable from 1.9 onward (the
  # network/security-group precedent).
  #
  # The guard is mirrored at this root (rather than relying on the
  # core's identical rule) because terraform test expect_failures
  # cannot target a child module's variable validation — the failure
  # must name THIS variable. The failure mode of lowering this floor
  # is quiet and bad: on < 1.9 the guard stops being accepted rather
  # than erroring loudly.
  required_version = ">= 1.9"

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
