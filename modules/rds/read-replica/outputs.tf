#--------------------------------------------------------------
# Module outputs
#
# Per-reader identifier + endpoint maps, keyed as var.replicas, for
# targeted routing (e.g. pinning an analytics job to a specific reader).
# The cluster's own reader_endpoint remains the load-balanced entry
# point across all readers — this module does not create a new pooled
# endpoint (DESIGN-0014 non-goal).
#--------------------------------------------------------------

output "replica_identifiers" {
  description = "Map of reader instance identifiers keyed as var.replicas (key => <identifier_prefix>-replica-<key>). Useful for AWS CLI / SDK operations targeting a specific reader (e.g., reboot-db-instance)."
  value       = { for k, r in aws_rds_cluster_instance.replica : k => r.identifier }
}

output "replica_endpoints" {
  description = "Map of per-reader endpoint hostnames keyed as var.replicas. Connect here to pin read traffic to a specific reader; use the cluster's reader_endpoint for load-balanced reads across all readers."
  value       = { for k, r in aws_rds_cluster_instance.replica : k => r.endpoint }
}
