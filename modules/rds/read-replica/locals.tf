#--------------------------------------------------------------
# Aliased cluster remote-state outputs (populated in Phase 2)
#
# A thin locals layer aliasing the cluster outputs consumed by the
# readers — cluster_identifier, engine, engine_version_actual,
# db_subnet_group_name, db_parameter_group_name — at the use site
# (per the memory: read remote state at the use site, minimal locals).
# Security group + KMS are cluster-owned; readers inherit them
# automatically and never re-set them.
#--------------------------------------------------------------
