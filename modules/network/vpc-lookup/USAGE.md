<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.1 |
| aws | ~> 6.2 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.54.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/internet_gateway) | data source |
| [aws_nat_gateways.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/nat_gateways) | data source |
| [aws_route_tables.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route_tables) | data source |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_subnets.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnets) | data source |
| [aws_subnets.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnets) | data source |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| lookup\_internet\_gateway | When true (default), look up the VPC's attached internet gateway and emit internet\_gateway\_id. Set false for isolated/private-only VPCs with no IGW, where the lookup would otherwise error. | `bool` | `true` | no |
| name | Logical VPC name. Used as the default tag:Name filter to discover the VPC (when var.vpc\_id is null) and as the <vpc\_name> segment of the remote-state key downstream modules read: <region>/vpc/<name>/terraform.tfstate. | `string` | n/a | yes |
| private\_subnet\_tags | Tag filter selecting the private subnets within the discovered VPC. Defaults to { Tier = "private" } — the convention the fleet's test fixtures already tag with. These become the private\_subnet\_ids output the RDS/EKS/EFS modules consume. | `map(string)` | ```{ "Tier": "private" }``` | no |
| public\_subnet\_tags | Tag filter selecting the public subnets within the discovered VPC. Defaults to { Tier = "public" }. Published as the additive public\_subnet\_ids output (no current consumer, but shipped for parity). | `map(string)` | ```{ "Tier": "public" }``` | no |
| vpc\_id | Optional explicit VPC ID. When set, the module looks the VPC up by ID and ignores tag-based discovery (var.name / var.vpc\_tags). When null (default), the VPC is discovered by tag:Name = var.name plus var.vpc\_tags. | `string` | `null` | no |
| vpc\_tags | Additional tag filters ANDed with tag:Name = var.name when discovering the VPC by tag (used only when var.vpc\_id is null). Ignored when var.vpc\_id is set. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| availability\_zones | Sorted distinct AZs spanned by the private subnets. Additive — useful for callers that need to co-locate resources with the DB/compute tier. |
| internet\_gateway\_id | ID of the VPC's attached internet gateway, or null when var.lookup\_internet\_gateway = false / none is attached. Additive. |
| nat\_gateway\_ids | Sorted IDs of the NAT gateways in the VPC (empty when none). Additive. |
| private\_subnet\_ids | Sorted IDs of the private subnets (tag filter var.private\_subnet\_tags). Contract output — RDS DB subnet groups, EKS vpc\_config, and EFS mount targets consume this. Spans >= 2 AZs when the source VPC is laid out correctly (INV-0004 Finding 4). |
| public\_subnet\_ids | Sorted IDs of the public subnets (tag filter var.public\_subnet\_tags). Additive — no current consumer, shipped for parity with the future modules/network/vpc. |
| route\_table\_ids | Sorted IDs of the route tables in the VPC (includes the main route table). Additive — the future modules/network/vpc will split public/private route-table outputs. |
| vpc\_cidr\_block | Primary IPv4 CIDR block of the discovered VPC. Additive. |
| vpc\_id | ID of the discovered VPC. Contract output — read by every downstream RDS/EKS/EFS module's security group + subnet group. |
<!-- END_TF_DOCS -->
