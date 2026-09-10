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

### Mode B ignores the four policy inputs

`managed_policy_arns`, `customer_managed_policy_arns`,
`inline_policies` and `permissions_boundary` are **accepted and
silently ignored** when `create_role = false`. The module attaches
nothing to a role it does not own — policies for a pre-existing role
belong to whatever stack owns that role.

They are ignored rather than rejected **on purpose**: Terragrunt
injects a uniform input set into every module regardless of use
(ADR-0020 / IMPL-0015 Q6a), so a wrapper passing the same policy
inputs across both Mode A and Mode B instances is the expected
calling pattern, and failing on an unused input would break it.
DESIGN-0027 Part C proposed rejecting the combination and was
**withdrawn** for this reason.

If you set a policy input in Mode B and wonder why the permission
never appeared: this is why. Nothing in the plan will say so — the
attachments simply do not exist.

## Upgrading past v0.23.0 — re-plan first

DESIGN-0027 Part B gave the four policy inputs the validations they
had never had. This module shipped from `v0.21.0` with **zero**
validation on that surface, so four input shapes that used to plan
green now **fail at plan**:

| Shape | Why it is now rejected |
|---|---|
| A malformed or non-policy ARN in `managed_policy_arns` | Must match `arn:aws:iam::aws:policy/…` |
| A malformed ARN in `customer_managed_policy_arns` | Must match `arn:aws:iam::<12 digits>:policy/…` |
| A non-JSON string in `inline_policies` | `can(jsondecode())` |
| `permissions_boundary = ""` | Reads as "bounded" in a plan and applies as **no boundary** |

The two channel regexes partition on the account field, which is what
makes the same ARN in both channels unrepresentable (IMPL-0022's F2).
The consequence for callers: **an ARN in the wrong channel is now an
error**, where before both channels emitted an identical
`aws_iam_role_policy_attachment` and either worked.

**Moving an ARN between channels is not address-neutral.** The
attachment is keyed by channel, so the move plans as a **destroy +
create** — a real, brief window in which the policy is detached from
the role. Schedule it accordingly rather than folding it into an
unrelated apply.

Non-commercial partitions (`aws-us-gov`, `aws-cn`) are rejected by
both regexes. That is inert for this fleet; loosening it must
preserve the account-field exclusivity above.

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

## Remote-state key contract (ADR-0020)

This module **reads** the cluster's state at:

```text
<account_name>/<region>/eks/<cluster_name>/terraform.tfstate
```

`cluster_name` must equal the `eks/cluster` stack's live-repo folder name.
A mismatch fails this module's plan with `Unable to find remote state`
(the error names neither bucket nor key — diff against this contract). The
key template is pinned by a plan assertion in `tests/mode_a.tftest.hcl`;
see ADR-0020 for the fleet table.
