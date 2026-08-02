#--------------------------------------------------------------
# Provider Versions
#
# No direct provider use — every resource lives in the internal core
# (../internal/core), whose aws ~> 6.2 + random ~> 3.7 constraints
# aggregate through init. Declaring them here too would trip tflint's
# unused-required-providers rule.
#--------------------------------------------------------------

terraform {
  required_version = ">= 1.1"
}
