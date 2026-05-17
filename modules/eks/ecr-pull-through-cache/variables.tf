#--------------------------------------------------------------
# Required inputs
#--------------------------------------------------------------

variable "region" {
  description = "AWS region. Used in the IAM policy's Resource ARN scope and the cache_url_prefixes output. The module is per-region — instantiate once per region the cluster runs in."
  type        = string
  nullable    = false
}

variable "name_prefix" {
  description = "Short name prefix for the Secrets Manager secret names and the IAM policy. The Secrets Manager prefix follows ECR's required \"ecr-pullthroughcache/\" — this prefix is appended as ecr-pullthroughcache/<name_prefix>-<upstream>."
  type        = string
  nullable    = false
}

variable "upstream_registries" {
  description = "List of upstream registries to cache. Supported values: ecr-public, quay, docker-hub, ghcr, kubernetes, mcr. docker-hub and ghcr are authentication-required; the others are open."
  type        = list(string)

  validation {
    condition     = length(var.upstream_registries) > 0
    error_message = "upstream_registries must contain at least one supported value (instantiating the module with an empty list is a misconfiguration)."
  }

  validation {
    condition     = alltrue([for u in var.upstream_registries : contains(["ecr-public", "quay", "docker-hub", "ghcr", "kubernetes", "mcr"], u)])
    error_message = "Each upstream must be one of: ecr-public, quay, docker-hub, ghcr, kubernetes, mcr."
  }

  nullable = false
}

#--------------------------------------------------------------
# Optional inputs
#--------------------------------------------------------------

variable "enable_node_pull_through_policy" {
  description = "When true (default), the module emits aws_iam_policy.node_pull_through carrying ecr:CreateRepository + ecr:BatchImportUpstreamImage scoped to this account's ECR repository ARNs. Consumers wire the ARN into the managed-node-group module's var.extra_node_policies. Off → zero IAM policy resources emitted (ADR-0015 two-stages-of-consent first gate)."
  type        = bool
  default     = true
}

variable "repo_creation_template_prefix" {
  description = "Prefix passed to aws_ecr_repository_creation_template. Default \"*\" matches every pull-through-created repo. Override only when you need to scope the template to a specific upstream prefix (e.g. \"docker-hub\")."
  type        = string
  default     = "*"
}

variable "untagged_image_retention_days" {
  description = "Days to retain untagged images pulled through the cache before the ECR lifecycle policy prunes them. Embedded in the creation template's lifecycle_policy JSON."
  type        = number
  default     = 7

  validation {
    condition     = var.untagged_image_retention_days >= 1
    error_message = "untagged_image_retention_days must be at least 1 (ECR rejects 0)."
  }
}

variable "tags" {
  description = "AWS resource tags applied to every taggable resource in the module (Secrets Manager secrets, IAM policy, creation template)."
  type        = map(string)
  default     = {}
}
