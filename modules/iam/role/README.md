<!-- markdownlint-disable-file MD025 MD041 -->
# IAM Role (generic trust-boundary role)

One generic module for standalone **trust-boundary** roles — roles
assumed by other IAM principals
([DESIGN-0025](../../../docs/design/0025-generic-iam-role-module.md)),
replacing the queued `iam/deploy-role` + `iam/cross-account-role`
pair: the two patterns have identical resource surfaces and differ
only in their inputs, so **the inputs define what an instance is**.

## Scope: what this module is not for

- **Service-principal roles** (EC2 instance profiles, Lambda
  execution roles, `pods.eks.amazonaws.com`) — resource-owning
  modules mint their own service roles (`eks/cluster`,
  `managed-node-group`, `eks/pod-identity-access`,
  `bedrock/claude-code` all do). `trusted_role_arns` rejects a
  service principal at plan rather than silently composing a trust
  policy nobody reviewed for it.
- **Standalone policy management** — v1 attaches existing policy
  ARNs and writes inline documents. Creating `aws_iam_policy`
  resources belongs to a future `iam/policy` sibling so a policy
  shared by two roles has an unambiguous owner.
- **SSO permission sets, OIDC/SAML providers, instance profiles** —
  different lifecycles, different owners.

## Trust is fail-closed and typed

`trusted_role_arns` takes exact IAM role/user ARNs and nothing else.
Wildcards are rejected, the list must be non-empty, and duplicates
are rejected (IAM dedupes them anyway — but the trust list is an
audit surface reviewers count, so it states each principal exactly
once). There is deliberately **no raw-JSON trust channel**: a JSON
escape hatch bypasses every one of those rules, which is the
fail-open this typed surface exists to prevent.

Trust conditions (`sts:ExternalId` first) are a recorded follow-up,
additive — the v1 single-statement composition is built so a
conditions block slots in without reshaping the variable.

## Worked example 1 — the per-account deploy role

The role every ADR-0020 remote-state read assumes. Its name is
load-bearing fleet-wide: every consumer composes
`arn:aws:iam::<account_id>:role/<deploy_role_name>`, which is why
this module takes an **exact `name`** with no prefix or suffix.

```hcl
module "deploy_role" {
  source = "../../modules/iam/role"

  name        = "deploy-tf" # == the fleet's deploy_role_name global
  description = "Terraform deploy role assumed by hub automation"

  # The hub automation principals. The Atlantis pod-identity role is
  # the same stable-creator principal DESIGN-0024 OQ 4 sanctions for
  # cluster creation — applies run through it, never through an
  # ad-hoc SSO session whose AWSReservedSSO_* suffix rotates.
  trusted_role_arns = [
    "arn:aws:iam::111122223333:role/atlantis-pod-identity",
  ]

  # The account's deploy policy. Its CONTENT is the caller's concern
  # — typically broad; this module does not opine.
  customer_managed_policy_arns = [
    "arn:aws:iam::444455556666:policy/deploy-tf",
  ]

  tags = { ManagedBy = "terraform" }
}
```

## Worked example 2 — `sse-platform-access`

The spoke-side half of the platform's DESIGN-0001 §4 access path: the
hub argocd-deployer assumes this role in each spoke account, and the
assumed role binds to a deploy RBAC group **cluster-side**.

```hcl
module "platform_access" {
  source = "../../modules/iam/role"

  name        = "sse-platform-access"
  description = "Assumed by the hub argocd-deployer to reach this spoke's cluster"

  trusted_role_arns = [
    "arn:aws:iam::111122223333:role/hub-argocd-deployer",
  ]

  inline_policies = {
    eks-access = data.aws_iam_policy_document.eks_access.json
  }
}
```

**The cluster-side half is not this module's.** Binding the assumed
role to a Kubernetes group is an
[`eks/access-entries`](../../eks/access-entries/) entry
([DESIGN-0024](../../../docs/design/0024-eks-hub-posture-access-entries-endpoint-fence-and-workload.md)),
in its own stack, so access churn never plans against the
control-plane stack. Pass **`module.platform_access.role_arn`
verbatim** into that entry — see the path note below.

## Paths: one role, two ARN spellings

`path` defaults to `"/"` and should usually stay there.

A role with a non-default path has **two legitimate ARN spellings** —
path-bearing (`arn:aws:iam::…:role/platform/Name`, what IAM returns)
and path-stripped (`arn:aws:iam::…:role/Name`). Spelling mismatches
are exactly where guards and validations get evaded: IMPL-0020's
security review found the `eks/access-entries` collision guard
letting a second spelling through, and it now normalizes for this
reason. Two consequences:

- **`trusted_role_arns` entries must be the real, path-bearing
  ARNs.** IAM validates principals when the policy is saved, and
  role names are account-unique regardless of path, so a stripped
  spelling of a path-bearing role fails the apply rather than
  quietly matching something else.
- **Keep `path = "/"` for roles destined for an access-entries
  binding.** The shipped access-entries validation and collision
  guard handle both spellings, but how the EKS API *canonicalizes*
  path-bearing principal ARNs is unverified until IMPL-0020 task
  5.4's live runs answer it.

## Adopting an existing role

The deploy roles already exist outside Terraform in most accounts, so
this module's real job is **adoption, not greenfield creation** — the
brownfield import-first doctrine from INV-0004. IAM imports cleanly
and piecewise, and trust-policy diffs converge in place: IAM is
metadata, so there is no replacement and no downtime.

**Match reality first, converge second.** Write the module inputs to
mirror the live role verbatim (trust ARNs, attachments, inline
documents), import, verify the plan is zero-diff, and only then
converge conventions (description, tags, session duration) in later
reviewed plans. Converging in the same change as the import turns a
provably-empty plan into one nobody can read.

Import blocks live in the **live repo's** stacks, targeting this
module's addresses:

```hcl
# 1. the role itself — by name
import {
  to = module.deploy_role.aws_iam_role.this
  id = "deploy-tf"
}

# 2. each managed/customer attachment — <role-name>/<policy-arn>
import {
  to = module.deploy_role.aws_iam_role_policy_attachment.customer["arn:aws:iam::444455556666:policy/deploy-tf"]
  id = "deploy-tf/arn:aws:iam::444455556666:policy/deploy-tf"
}

# 3. each inline policy — <role-name>:<policy-name>
import {
  to = module.deploy_role.aws_iam_role_policy.inline["eks-access"]
  id = "deploy-tf:eks-access"
}
```

The attachment and inline addresses key by policy ARN and policy
name, so adding or removing one entry later never churns a sibling's
address.

## Remote-state key contract

Published at the **platform-reserved iam shape**
(`ADR-0020`):

```text
<account_name>/<region>/iam/<name>/terraform.tfstate
```

`<name>` is the standard triple coupling — role name == live-repo
folder == future consumer input. No Terraform consumer is wired in
v1; the row reserves the shape the way `secrets` was reserved ahead
of its consumer, because a producer publishing into an undocumented
shape is the alternative, not publishing nothing. Foreseeable first
consumer: a spoke's platform-access stack reading a hub principal's
`role_arn`.

## Tests

| Suite | Tier | What it proves |
|-------|------|----------------|
| `tests/` | plan (the gate) | Both §4 shapes with the trust JSON asserted by content; the three policy channels and their address stability; eleven fail-closed rejections, each verified to fire its own rule |
| `tests-localstack/` | Community apply | The IAM surface round-trips live — see `FINDINGS.md` for what a LocalStack apply can and cannot prove about trust |

Full variable/output reference: [USAGE.md](USAGE.md).
