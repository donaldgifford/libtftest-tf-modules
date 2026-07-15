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
  description = "Tag filter selecting the private subnets within the discovered VPC. Defaults to { Tier = \"private\" } — the convention the fleet's test fixtures already tag with. These become the private_subnet_ids output the RDS/EKS/EFS modules consume."
  type        = map(string)
  default     = { Tier = "private" }
}

variable "public_subnet_tags" {
  description = "Tag filter selecting the public subnets within the discovered VPC. Defaults to { Tier = \"public\" }. Published as the additive public_subnet_ids output (no current consumer, but shipped for parity)."
  type        = map(string)
  default     = { Tier = "public" }
}

variable "lookup_internet_gateway" {
  description = "When true (default), look up the VPC's attached internet gateway and emit internet_gateway_id. Set false for isolated/private-only VPCs with no IGW, where the lookup would otherwise error."
  type        = bool
  default     = true
}
