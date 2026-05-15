#--------------------------------------------------------------
# Required inputs
#--------------------------------------------------------------

variable "remote_state_bucket" {
  description = "S3 bucket holding the cluster module's and VPC stack's remote state. Used by data.terraform_remote_state.eks and .vpc per ADR-0001."
  type        = string
  nullable    = false
}

variable "region" {
  description = "AWS region. Used in the remote-state key prefix and for AWS API calls."
  type        = string
  nullable    = false
}

variable "cluster_name" {
  description = "EKS cluster name. Used as the remote-state key fragment and as aws_eks_node_group.cluster_name (read from the cluster's remote state output at the use site, ADR-0001)."
  type        = string
  nullable    = false
}

variable "vpc_name" {
  description = "VPC stack name. Used in the VPC remote-state key fragment."
  type        = string
  nullable    = false
}

variable "nodegroup_name" {
  description = "Logical name of this node group. Combined with cluster_name for the IAM role + node group name."
  type        = string
  nullable    = false
}

#--------------------------------------------------------------
# Architecture (typed object per DESIGN-0001)
#--------------------------------------------------------------
#
# Caller (typically Boilerplate-generated Terragrunt) computes the
# arch-derived fields from a single "arm64" | "amd64" choice and
# passes them in as a fully-formed object. Defaults below model the
# ARM64 case per ADR-0006.

variable "architecture" {
  description = "Architecture object: name (arm64|amd64), ami_type, gvisor_arch (aarch64|x86_64), k8s_arch (arm64|amd64), and default_instance_types. Boilerplate-derived per DESIGN-0001."
  type = object({
    name                   = string
    ami_type               = string
    gvisor_arch            = string
    k8s_arch               = string
    default_instance_types = list(string)
  })
  default = {
    name                   = "arm64"
    ami_type               = "AL2023_ARM_64_STANDARD"
    gvisor_arch            = "aarch64"
    k8s_arch               = "arm64"
    default_instance_types = ["m7g.large", "m7g.xlarge", "c7g.large", "c7g.xlarge"]
  }

  validation {
    condition     = contains(["arm64", "amd64"], var.architecture.name)
    error_message = "architecture.name must be \"arm64\" or \"amd64\"."
  }

  validation {
    condition     = contains(["AL2023_ARM_64_STANDARD", "AL2023_x86_64_STANDARD"], var.architecture.ami_type)
    error_message = "architecture.ami_type must be one of AL2023_ARM_64_STANDARD or AL2023_x86_64_STANDARD (AL2023 only per ADR-0008)."
  }

  validation {
    condition     = contains(["aarch64", "x86_64"], var.architecture.gvisor_arch)
    error_message = "architecture.gvisor_arch must be \"aarch64\" or \"x86_64\"."
  }

  validation {
    condition     = contains(["arm64", "amd64"], var.architecture.k8s_arch)
    error_message = "architecture.k8s_arch must be \"arm64\" or \"amd64\" (Kubernetes node-role label)."
  }
}

#--------------------------------------------------------------
# Capacity, scaling, storage
#--------------------------------------------------------------

# tflint-ignore: terraform_unused_declarations  # consumed in a later IMPL-0002 phase
variable "instance_types" {
  description = "Override list of instance types. Empty (default) falls back to var.architecture.default_instance_types. Instance-type-vs-architecture compatibility is asserted in Phase 5 / Phase 7."
  type        = list(string)
  default     = []
}

# tflint-ignore: terraform_unused_declarations  # consumed in a later IMPL-0002 phase
variable "capacity_type" {
  description = "Node group capacity type. ON_DEMAND default per ADR-0009; SPOT permitted for explicitly batch / non-critical workloads."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be \"ON_DEMAND\" or \"SPOT\"."
  }
}

# tflint-ignore: terraform_unused_declarations  # consumed in a later IMPL-0002 phase
variable "desired_size" {
  description = "Initial desired size. After create, drift is ignored via lifecycle.ignore_changes so a cluster autoscaler can manage it without Terraform fighting back."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_size >= 0
    error_message = "desired_size must be >= 0."
  }
}

# tflint-ignore: terraform_unused_declarations  # consumed in a later IMPL-0002 phase
variable "min_size" {
  description = "Minimum node group size."
  type        = number
  default     = 0

  validation {
    condition     = var.min_size >= 0
    error_message = "min_size must be >= 0."
  }
}

# tflint-ignore: terraform_unused_declarations  # consumed in a later IMPL-0002 phase
variable "max_size" {
  description = "Maximum node group size."
  type        = number
  default     = 10

  validation {
    condition     = var.max_size >= 1
    error_message = "max_size must be >= 1."
  }
}

