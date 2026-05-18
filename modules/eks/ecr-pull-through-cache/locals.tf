#--------------------------------------------------------------
# Upstream catalog
#--------------------------------------------------------------
#
# Static mapping of supported upstream name → ECR prefix +
# upstream URL + auth_required flag. The six DESIGN-0005
# upstreams: ECR Public, Quay, Docker Hub, GHCR, Kubernetes,
# MCR. Docker Hub and GHCR are the only authenticated ones.

locals {
  upstream_catalog = {
    "ecr-public" = { prefix = "ecr-public", upstream_url = "public.ecr.aws", auth_required = false }
    "quay"       = { prefix = "quay", upstream_url = "quay.io", auth_required = false }
    "docker-hub" = { prefix = "docker-hub", upstream_url = "registry-1.docker.io", auth_required = true }
    "ghcr"       = { prefix = "ghcr", upstream_url = "ghcr.io", auth_required = true }
    "kubernetes" = { prefix = "kubernetes", upstream_url = "registry.k8s.io", auth_required = false }
    "mcr"        = { prefix = "mcr", upstream_url = "mcr.microsoft.com", auth_required = false }
  }

  selected = { for name in var.upstream_registries : name => local.upstream_catalog[name] }

  authenticated = { for name, cfg in local.selected : name => cfg if cfg.auth_required }

  account_id = data.aws_caller_identity.current.account_id
}
