# access-entries

[Usage docs](./USAGE.md)

Binds arbitrary IAM principals to an existing EKS cluster as access entries,
with per-entry policy associations and full namespace scoping. Design:
[DESIGN-0024 part 1](../../../docs/design/0024-eks-hub-posture-access-entries-endpoint-fence-and-workload.md).

## Why this is its own stack

Access entries are the highest-churn cluster-adjacent surface — principals
onboard, scopes tighten, break-glass rotates. In the cluster module every one
of those edits would plan against (and lock) the stack that owns the control
plane, the KMS key, and the node security group, so a typo in an access entry
would be reviewed alongside cluster-mutating changes. As its own stack, entry
churn is a small, fast, low-blast-radius plan — the same isolation `rds/proxy`
and `rds/read-replica` have against `rds/cluster`, and the same seam
`eks/pod-identity-access` already proves for per-cluster IAM surfaces.

The **SSO entry stays in `eks/cluster`** and is not managed here (see the
collision guard below).

## Usage — the platform §4 principals

```hcl
module "access_entries" {
  source = "..."

  cluster_name = "sse-mgmt-hub"
  # ... the six Terragrunt globals

  access_entries = {
    # The hub argocd-deployer assumes this spoke's platform-access role;
    # the assumed role binds to the deploy RBAC group.
    argocd_deployer = {
      principal_arn     = "arn:aws:iam::<spoke-account>:role/sse-platform-access"
      kubernetes_groups = ["deploy"]
      user_name         = "argocd-deployer"
    }

    break_glass = {
      principal_arn = "arn:aws:iam::<account>:role/BreakGlassAdmin"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        }
      }
    }

    # The durable admin once day-0 completes — see "Day-0 ordering".
    deploy_role = {
      principal_arn = "arn:aws:iam::<account>:role/deploy-role"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        }
        app_namespaces = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = ["apps", "platform"]
          }
        }
      }
    }
  }
}
```

Principals are **direct ARNs with no resolution**: spokes are separate AWS
accounts, so the in-account regex resolution the cluster module's SSO path uses
cannot reach them.

`policy_arn` takes the **full** EKS cluster-access-policy ARN (validated by
prefix). AWS grows that catalog independently of this module, so a new policy
needs no module release — while a pasted IAM policy ARN still fails at plan.

### Addressing

Both maps are keyed by **logical name**, and associations flatten to
`"<entry>:<association>"`. The keys are the Terraform addresses, so re-pointing
a principal (an SSO permission set re-mints its role suffix; a deploy role is
recreated) or adding an association never churns a sibling.

## Cross-stack collision guard

`eks/cluster` owns the SSO principal's access entry. Because the two surfaces
now live in different stacks, declaring that same principal here would mean two
stacks own one AWS resource — which AWS reports only at apply, and which turns
into a permanent fight over that entry's policies.

This module reads the cluster's `sso_principal_arn` output and **fails at plan**
if any entry names it.

> [!NOTE]
> `sso_principal_arn` is an additive output from DESIGN-0024. A cluster stack
> that has not re-applied since will have state without it, and the guard's read
> is `try()`-wrapped so that **degrades to no-guard rather than breaking every
> plan here**. If you want the guard armed, re-apply the cluster stack once.

## Day-0 ordering

This stack applies **after** the cluster stack — it reads the cluster's remote
state. During that window the access floor is the cluster creator's bootstrap
admin entry (see the cluster module's README), so a wrong or absent entries
stack can never lock the fleet out of a fresh cluster. Once this stack applies,
the declared map is the durable access surface.

## Remote-state key contract (ADR-0020)

This module reads the cluster stack's state at the account-scoped key:

```text
<account_name>/<region>/eks/<cluster_name>/terraform.tfstate
```

`<cluster_name>` is triple-coupled: the producer's cluster name, the producer's
live-repo folder, and this module's `cluster_name` input must all match. A
mismatch fails this stack's plan loudly but vaguely (`Unable to find remote
state` — the error names neither bucket nor key), so the composed key is pinned
by an assertion in `tests/default.tftest.hcl`.

## Testing

Plan-only `tests/` is the gate (`just tf test eks/access-entries`): the hub §4
trio, the empty-map bring-up state, every validation guard, the collision guard
armed, and its stale-state degrade path.
