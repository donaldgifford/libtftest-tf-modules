#--------------------------------------------------------------
# Provider Versions
#--------------------------------------------------------------

terraform {
  # >= 1.9 — NOT the fleet's usual >= 1.1 floor, and NOT arbitrary.
  #
  # The world-open guard is a CROSS-VARIABLE validation: a condition on
  # var.ingress_rules that also reads var.allow_world_open_ingress.
  # Terraform only permits a validation block to reference another
  # variable from 1.9 onward (DESIGN-0026 OQ 1a).
  #
  # The failure mode of lowering this is quiet and bad: on < 1.9 the
  # guard does not error loudly, it simply stops being accepted — so
  # "simplifying" the floor down silently removes the module's
  # highest-value protection. If you ever need a lower floor, the guard
  # has to move to a precondition on the ingress rule resource first
  # (OQ 1b), which changes both its error site and its message.
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}
