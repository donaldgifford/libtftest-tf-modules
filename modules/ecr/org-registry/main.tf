#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------

data "aws_caller_identity" "current" {}

# The provider's default_tags, read back for the creation templates'
# resource_tags (DESIGN-0029): ECR applies those to repositories it creates
# later, which the provider never manages, so default_tags cannot reach
# them on their own. Reads provider config only — no API call.
data "aws_default_tags" "this" {}
