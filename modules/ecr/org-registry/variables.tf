#--------------------------------------------------------------
# Required inputs
#--------------------------------------------------------------

variable "name_prefix" {
  description = "Short name prefix for the KMS alias, ECR-template IAM role, and publisher IAM policy. The module composes alias/<name_prefix>-ecr-oci, <name_prefix>-ecr-template, and <name_prefix>-oci-publisher from this value."
  type        = string
  nullable    = false
}

variable "organizations_org_id" {
  description = "AWS Organizations ID (o-...) used in the aws:PrincipalOrgID condition on the org-wide pull policy embedded in both creation templates. Caller-supplied — the module does NOT read this via data.aws_organizations_organization (per IMPL-0006 Q2 (a) / ADR-0001 explicit-input posture)."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organizations_org_id))
    error_message = "organizations_org_id must be an AWS Organizations ID matching ^o-[a-z0-9]{10,32}$ (e.g. o-abc1234567)."
  }

  nullable = false
}

#--------------------------------------------------------------
# Optional inputs
#--------------------------------------------------------------

variable "kms_key_arn" {
  description = "Optional caller-supplied KMS key ARN for ECR encryption. When null (default), the module creates a key + alias internally. Pattern matches the cluster module's bring-your-own KMS shape."
  type        = string
  default     = null
}

variable "helm_charts_prefix" {
  description = "ECR repository name prefix for internal Helm charts. The aws_ecr_repository_creation_template targets this prefix; first `helm push <prefix>/<chart>` auto-creates the repo under the template's policy."
  type        = string
  default     = "helm-charts"

  validation {
    condition     = var.helm_charts_prefix != "ROOT" && length(var.helm_charts_prefix) >= 2 && length(var.helm_charts_prefix) <= 256 && can(regex("^[a-zA-Z0-9_./-]+$", var.helm_charts_prefix))
    error_message = "helm_charts_prefix must be a 2-256 character string of alphanumerics / underscore / period / hyphen / slash, and must not be the catch-all special value \"ROOT\"."
  }
}

variable "tf_modules_prefix" {
  description = "ECR repository name prefix for internal Terraform modules published as OCI artifacts. Same template/auto-creation behavior as helm_charts_prefix, distinct prefix."
  type        = string
  default     = "tf-modules"

  validation {
    condition     = var.tf_modules_prefix != "ROOT" && length(var.tf_modules_prefix) >= 2 && length(var.tf_modules_prefix) <= 256 && can(regex("^[a-zA-Z0-9_./-]+$", var.tf_modules_prefix))
    error_message = "tf_modules_prefix must be a 2-256 character string of alphanumerics / underscore / period / hyphen / slash, and must not be the catch-all special value \"ROOT\"."
  }
}

variable "pre_release_retention_days" {
  description = "Days to retain pre-release / dev-tagged images before the ECR lifecycle policy prunes them. Embedded in both creation templates' lifecycle_policy JSON."
  type        = number
  default     = 90

  validation {
    condition     = var.pre_release_retention_days >= 1
    error_message = "pre_release_retention_days must be at least 1 (ECR rejects 0)."
  }
}

variable "untagged_retention_days" {
  description = "Days to retain untagged images before the ECR lifecycle policy prunes them. Embedded in both creation templates' lifecycle_policy JSON."
  type        = number
  default     = 7

  validation {
    condition     = var.untagged_retention_days >= 1
    error_message = "untagged_retention_days must be at least 1 (ECR rejects 0)."
  }
}

variable "publish_to_ssm" {
  description = "When true, the module emits two SSM Parameter Store entries (the publisher policy ARN and the full publisher policy JSON) so consumers can discover the policy programmatically. Default false — opt-in (per IMPL-0006 Q7)."
  type        = bool
  default     = false
}

variable "ssm_parameter_path_arn" {
  description = "SSM Parameter Store path for the publisher policy ARN. Same-account consumers read this to discover the policy ARN. Only used when publish_to_ssm = true."
  type        = string
  default     = "/platform/ecr-oci-publisher-policy-arn"

  validation {
    condition     = can(regex("^/", var.ssm_parameter_path_arn))
    error_message = "ssm_parameter_path_arn must start with a leading slash (SSM parameter paths require '/' as the root)."
  }
}

variable "ssm_parameter_path_json" {
  description = "SSM Parameter Store path for the publisher policy JSON. Cross-account consumers read the JSON via data.aws_ssm_parameter and recreate the policy locally in their own account. Only used when publish_to_ssm = true."
  type        = string
  default     = "/platform/ecr-oci-publisher-policy-json"

  validation {
    condition     = can(regex("^/", var.ssm_parameter_path_json))
    error_message = "ssm_parameter_path_json must start with a leading slash (SSM parameter paths require '/' as the root)."
  }
}

variable "ssm_cross_account_org_id" {
  description = "When non-null, the SSM parameters switch to Advanced tier and a resource-based policy grants ssm:GetParameter / ssm:GetParameters to aws:PrincipalOrgID = this value — letting cross-account publisher CI roles read the policy JSON. Null (default) = same-account-only mode (Standard tier, no resource-based policy)."
  type        = string
  default     = null

  validation {
    condition     = var.ssm_cross_account_org_id == null || can(regex("^o-[a-z0-9]{10,32}$", var.ssm_cross_account_org_id))
    error_message = "ssm_cross_account_org_id must be null or an AWS Organizations ID matching ^o-[a-z0-9]{10,32}$ (e.g. o-abc1234567)."
  }
}

variable "tags" {
  description = "AWS resource tags applied to every taggable resource in the module (KMS key, IAM role, IAM policy, creation templates, SSM parameters)."
  type        = map(string)
  default     = {}
}
