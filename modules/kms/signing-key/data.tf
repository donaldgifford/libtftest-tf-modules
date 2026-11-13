#--------------------------------------------------------------
# Data sources
#--------------------------------------------------------------

# The applying principal, checked against admin_principal_arns so the
# key can never be created with a policy that locks its own deployer out.
data "aws_caller_identity" "current" {}

# The public half, for verifiers and admission controllers that should
# not need KMS access at all.
data "aws_kms_public_key" "this" {
  key_id = aws_kms_key.this.arn
}
