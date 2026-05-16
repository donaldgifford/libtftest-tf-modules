#--------------------------------------------------------------
# Pod Identity Access Module — entrypoint
#--------------------------------------------------------------
#
# Binds a Kubernetes service account to AWS credentials via an
# EKS Pod Identity Association per DESIGN-0004 / ADR-0004. This
# module is instantiated many times per cluster — one per
# (namespace, service_account) pair.
#
# Mode A (default): the module creates a Pod-Identity-trusting
# IAM role in iam.tf with caller-supplied managed/customer/
# inline policies, and the association binds to it.
#
# Mode B (escape hatch): the caller passes existing_role_arn;
# the module creates only the association.
#
# Phase 5 will land aws_eks_pod_identity_association.this here.
