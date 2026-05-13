#--------------------------------------------------------------
# Local Variables
#--------------------------------------------------------------
locals {
  tags = {
    Account     = trimprefix(var.aws_account_alias_enabled ? data.aws_iam_account_alias.this[0].account_alias : var.account_alias, "dev-")
    ClusterName = var.name
    ClusterType = "eks"
    Environment = "dev"
    Region      = data.aws_region.this.name
  }
}

