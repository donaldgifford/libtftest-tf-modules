<!-- markdownlint-disable-file MD025 MD041 -->
# EKS ECR Pull-Through Cache Module

Fleet-shared module that provisions an ECR pull-through cache fronting up
to six upstream registries (ECR Public, Quay, Docker Hub, GHCR, Kubernetes,
MCR), each cached repo lifecycled by an `aws_ecr_repository_creation_template`,
and an opt-out IAM policy granting EKS managed nodes `ecr:CreateRepository` +
`ecr:BatchImportUpstreamImage`. Implements
[DESIGN-0005](../../../docs/design/0005-ecr-pull-through-cache-module.md).

Instantiated **once per account+region**, not per cluster — the pull-through
cache and its lifecycle template are account-level constructs. The IAM policy
output is consumed by *every* managed-node-group instance in that region via
`var.extra_node_policies` ([ADR-0015](../../../docs/adr/0015-three-managed-policies-on-the-node-role.md)).

The module does NOT:

- **Create the three VPC endpoints** the cache requires. These belong on the
  VPC module (`com.amazonaws.<region>.ecr.api`,
  `com.amazonaws.<region>.ecr.dkr`, `com.amazonaws.<region>.s3`). See
  [DESIGN-0005 §VPC Endpoints](../../../docs/design/0005-ecr-pull-through-cache-module.md)
  for the rationale.
- **Populate the Secrets Manager credentials.** The module creates the
  secret + an initial placeholder version (`{"username":"REPLACE_ME",
  "accessToken":"REPLACE_ME"}`) and uses
  `lifecycle.ignore_changes = [secret_string]` so the operator-rotated
  value isn't clobbered on later applies. See the post-apply step below.
- **Rewrite image references.** Helm chart values / Kustomize patches /
  workload manifests still point at `docker.io/library/nginx`. Rewriting to
  `<account>.dkr.ecr.<region>.amazonaws.com/docker-hub/library/nginx` is the
  delivery layer's job (per [ADR-0011](../../../docs/adr/0011-terraform-manages-aws-api-resources-only-kubernetes-manifests-out-of-band.md)).

See [USAGE.md](./USAGE.md) for the generated input / output reference.

## Prerequisites

### Three VPC endpoints on the cluster's VPC

The pull-through cache is reached by nodes through these three endpoints
(if your nodes run in private subnets, which is the default fleet posture):

- `com.amazonaws.<region>.ecr.api` (Interface endpoint)
- `com.amazonaws.<region>.ecr.dkr` (Interface endpoint)
- `com.amazonaws.<region>.s3` (Gateway endpoint — ECR-on-S3 layer storage)

Missing any one of these means pull-through reaches the public Internet (or
fails entirely if the subnet has no NAT/IGW). This is the most common
production tripwire — the cache plan/apply succeeds, but `crictl pull`
through the cache URL hangs at the manifest-resolve step.

## Typical instantiation

```hcl
module "ecr_pull_through_cache" {
  source = "../../modules/eks/ecr-pull-through-cache"

  region              = "us-east-1"
  name_prefix         = "platform"
  upstream_registries = ["ecr-public", "docker-hub", "kubernetes", "quay"]

  untagged_image_retention_days = 14

  tags = {
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}
```

## Post-apply: populate the Secrets Manager credentials

For authenticated upstreams (`docker-hub`, `ghcr`), the module writes a
placeholder secret version on first apply. Replace it with real credentials:

```bash
# Docker Hub (use a Personal Access Token, not your account password)
aws secretsmanager put-secret-value \
  --secret-id ecr-pullthroughcache/platform-docker-hub \
  --secret-string '{"username":"<dockerhub_user>","accessToken":"<dockerhub_pat>"}'

# GitHub Container Registry (use a fine-grained PAT scoped to read:packages)
aws secretsmanager put-secret-value \
  --secret-id ecr-pullthroughcache/platform-ghcr \
  --secret-string '{"username":"<github_user>","accessToken":"<github_pat>"}'
```

`lifecycle.ignore_changes = [secret_string]` on the version resource means
subsequent `terraform apply` runs won't revert this value. Rotation is an
operator workflow, not a Terraform-managed loop.

## Consumer integration: wire the IAM policy into managed nodes

The module emits `node_pull_through_policy_arn` — wire it into every
managed-node-group consumer via the
[ADR-0015](../../../docs/adr/0015-three-managed-policies-on-the-node-role.md)
third-managed-policy carve-out:

```hcl
module "node_group_secure" {
  source = "../../modules/eks/managed-node-group"

  # ... required inputs (cluster_name, vpc_name, etc.) ...

  extra_node_policies = [
    module.ecr_pull_through_cache.node_pull_through_policy_arn,
  ]
}
```

This is **gate (b) of ADR-0015's two-stages-of-consent**. The module's
`var.enable_node_pull_through_policy` (default `true`) is gate (a):
emission. Both gates must close for nodes to actually receive the
permission — either consent alone is a no-op.

When `enable_node_pull_through_policy = false`, the output is `null` and
passing it to a node group is a plan-time failure (intentional —
configuration is unambiguous when both ends agree).

## Cache URL construction

Outputs.tf exposes `cache_url_prefixes` — a map keyed by upstream name
yielding the fully-qualified ECR cache URL prefix:

```text
<account_id>.dkr.ecr.<region>.amazonaws.com/<prefix>
```

Pull through the cache by rewriting image references at the delivery
layer:

```text
docker.io/library/nginx:1.27
→ <account_id>.dkr.ecr.<region>.amazonaws.com/docker-hub/library/nginx:1.27

registry.k8s.io/pause:3.10
→ <account_id>.dkr.ecr.<region>.amazonaws.com/kubernetes/pause:3.10
```

Rewriting is **out-of-scope of this module** — perform it in your Helm chart
values, Kustomize patches, or via a global Helm/Kustomize `image:` prefix.

[Usage docs](./USAGE.md)
