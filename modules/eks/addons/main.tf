#--------------------------------------------------------------
# Addons Module — entrypoint
#--------------------------------------------------------------
#
# Installs the five mandatory EKS managed addons + optional EFS
# CSI per DESIGN-0003. The eks-pod-identity-agent addon is
# installed FIRST per ADR-0003 (in pod_identity_agent.tf); every
# other addon explicitly depends_on it.
#
# AWS-credentialed addons (VPC CNI, EBS CSI, optional EFS CSI)
# use the addon-managed pod_identity_association block per
# ADR-0004 — the PIA lifecycle is tied to the addon, not a
# separate resource.
#
# Phase 4 will land kube_proxy + coredns resources here.
