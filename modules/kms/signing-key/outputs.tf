#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------

output "key_arn" {
  description = "The key ARN."
  value       = aws_kms_key.this.arn
}

output "key_id" {
  description = "The key ID."
  value       = aws_kms_key.this.key_id
}

output "alias_name" {
  description = "The alias name (alias/<name>)."
  value       = aws_kms_alias.this.name
}

output "alias_arn" {
  description = "The alias ARN. Same-account use only: KMS aliases cannot be used across accounts."
  value       = aws_kms_alias.this.arn
}

output "public_key_pem" {
  description = "The PEM-encoded public key, for verifiers and admission controllers that should not need KMS access."
  value       = data.aws_kms_public_key.this.public_key_pem
}

output "cosign_key_ref" {
  description = "The cosign --key reference: awskms:///<key ARN>. Uses the key ARN, never the alias, because aliases do not resolve across accounts."
  value       = "awskms:///${aws_kms_key.this.arn}"
}

output "signer_policy_json" {
  description = "The identity-side grant a CROSS-ACCOUNT signer needs (kms:Sign, GetPublicKey, DescribeKey on this key). Same-account signers are already covered by the key policy."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "SignWithKey"
      Effect   = "Allow"
      Action   = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]
      Resource = [aws_kms_key.this.arn]
    }]
  })
}
