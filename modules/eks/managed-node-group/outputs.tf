#--------------------------------------------------------------
# Outputs — module's external contract per DESIGN-0001 §Outputs
#--------------------------------------------------------------

output "nodegroup_name" {
  description = "EKS managed node group name. Stable identifier; matches var.nodegroup_name."
  value       = aws_eks_node_group.this.node_group_name
}

output "architecture" {
  description = "Echo of var.architecture for downstream tooling (e.g., per-arch workload selectors)."
  value       = var.architecture
}

output "ami_type" {
  description = "AL2023 AMI type selected by EKS based on var.architecture.ami_type (e.g., AL2023_ARM_64_STANDARD)."
  value       = aws_eks_node_group.this.ami_type
}

output "node_role_arn" {
  description = "ARN of the node IAM role. Consumed by the ECR pull-through cache module's Terragrunt wiring to attach the opt-in third policy per ADR-0015."
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "Name of the node IAM role. Useful for downstream IAM lookups."
  value       = aws_iam_role.node.name
}

output "instance_profile_arn" {
  description = "ARN of the EC2 instance profile bound to the node role."
  value       = aws_iam_instance_profile.node.arn
}

output "launch_template_id" {
  description = "ID of the launch template used by the node group."
  value       = aws_launch_template.node.id
}

output "launch_template_latest_version" {
  description = "Latest version of the launch template — bumps on every change to user_data, metadata_options, etc."
  value       = aws_launch_template.node.latest_version
}

output "node_labels" {
  description = "Kubernetes node labels applied to every node (workload-class=secure, runtime=gvisor, kubernetes.io/arch, plus var.additional_labels)."
  value       = local.runtime_labels
}

output "node_taints" {
  description = "Kubernetes node taints applied to every node — the always-on workload-class=secure:NO_SCHEDULE plus var.additional_taints."
  value = concat(
    [{ key = "workload-class", value = "secure", effect = "NO_SCHEDULE" }],
    var.additional_taints,
  )
}
