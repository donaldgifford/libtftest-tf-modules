#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------
#
# "We are just setting standard outputs we want instead of lookups"
# (the operator, INV-0011 F1 batch 4) — security_group_id is the point
# of the module. Chart-side consumers take it through live-repo values
# for the Load Balancer Controller's frontend-SG annotation; future
# Terraform consumers take it cross-stack as a
# referenced_security_group_id.

output "security_group_id" {
  description = "Security group id (sg-...). The module's primary output: the value the Load Balancer Controller's frontend-SG annotation carries, and the value a sibling stack takes as referenced_security_group_id."
  value       = aws_security_group.this.id
}

output "security_group_arn" {
  description = "Security group ARN."
  value       = aws_security_group.this.arn
}

output "security_group_name" {
  description = "PHYSICAL security group name — var.name plus the provider-generated name_prefix suffix, not var.name itself. Use this when matching what the console or the EC2 API shows; use var.name for the friendly Name tag."
  value       = aws_security_group.this.name
}

# Logical rule name → sgr-... id. The adoption and ops surface: the
# import runbook needs a rule's id to target it, and an operator
# chasing a live rule in the console needs the mapping back to the
# logical name the plan speaks in.
output "ingress_rule_ids" {
  description = "Map of logical ingress rule name to its security-group-rule id (sgr-...). Empty when ingress_rules is empty."
  value       = { for k, r in aws_vpc_security_group_ingress_rule.this : k => r.security_group_rule_id }
}

output "egress_rule_ids" {
  description = "Map of logical egress rule name to its security-group-rule id (sgr-...). Covers the typed egress_rules map ONLY — the allow_all_egress rule has no logical name and rides all_egress_rule_id instead."
  value       = { for k, r in aws_vpc_security_group_egress_rule.this : k => r.security_group_rule_id }
}

# Deliberately its own output rather than a reserved key inside
# egress_rule_ids: a reserved key would collide the moment a caller
# names an egress rule "all-egress", and a silent collision in an ops
# lookup map is a bad trade for one less output.
output "all_egress_rule_id" {
  description = "Security-group-rule id of the module's all-protocols egress rule, or null when allow_all_egress = false."
  value       = one(aws_vpc_security_group_egress_rule.all[*].security_group_rule_id)
}
