# RDS instance module (modules/rds/instance)
#
# A single, non-clustered aws_db_instance for postgres / mysql workloads
# that don't need Aurora (DESIGN-0012 / IMPL-0011). Forks the shipped
# modules/rds/serverless scaffolding: VPC remote state, managed-or-BYO
# KMS, granular SG rules, AWS-managed master password, static
# parameter-family lookup, and the validation-split doctrine
# (single-variable -> variable.validation; cross-variable ->
# lifecycle.precondition). Emits the seven proxy-composition outputs so
# it is a valid target_type = "rds-instance" for modules/rds/proxy.
#
# Data sources (VPC remote state) land in Phase 2.
