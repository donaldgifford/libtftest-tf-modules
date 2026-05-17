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

  # tflint-ignore: terraform_unused_declarations  # consumed by aws_secretsmanager_secret.upstream and the credential_arn lookup in Phases 3 + 4
  authenticated = { for name, cfg in local.selected : name => cfg if cfg.auth_required }

  # tflint-ignore: terraform_unused_declarations  # consumed by aws_iam_policy.node_pull_through and the cache_url_prefixes output in later phases
  account_id = data.aws_caller_identity.current.account_id
}
