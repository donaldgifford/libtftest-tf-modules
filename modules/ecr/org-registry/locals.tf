#--------------------------------------------------------------
# Locals
#--------------------------------------------------------------

locals {
  account_id = data.aws_caller_identity.current.account_id

  kms_key_arn = coalesce(var.kms_key_arn, try(aws_kms_key.ecr_oci[0].arn, null))

  kms_alias_name        = "alias/${var.name_prefix}-ecr-oci"
  template_role_name    = "${var.name_prefix}-ecr-template"
  publisher_policy_name = "${var.name_prefix}-oci-publisher"
}
