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

# Terragrunt-injected multi-account remote-state inputs (IMPL-0015). In
# production these come from Terragrunt includes; in tests from the shared
# test/fixtures/terragrunt-inputs.tfvars via the `just tf test*` recipes.
# Required (no default) — production always injects them and a wrong default
# would silently mis-scope the cross-account remote-state read. Both the eks
# and vpc reads use them.

variable "account_name" {
  description = "Terragrunt account name — the <account_name> prefix of the account-scoped remote-state keys this module reads (<account_name>/<region>/{eks,vpc}/<name>/terraform.tfstate)."
  type        = string
  nullable    = false
}

variable "account_id" {
  description = "12-digit AWS account ID that owns the remote-state bucket. Composed into the assume_role role_arn (arn:aws:iam::<account_id>:role/<deploy_role_name>) for the cross-account state reads."
  type        = string
  nullable    = false
}

variable "remote_state_bucket_region" {
  description = "Region of the remote-state S3 bucket — distinct from var.region (the deployment region) in production Terragrunt. The terraform_remote_state backends read from this region."
  type        = string
  nullable    = false
}

variable "deploy_role_name" {
  description = "Name of the IAM role Terraform assumes to read the remote-state bucket cross-account. Composed into the assume_role role_arn with account_id."
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

variable "instance_types" {
  description = "Override list of instance types. Empty (default) falls back to var.architecture.default_instance_types. Instance-type-vs-architecture compatibility is asserted in Phase 5 / Phase 7."
  type        = list(string)
  default     = []
}

variable "capacity_type" {
  description = "Node group capacity type. ON_DEMAND default per ADR-0009; SPOT permitted for explicitly batch / non-critical workloads."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be \"ON_DEMAND\" or \"SPOT\"."
  }
}

variable "desired_size" {
  description = "Initial desired size. After create, drift is ignored via lifecycle.ignore_changes so a cluster autoscaler can manage it without Terraform fighting back."
  type        = number
  default     = 1

  validation {
    condition     = var.desired_size >= 0
    error_message = "desired_size must be >= 0."
  }
}

variable "min_size" {
  description = "Minimum node group size."
  type        = number
  default     = 0

  validation {
    condition     = var.min_size >= 0
    error_message = "min_size must be >= 0."
  }
}

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
# Workload class (DESIGN-0024 part 3)
#--------------------------------------------------------------
#
# The platform class taxonomy (platform DESIGN-0001 §2) parameterized:
# this single input drives the workload-class label, the matching
# NO_SCHEDULE taint, and (Phase 4) the gVisor default. Before
# DESIGN-0024 the module hardwired the "secure" class in five places;
# the default is now "core" — a deliberate default-behavior change
# made while the module had zero live consumers (INV-0011 OQ 13).

variable "workload_class" {
  description = "Platform workload class for this node group. Drives the workload-class label (always), the workload-class=<class>:NO_SCHEDULE taint (every class EXCEPT core — core is the untainted default landing zone), and the gVisor default (secure only). The class taxonomy is the platform's (DESIGN-0001 section 2); new classes are deliberate one-line enum additions here, never free-form."
  type        = string
  default     = "core"

  validation {
    condition     = contains(["core", "observability", "analytics", "temporal", "secure"], var.workload_class)
    error_message = "workload_class must be one of core, observability, analytics, temporal, secure (the platform class taxonomy; adding a class is a module change, not a caller string)."
  }

  nullable = false
}

#--------------------------------------------------------------
# gVisor (ADR-0005 / ADR-0010)
#--------------------------------------------------------------
#
# Renovate pins both the release identifier and the matching SHA-512
# digests for the platform binaries. The default is a known-good pin
# at IMPL-completion time; consumers may pin to a different release.

variable "gvisor_enabled" {
  description = "Nullable override for the gVisor runtime install + runtime=gvisor labeling + kubelet fragments. Null (default) = the class rule: enabled iff workload_class == \"secure\". Set true/false to override for the odd case (e.g. a sandboxed analytics pool, or a secure group whose sandboxing is handled elsewhere)."
  type        = bool
  default     = null
}

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
  description = "Extra Kubernetes labels to merge onto the node group on top of the module-managed runtime / workload-class / arch labels. The module-managed keys are reserved: they are derived from workload_class and effective gVisor and are also written into the kubelet bootstrap flags, so overriding them here would desynchronize the two label paths."
  type        = map(string)
  default     = {}

  # This merge wins on key collision, and only the EKS-API label path
  # sees it — the kubelet --node-labels fragment is composed from the
  # class rules alone. Overriding a managed key would therefore make a
  # node advertise something its bootstrap never applied: notably
  # runtime=gvisor on a node with no runsc installed, which is exactly
  # the lie local.gvisor_effective exists to prevent.
  validation {
    condition     = length(setintersection(keys(var.additional_labels), ["workload-class", "runtime", "kubernetes.io/arch"])) == 0
    error_message = "additional_labels must not set the module-managed keys workload-class, runtime, or kubernetes.io/arch. Use var.workload_class, var.gvisor_enabled, and var.architecture — those drive both the EKS-API labels and the kubelet bootstrap flags together, which a raw label override would desynchronize."
  }
}

variable "additional_taints" {
  description = "Extra taints to apply on top of the class taint (workload-class=<var.workload_class>:NO_SCHEDULE, emitted for every class except the untainted core)."
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
