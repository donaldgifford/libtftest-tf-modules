#--------------------------------------------------------------
# Outputs (caller contract per DESIGN-0004)
#--------------------------------------------------------------

output "role_arn" {
  description = "ARN of the Pod-Identity-trusting IAM role bound to (var.namespace, var.service_account). Mode A: the role created by this module. Mode B: var.existing_role_arn echoed back."
  value       = var.create_role ? aws_iam_role.this[0].arn : var.existing_role_arn
}

output "association_id" {
  description = "EKS Pod Identity Association ID. Stable handle for the (cluster_name, namespace, service_account, role_arn) tuple."
  value       = aws_eks_pod_identity_association.this.association_id
}

output "namespace" {
  description = "Echo of var.namespace. Useful for multi-instance for_each compositions that key by (namespace, service_account)."
  value       = var.namespace
}

output "service_account" {
  description = "Echo of var.service_account. Useful for multi-instance for_each compositions that key by (namespace, service_account)."
  value       = var.service_account
}
