# Provider default_tags coverage (DESIGN-0029 / IMPL-0026 3.1).
#
# The module declares no tags input: the fleet's standard tag set arrives
# through the provider's default_tags, set in the live repo's generated
# provider block. This run proves the probe key reaches the security group and every rule resource.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  default_tags {
    tags = { DefaultTagProbe = "design-0029" }
  }
}

variables {
  name     = "gateway-frontend-public"
  vpc_name = "libtftest-vpc"
}

override_data {
  target = data.terraform_remote_state.vpc
  values = {
    outputs = {
      vpc_id             = "vpc-0123456789abcdef0"
      private_subnet_ids = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
    }
  }
}

run "default_tags_reach_every_resource" {
  command = plan

  variables {
    ingress_rules = {
      corp = { description = "corp", from_port = 443, cidr_ipv4 = "203.0.113.0/24" }
    }
  }

  assert {
    condition     = aws_security_group.this.tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the security group (tags_all)"
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.this["corp"].tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach an ingress rule (tags_all)"
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.all[0].tags_all["DefaultTagProbe"] == "design-0029"
    error_message = "provider default_tags must reach the all-egress rule (tags_all)"
  }
}