variable "disk_size_gib" {
  description = "Root EBS volume size in GiB. gp3, KMS-encrypted with the cluster module's KMS key (read from remote state)."
  type        = number
  default     = 100

  validation {
    condition     = var.disk_size_gib >= 20
    error_message = "disk_size_gib must be >= 20 (AL2023 minimum)."
  }
}

#--------------------------------------------------------------
# IAM additions (opt-in per ADR-0012 and ADR-0015)
#--------------------------------------------------------------

variable "enable_ssm" {
  description = "Attach AmazonSSMManagedInstanceCore to the node role for Session Manager break-glass access. Off by default per ADR-0012."
  type        = bool
  default     = false
}

variable "extra_node_policies" {
  description = "Additional managed-style IAM policy ARNs to attach to the node role. Reserved for opt-in ECR pull-through cache policy per ADR-0015. Default empty — no extra attachments unless the consumer's Terragrunt config explicitly opts in. Each ARN is attached via aws_iam_role_policy_attachment."
  type        = list(string)
  default     = []
}

#--------------------------------------------------------------
# gVisor (ADR-0005 / ADR-0010)
#--------------------------------------------------------------
#
# Renovate pins both the release identifier and the matching SHA-512
# digests for the platform binaries. The default is a known-good pin
# at IMPL-completion time; consumers may pin to a different release.

variable "gvisor_version" {
  description = "gVisor release identifier, e.g. \"release-20260101.0\". Used as the URL fragment in https://storage.googleapis.com/gvisor/releases/<release>/<arch>/. Renovate manages bumps per ADR-0010."
  type        = string
  default     = "release-20260101.0"
  validation {
    condition     = length(var.gvisor_version) > 0
    error_message = "gvisor_version must be non-empty (Renovate-pinned release identifier)."
  }
  nullable = false
}

variable "gvisor_sha512" {
  description = "SHA-512 digests for the gVisor binaries matching var.gvisor_version and var.architecture.gvisor_arch. Keys: \"runsc\", \"containerd_shim_runsc_v1\". Renovate updates this map alongside gvisor_version. Empty defaults are placeholders — wired to a real verification step in Phase 4."
  type = object({
    runsc                    = string
    containerd_shim_runsc_v1 = string
  })
  default = {
    runsc                    = ""
    containerd_shim_runsc_v1 = ""
  }
}

#--------------------------------------------------------------
# Containerd registry mirror (ECR pull-through cache; opt-in per IMPL-0005 Q8)
#--------------------------------------------------------------
#
# Bootstrap-time user-data writes /etc/containerd/config.toml.d/mirror.toml
# when enabled. Off by default — symmetry with the IAM gate from ADR-0015
# (two stages of consent: extra_node_policies attachment AND this mirror).
# A misconfigured mirror silently breaks every pod that starts on the node,
# so off-by-default keeps the boring path as the default.

variable "containerd_pull_through_mirror" {
  description = "When enabled, user data writes a containerd config drop-in redirecting upstream registries to cache_url_prefix. Requires the corresponding ECR pull-through cache module to be instantiated and the matching node IAM policy attached via var.extra_node_policies."
  type = object({
    enabled          = bool
    cache_url_prefix = optional(string)
    upstreams = optional(list(object({
      host   = string
      prefix = string
    })), [])
  })
  default = {
    enabled = false
  }

  validation {
    condition     = !var.containerd_pull_through_mirror.enabled || (var.containerd_pull_through_mirror.cache_url_prefix != null && length(var.containerd_pull_through_mirror.cache_url_prefix) > 0)
    error_message = "When containerd_pull_through_mirror.enabled is true, cache_url_prefix must be a non-empty string (e.g. \"<account-id>.dkr.ecr.<region>.amazonaws.com\")."
  }

  validation {
    condition     = !var.containerd_pull_through_mirror.enabled || length(var.containerd_pull_through_mirror.upstreams) > 0
    error_message = "When containerd_pull_through_mirror.enabled is true, upstreams must list at least one { host, prefix } pair."
  }
}

#--------------------------------------------------------------
# Labels, taints, kubelet, tags
#--------------------------------------------------------------

variable "additional_labels" {
  description = "Extra Kubernetes labels to merge onto the node group on top of the module-managed runtime / workload-class labels."
  type        = map(string)
  default     = {}
}

# tflint-ignore: terraform_unused_declarations  # consumed in a later IMPL-0002 phase
variable "additional_taints" {
  description = "Extra taints to apply on top of the always-on workload-class=secure:NO_SCHEDULE taint."
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

variable "extra_kubelet_args" {
  description = "Extra kubelet command-line arguments appended at AL2023 nodeadm bootstrap. Empty by default."
  type        = string
  default     = ""
}

variable "tags" {
  description = "AWS resource tags applied to every resource in the module."
  type        = map(string)
  default     = {}
}
