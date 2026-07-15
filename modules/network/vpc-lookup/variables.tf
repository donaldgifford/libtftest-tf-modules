#--------------------------------------------------------------
# Discovery inputs
#--------------------------------------------------------------

variable "name" {
  description = "Logical VPC name. Used as the default tag:Name filter to discover the VPC (when var.vpc_id is null) and as the <vpc_name> segment of the remote-state key downstream modules read: <region>/vpc/<name>/terraform.tfstate."
  type        = string
  nullable    = false
}

variable "vpc_id" {
  description = "Optional explicit VPC ID. When set, the module looks the VPC up by ID and ignores tag-based discovery (var.name / var.vpc_tags). When null (default), the VPC is discovered by tag:Name = var.name plus var.vpc_tags."
  type        = string
  default     = null
}

variable "vpc_tags" {
  description = "Additional tag filters ANDed with tag:Name = var.name when discovering the VPC by tag (used only when var.vpc_id is null). Ignored when var.vpc_id is set."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Tag filter selecting the private (data-tier) subnets within the discovered VPC. Defaults to { Network = \"Private\" }. These become the private_subnet_ids output the RDS/EFS modules and EKS worker nodes consume. In the reference topology these subnets also carry the passive kubernetes.io/role/internal-elb = \"1\" tag for internal-LB auto-discovery (the AWS Load Balancer Controller reads it directly — the module does not filter on it)."
  type        = map(string)
  default     = { Network = "Private" }
}

variable "public_subnet_tags" {
  description = "Tag filter selecting the public subnets within the discovered VPC. Defaults to { Network = \"Public\" }. Published as public_subnet_ids. In the reference topology these subnets also carry the passive kubernetes.io/role/elb = \"1\" tag for internet-facing-LB auto-discovery."
  type        = map(string)
  default     = { Network = "Public" }
}

variable "private_eks_subnet_tags" {
  description = "Tag filter selecting the private EKS subnets within the discovered VPC — the internal cluster IP range the EKS control-plane ENIs use. Defaults to { Network = \"Private EKS\" }. Published as private_eks_subnet_ids; the eks/cluster module consumes this for aws_eks_cluster.vpc_config.subnet_ids (worker nodes use the plain private tier)."
  type        = map(string)
  default     = { Network = "Private EKS" }
}

variable "lookup_internet_gateway" {
  description = "When true (default), look up the VPC's attached internet gateway and emit internet_gateway_id. Set false for isolated/private-only VPCs with no IGW, where the lookup would otherwise error."
  type        = bool
  default     = true
}
