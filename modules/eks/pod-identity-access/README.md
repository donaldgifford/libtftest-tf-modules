<!-- markdownlint-disable-file MD025 MD041 -->
# EKS Pod Identity Access Module

Small, single-purpose module that binds a Kubernetes service account to AWS
credentials via an EKS Pod Identity Association. Implements
[DESIGN-0004](../../../docs/design/0004-eks-pod-identity-access-module.md).
Instantiated many times per cluster — one per `(namespace, service_account)`
pair.

Two modes:

- **Mode A (default)** — module creates a Pod-Identity-trusting IAM role
  with caller-supplied managed/customer/inline policies, then registers the
  association binding the SA to that role. The standard fleet posture.
- **Mode B (escape hatch)** — caller passes `existing_role_arn` referencing
  a pre-existing Pod-Identity-trusting role. Module creates only the
  association. Use for brownfield migrations or when an IAM role's policy
  shape is owned outside this module.

The module does NOT:

- Install the Pod Identity Agent — owned by the `addons` module
  ([ADR-0003](../../../docs/adr/0003-eks-pod-identity-agent-addon-installs-first.md)).
- Create the Kubernetes ServiceAccount — delivered out-of-band (Helm /
  Kustomize / Argo CD) per
  [ADR-0011](../../../docs/adr/0011-terraform-manages-aws-api-resources-only-kubernetes-manifests-out-of-band.md).

See [USAGE.md](./USAGE.md) for the generated input / output reference.

## Mode A — typical usage (cluster-autoscaler)

```hcl
module "cluster_autoscaler_grant" {
  source = "../../modules/eks/pod-identity-access"

  remote_state_bucket = "my-tfstate-bucket"
  region              = "us-east-1"
  cluster_name        = "production-eks"

  namespace       = "kube-system"
  service_account = "cluster-autoscaler"

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AutoScalingFullAccess",
  ]

  inline_policies = {
    ec2-describe = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["ec2:DescribeLaunchTemplates", "ec2:DescribeInstanceTypes"]
          Resource = "*"
        },
      ]
    })
  }

  tags = {
    Component = "cluster-autoscaler"
  }
}
```

## Mode B — caller-owned role

```hcl
module "shared_alb_grant" {
  source = "../../modules/eks/pod-identity-access"

  remote_state_bucket = "my-tfstate-bucket"
  region              = "us-east-1"
  cluster_name        = "production-eks"

  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"

  create_role       = false
  existing_role_arn = data.terraform_remote_state.iam.outputs.alb_controller_role_arn
}
```

## Naming

The IAM role name (Mode A) defaults to:

```text
<cluster_name>-<namespace>-<service_account>
```

When this joined default exceeds IAM's 64-char hard limit, the module
truncates to 57 chars + `-` + 6-hex-char sha256 prefix (totaling 64). The
hash disambiguates names that share the same 57-char prefix so different
(namespace, service_account) pairs don't silently collide on the same
role.

To pin an explicit name, pass `role_name_override = "..."`.

## Cross-stack ordering

The fleet's operational order is:

```text
cluster  →  managed-node-group  →  addons  →  pod-identity-access
```

Pod Identity Associations are AWS API objects — they can be created at any
time. The agent (installed by the addons module) must be running on the
target nodes before the association can deliver credentials to pods. The
Terraform module does not enforce this — it is an operational property of
the consumer's Terragrunt configuration.

[Usage docs](./USAGE.md)
