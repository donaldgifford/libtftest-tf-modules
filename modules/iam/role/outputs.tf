#--------------------------------------------------------------
# Outputs — pointer-only (DESIGN-0025)
#
# No policy echo (the caller supplied every document and ARN) and no
# credential-adjacent values: nothing here mints credentials — that
# is tools/bedrock-keyctl territory. Published at the
# platform-reserved ADR-0020 shape
# <account_name>/<region>/iam/<name>/terraform.tfstate.
#--------------------------------------------------------------

output "role_arn" {
  description = "The role's ARN. Note this is the PATH-BEARING spelling IAM returns — consumers composing trust policies or access entries must use it verbatim (see the README's path note)."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "The role's exact name — the by-name contract every ADR-0020 assume_role block composes from (role_arn = arn:aws:iam::<account_id>:role/<this>)."
  value       = aws_iam_role.this.name
}

output "role_unique_id" {
  description = "The role's stable unique ID (AROA...). Survives a rename; useful for audit correlation across CloudTrail."
  value       = aws_iam_role.this.unique_id
}
