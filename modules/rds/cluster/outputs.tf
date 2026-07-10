#--------------------------------------------------------------
# Module outputs (consumer contract)
#
# The source-of-truth output surface consumed by two modules:
#   1. read-replica (DESIGN-0014) reads cluster_identifier,
#      cluster_resource_id, engine, engine_version_actual,
#      db_subnet_group_name, db_parameter_group_name.
#   2. proxy (target_type = "aurora-cluster") reads the seven-output
#      composition set.
#
# Stable surface; renaming or removing an output breaks downstream
# remote-state consumers. Populated in Phase 8.
#--------------------------------------------------------------
