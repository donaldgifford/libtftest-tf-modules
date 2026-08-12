# Unit tests for credentials.rego — run via `conftest verify --policy
# policy/` (wired into `just conftest`). Each deny rule is exercised
# both ways: a violating input fires exactly the expected message, and
# the legal write-only / managed-password shapes stay clean.
#
# Inputs mirror conftest's hcl2 parse shape:
# input.resource.<type>.<name> = [ { <attributes> } ].

package main

# ── aws_secretsmanager_secret_version ──────────────────────────────

test_secret_string_denied if {
	count(deny) == 1 with input as {"resource": {"aws_secretsmanager_secret_version": {"v": [{"secret_id": "x", "secret_string": "leak"}]}}}
}

test_secret_binary_denied if {
	count(deny) == 1 with input as {"resource": {"aws_secretsmanager_secret_version": {"v": [{"secret_id": "x", "secret_binary": "bGVhaw=="}]}}}
}

test_secret_string_wo_allowed if {
	count(deny) == 0 with input as {"resource": {"aws_secretsmanager_secret_version": {"v": [{"secret_id": "x", "secret_string_wo": "${ephemeral.random_password.this.result}", "secret_string_wo_version": 1}]}}}
}

# ── aws_db_instance ────────────────────────────────────────────────

test_db_instance_password_denied if {
	count(deny) == 1 with input as {"resource": {"aws_db_instance": {"d": [{"identifier": "db", "password": "leak"}]}}}
}

test_db_instance_password_wo_allowed if {
	count(deny) == 0 with input as {"resource": {"aws_db_instance": {"d": [{"identifier": "db", "password_wo": "${ephemeral.aws_secretsmanager_secret_version.v.secret_string}", "password_wo_version": 1}]}}}
}

test_db_instance_managed_password_allowed if {
	count(deny) == 0 with input as {"resource": {"aws_db_instance": {"d": [{"identifier": "db", "manage_master_user_password": true}]}}}
}

# ── aws_rds_cluster ────────────────────────────────────────────────

test_rds_cluster_master_password_denied if {
	count(deny) == 1 with input as {"resource": {"aws_rds_cluster": {"c": [{"cluster_identifier": "db", "master_password": "leak"}]}}}
}

test_rds_cluster_master_password_wo_allowed if {
	count(deny) == 0 with input as {"resource": {"aws_rds_cluster": {"c": [{"cluster_identifier": "db", "master_password_wo": "${ephemeral.aws_secretsmanager_secret_version.v.secret_string}", "master_password_wo_version": 1}]}}}
}

# ── cross-cutting ──────────────────────────────────────────────────

test_multiple_violations_all_reported if {
	count(deny) == 2 with input as {"resource": {
		"aws_db_instance": {"d": [{"password": "leak"}]},
		"aws_rds_cluster": {"c": [{"master_password": "leak"}]},
	}}
}

test_unrelated_resources_clean if {
	count(deny) == 0 with input as {"resource": {"aws_s3_bucket": {"b": [{"bucket": "name"}]}}}
}
