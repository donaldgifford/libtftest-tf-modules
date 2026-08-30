#--------------------------------------------------------------
# Outputs — pointer-only (DESIGN-0024 part 1)
#--------------------------------------------------------------
#
# Keyed by the caller's logical entry names so downstream tooling and
# operators can resolve "which principal did we grant, and what is its
# entry ARN" without re-deriving the map.

output "access_entry_arns" {
  description = "Map of logical entry name -> EKS access entry ARN."
  value       = { for k, e in aws_eks_access_entry.this : k => e.access_entry_arn }
}

output "principal_arns" {
  description = "Map of logical entry name -> the IAM principal ARN it binds. Echoes the input for audit and for consumers that hold only this module's state."
  value       = { for k, e in aws_eks_access_entry.this : k => e.principal_arn }
}

output "policy_association_ids" {
  description = "Map of \"<entry>:<association>\" -> the policy association's ID. The flattened key shape is the module's stable addressing contract."
  value       = { for k, a in aws_eks_access_policy_association.this : k => a.id }
}
