#--------------------------------------------------------------
# Module outputs (consumer contract)
#
# Stable surface; renaming or removing an output breaks downstream
# consumers. proxy_security_group_id is the load-bearing one: the
# operator passes it into the target DB module's allowed_consumer_sg_ids
# on a subsequent apply to complete the proxy↔DB SG wiring (the
# reciprocal of the proxy's egress-to-DB rule — DESIGN-0010 Q3).
#--------------------------------------------------------------

output "proxy_arn" {
  description = "ARN of the RDS Proxy."
  value       = aws_db_proxy.this.arn
}

output "proxy_name" {
  description = "Name of the RDS Proxy (var.name). Used to compose this proxy's own remote-state key for downstream consumers."
  value       = aws_db_proxy.this.name
}

output "proxy_endpoint" {
  description = "Default (writer) proxy endpoint hostname. Applications connect here for read+write workloads, in place of the DB cluster/instance writer endpoint."
  value       = aws_db_proxy.this.endpoint
}

output "read_only_endpoint" {
  description = "Hostname of the READ_ONLY proxy endpoint when var.create_read_only_endpoint is set on an Aurora target; null otherwise. Routes read traffic to Aurora readers."
  value       = try(aws_db_proxy_endpoint.read_only[0].endpoint, null)
}

output "proxy_security_group_id" {
  description = "Security group ID of the proxy. Pass this into the target DB module's allowed_consumer_sg_ids on a subsequent apply so the DB tier admits the proxy on the engine port (the reciprocal of the proxy's egress-to-DB rule — DESIGN-0010 Q3)."
  value       = aws_security_group.proxy.id
}

output "proxy_role_arn" {
  description = "ARN of the IAM role the proxy assumes to read and decrypt the target's AWS-managed master secret."
  value       = aws_iam_role.proxy.arn
}
