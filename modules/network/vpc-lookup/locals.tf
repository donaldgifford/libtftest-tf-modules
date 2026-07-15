locals {
  # Discover by ID xor by tag: when var.vpc_id is set, don't also
  # constrain the aws_vpc lookup by tags; otherwise match tag:Name =
  # var.name plus any extra var.vpc_tags.
  vpc_lookup_tags = var.vpc_id != null ? {} : merge({ Name = var.name }, var.vpc_tags)

  # Sorted for deterministic output ordering (aws_subnets.ids order is
  # not guaranteed stable across reads).
  private_subnet_ids = sort(data.aws_subnets.private.ids)
  public_subnet_ids  = sort(data.aws_subnets.public.ids)

  availability_zones = sort(distinct([
    for s in data.aws_subnet.private : s.availability_zone
  ]))

  internet_gateway_id = length(data.aws_internet_gateway.this) > 0 ? data.aws_internet_gateway.this[0].id : null
}
