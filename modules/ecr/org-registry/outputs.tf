#--------------------------------------------------------------
# Consumer-facing outputs (per DESIGN-0006 §API)
#--------------------------------------------------------------

output "helm_charts_template_id" {
  description = "ID of the aws_ecr_repository_creation_template for the helm-charts/* prefix. (v6 schema exposes `id`, not `arn`.)"
  value       = aws_ecr_repository_creation_template.helm_charts.id
}

output "tf_modules_template_id" {
  description = "ID of the aws_ecr_repository_creation_template for the tf-modules/* prefix."
  value       = aws_ecr_repository_creation_template.tf_modules.id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt OCI artifact repositories. Module-managed when var.kms_key_arn is null; BYO when supplied."
  value       = local.kms_key_arn
}

output "publisher_policy_arn" {
  description = "ARN of the reusable customer-managed publisher policy. Same-account CI / IRSA roles attach this via aws_iam_role_policy_attachment. Cross-account consumers recreate the policy locally from the JSON SSM parameter (see publisher_policy_ssm_json_parameter_name)."
  value       = aws_iam_policy.oci_publisher.arn
}

output "ecr_template_role_arn" {
  description = "ARN of the ECR-assumed IAM role driving repo creation via the two aws_ecr_repository_creation_template resources. Provided for observability / cross-stack debugging; consumers should not attach this role themselves."
  value       = aws_iam_role.ecr_template.arn
}

output "publisher_policy_ssm_arn_parameter_name" {
  description = "SSM Parameter Store path where the publisher policy ARN was published (or null when var.publish_to_ssm = false). Same-account consumers read this via data.aws_ssm_parameter to discover the policy ARN dynamically."
  value       = try(aws_ssm_parameter.publisher_policy_arn[0].name, null)
}

output "publisher_policy_ssm_json_parameter_name" {
  description = "SSM Parameter Store path where the full publisher policy JSON was published (or null when var.publish_to_ssm = false). Cross-account consumers read this via data.aws_ssm_parameter and recreate the policy locally in their own accounts (IAM policies don't cross account boundaries by reference)."
  value       = try(aws_ssm_parameter.publisher_policy_json[0].name, null)
}

output "ssm_org_read_policy_json" {
  description = "Resource-based policy JSON granting org-wide ssm:GetParameter on the two SSM parameters (gated on var.publish_to_ssm AND var.ssm_cross_account_org_id != null; null otherwise). Schema-driven gap workaround: hashicorp/aws ~> 6.2 has no aws_ssm_resource_policy resource — operators attach this manually via `aws ssm put-resource-policy --resource-arn <param-arn> --policy <this>`. See README."
  value       = try(data.aws_iam_policy_document.ssm_org_read[0].json, null)
}
