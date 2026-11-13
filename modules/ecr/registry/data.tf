#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------

# Account and region come from the provider that applies the policy
# (DESIGN-0030 OQ 9a), never from Terragrunt globals: a mismatch between
# a global and the provider would render repository ARNs for the wrong
# registry. The module declares none of the six globals.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
