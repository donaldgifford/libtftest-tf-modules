#--------------------------------------------------------------
# Key policy composition (DESIGN-0031 § kms/signing-key)
#
# Explicit statements only, and NO root delegation (OQ 3a): without an
# arn:aws:iam::<acct>:root statement, account IAM cannot grant kms:Sign,
# so a principal holding kms:* on * through an identity policy (a broad
# admin role) still cannot sign. Only the key policy names signers. That
# is the property a key that vouches for images needs.
#--------------------------------------------------------------

locals {
  # <account>/<name>, lowercased and path-stripped: the IMPL-0020 /
  # iam/role comparison form, since one role has two ARN spellings and
  # IAM names are case-insensitively unique.
  admin_keys = [for a in var.admin_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]

  # The caller arrives as an STS assumed-role ARN
  # (arn:aws:sts::<acct>:assumed-role/<role>/<session>), an IAM user ARN,
  # or the account root. Normalize the first two to the same form.
  caller_arn      = data.aws_caller_identity.current.arn
  caller_resource = element(split(":", local.caller_arn), 5)
  caller_name = (
    startswith(local.caller_resource, "assumed-role/")
    ? element(split("/", local.caller_resource), 1)
    : element(reverse(split("/", local.caller_resource)), 0)
  )
  caller_key = lower("${element(split(":", local.caller_arn), 4)}/${local.caller_name}")

  admin_statement = {
    Sid       = "KeyAdministration"
    Effect    = "Allow"
    Principal = { AWS = sort(var.admin_principal_arns) }
    # Administering the key must not mean being able to vouch with it.
    NotAction = ["kms:Sign"]
    Resource  = "*"
  }

  sign_statement = {
    Sid       = "AllowSign"
    Effect    = "Allow"
    Principal = { AWS = sort(var.signer_principal_arns) }
    Action    = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]
    Resource  = "*"
  }

  verify_statements = (length(var.verifier_principal_arns) == 0 ? [] : [{
    Sid       = "AllowVerify"
    Effect    = "Allow"
    Principal = { AWS = sort(var.verifier_principal_arns) }
    Action    = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Verify"]
    Resource  = "*"
  }])

  key_policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = concat([local.admin_statement, local.sign_statement], local.verify_statements)
  })
}
