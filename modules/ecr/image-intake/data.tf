#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------

# Account and region compose every repository ARN in the policies.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Creation templates tag repositories that ECR creates LATER, on push,
# outside the provider, so provider default_tags never reach them. The
# standard set is read back and passed as resource_tags (DESIGN-0029).
data "aws_default_tags" "current" {}
