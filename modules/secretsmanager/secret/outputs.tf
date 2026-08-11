#--------------------------------------------------------------
# Pointer-only outputs (INV-0010 F7 / DESIGN-0020)
#
# These are the module's entire remote-state contract — the POINTER to
# the secret, never its value. Remote-state outputs re-persist into
# every consumer's state, so a value output would leak the password
# into N+1 state files. No output may reference the ephemeral or any
# value-bearing attribute; the plan suite pins this exact output set
# by name (outputs_contract.tftest.hcl) so additions are deliberate.
#--------------------------------------------------------------

output "secret_arn" {
  description = "ARN of the Secrets Manager secret — the composition pointer. Consumers (the RDS reference mode, rds/proxy) scope their IAM secretsmanager:GetSecretValue to exactly this ARN and read the value ephemerally at apply."
  value       = aws_secretsmanager_secret.this.arn
}

output "secret_id" {
  description = "Resource ID of the secret (equals the ARN for Secrets Manager; kept for symmetry with the fleet's other producers)."
  value       = aws_secretsmanager_secret.this.id
}

output "secret_name" {
  description = "Physical (suffixed) secret name — informational. NB: the ADR-0020 remote-state key couples to var.name, NOT this value; consumers resolve the secret by ARN, never by constructing this name."
  value       = aws_secretsmanager_secret.this.name
}

output "kms_key_arn" {
  description = "CMK ARN encrypting the secret, or null when the AWS-managed aws/secretsmanager key is in charge (the default). Faithful null matters: rds/proxy keys off it — non-null gets exact kms:Decrypt scoping, null falls back to its ViaService-fenced wildcard path."
  value       = var.kms_key_arn
}

output "secret_string_version" {
  description = "Current value of the write-only version gate — informational. Bumping the input mints one new password (INV-0010 F4); consumers that copy the value onward re-send on their own version bump."
  value       = var.secret_string_version
}

output "username" {
  description = "Non-secret username half of the DB-credential pair (null when the secret is a bare password). Lets consumers sanity-check which credential pair they are pointing at without reading the value."
  value       = var.username
}
