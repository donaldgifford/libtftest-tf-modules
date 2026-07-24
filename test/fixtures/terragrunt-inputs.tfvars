# Shared Terragrunt-provided globals for the LocalStack test suites (IMPL-0015).
#
# In production these six values are injected by Terragrunt includes into every
# module — whether or not the module declares them. This file is the test-time
# stand-in: one place that centralizes the Terragrunt constants so every
# consumer's account-scoped remote-state read + assume_role resolves without
# per-suite duplication. Wired into `terraform test` by the `just tf test*`
# recipes via `-var-file` (see the justfile `_tf-test*` recipes).
#
# Producer-only modules (e.g. network/vpc-lookup) that declare none of these
# will emit harmless "Value for undeclared variable" warnings — accepted per
# IMPL-0015 Open Question 6a, mirroring Terragrunt's pass-every-input design.
#
# Phase 1 (INV-0005 5a) proved LocalStack STS mints credentials for any role
# ARN, so account_id / deploy_role_name need not name a real IAM role.

account_name               = "sandbox"
account_id                 = "000000000000"
region                     = "us-east-1"
remote_state_bucket        = "tftest-fleet-state"
remote_state_bucket_region = "us-east-1"
deploy_role_name           = "Deploy-Tf-Role"
