# credentials.rego — the fleet's persisted-credential deny policy
# (IMPL-0019 Phase 4 / DESIGN-0020; the generalized INV-0010 no-leak
# invariant).
#
# THE INVARIANT: no module may pass a credential through a PERSISTED
# Terraform argument — those values land in state (and often plan) in
# plaintext. The only legal credential paths in this fleet are:
#   - write-only arguments (secret_string_wo, password_wo,
#     master_password_wo) fed by ephemeral values, and
#   - the AWS-managed master secret (manage_master_user_password).
#
# Enforced repo-wide by scripts/static-check.sh (via `just conftest`)
# against MODULE SOURCE using conftest's hcl2 parser: input shape is
#   input.resource.<type>.<name> = [ { <attributes> } ]
# (bodies are ARRAYS — see `conftest parse --parser hcl2`).
#
# Presence alone is the violation: it does not matter whether the value
# is a literal, a variable, or a data-source read — a persisted
# credential argument puts SOMETHING secret into state.
#
# The Atlantis plan-JSON variant of this policy belongs to the live
# repo (a different input shape: tfplan JSON, not HCL source) — same
# rule intent, per IMPL-0019's Out of Scope.

package main

# aws_secretsmanager_secret_version: secret_string / secret_binary
# persist the value; secret_string_wo is the only allowed path.
deny contains msg if {
	some name
	input.resource.aws_secretsmanager_secret_version[name][_].secret_string
	msg := sprintf(
		"aws_secretsmanager_secret_version.%s sets secret_string — persisted in state; use secret_string_wo (write-only) instead",
		[name],
	)
}

deny contains msg if {
	some name
	input.resource.aws_secretsmanager_secret_version[name][_].secret_binary
	msg := sprintf(
		"aws_secretsmanager_secret_version.%s sets secret_binary — persisted in state; use secret_string_wo (write-only) instead",
		[name],
	)
}

# aws_db_instance: password persists the master password; password_wo
# or manage_master_user_password are the allowed paths.
deny contains msg if {
	some name
	input.resource.aws_db_instance[name][_].password
	msg := sprintf(
		"aws_db_instance.%s sets password — persisted in state; use password_wo (write-only) or manage_master_user_password",
		[name],
	)
}

# aws_rds_cluster: master_password persists; master_password_wo or
# manage_master_user_password are the allowed paths.
deny contains msg if {
	some name
	input.resource.aws_rds_cluster[name][_].master_password
	msg := sprintf(
		"aws_rds_cluster.%s sets master_password — persisted in state; use master_password_wo (write-only) or manage_master_user_password",
		[name],
	)
}
