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

## Trust conditions

Two optional inputs narrow *who* may assume the role beyond naming
them. Both are unset by default and add nothing:

| Input | Renders |
|---|---|
| `require_org_ids` (`list(string)`) | `StringEquals` on `aws:PrincipalOrgID` |
| `external_id` (`string`) | `StringEquals` on `sts:ExternalId` |

```hcl
require_org_ids = ["o-a1b2c3d4e5"]   # principals must be in this org
external_id     = "hub-to-spoke-42"  # ...AND present this external id
```

**`require_org_ids` is what mitigates the cross-account dangling
principal** described below: a squatted role in an account outside
your organizations cannot assume this role no matter what the trust
list literally says. Its limit, stated plainly — it does **nothing**
for a typo naming a nonexistent role *inside* the org. It shrinks the
blast radius; correct ARNs remain the primary control.

### How these combine (IAM's three rules disagree)

| Level | Combines as |
|---|---|
| values inside one condition | **OR** — "in **any** of these orgs" |
| conditions inside one statement | **AND** — org **and** external id |
| statements inside one document | **OR** |

Both conditions therefore compose into the module's **single**
statement, and that is a security property rather than a style
choice: splitting them across statements would turn the AND into an
OR, letting either condition alone grant the assume. The plan suite
pins the statement count at 1 in every conditions run.

One rendering detail if you write your own assertions: conditions
sharing a test operator **merge**, so both keys land inside one
`StringEquals` object — `length(Condition)` is 1, not 2. And a single
org id renders as a bare string where two render a list.

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
  ARNs.** The module rejects the two spellings of one principal at
  plan, comparing normalized `<account>/<name>` lowercased and
  path-stripped (the IMPL-0020 collision-guard rule) — but see the
  cross-account caveat immediately below, because that plan-time
  check is the *only* one you get for a principal in another
  account.
- **Keep `path = "/"` for roles destined for an access-entries
  binding.** The shipped access-entries validation and collision
  guard handle both spellings, but how the EKS API *canonicalizes*
  path-bearing principal ARNs is unverified until IMPL-0020 task
  5.4's live runs answer it.

### The apply-time backstop is same-account only

**Corrected after the IMPL-0022 security review** — an earlier
version of this section claimed a wrong ARN spelling "fails the apply
rather than quietly matching something else." That holds only for
**same-account** principals, where IAM resolves the ARN to the
principal's unique id when the trust policy is saved and rejects one
it cannot resolve.

**Cross-account, there is no such check.** IAM cannot resolve a
principal in an account it does not own, so the ARN is stored as an
unvalidated literal string. A typo'd, padded, or wrongly-cased
cross-account ARN therefore:

1. passes every plan-time validation,
2. applies green — no error, no warning,
3. grants the intended principal nothing (fail-closed, so it is
   eventually noticed), and
4. leaves a **dangling principal** — whoever can later create a role
   by that name in that account inherits `sts:AssumeRole` on this
   role.

Both worked examples above are cross-account, which is exactly where
the missing backstop bites. For the deploy role, whose policy is
typically broad, a dangling principal is an account-level privilege
handoff.

**Consequences for callers:**

- Treat `trusted_role_arns` as unverified input. Copy ARNs from
  `aws iam get-role` output, never by hand.
- The **cross-account instances should carry a trust condition**
  before they hold real privilege. This shipped in DESIGN-0027: set
  `require_org_ids` (see [Trust conditions](#trust-conditions)).
  `aws:PrincipalOrgID` is the higher-value control here — it is
  valid in an `sts:AssumeRole` trust policy, needs no per-caller
  coordination, and survives a dangling principal, which
  `sts:ExternalId` alone does not. Both v1 consumers are intra-org.

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
| `tests/` | plan (the gate) | Both §4 shapes with the trust JSON asserted by content; a bare call pinning every default; trust conditions at both org-id cardinalities plus the AND-within-one-statement invariant; the three policy channels and their address stability; twenty-two fail-closed rejections, each verified to fire its own rule |
| `tests-localstack/` | Community apply | The IAM surface **and both trust conditions** round-trip live (5 runs) — see `FINDINGS.md` for what a LocalStack apply can and cannot prove about trust |

Full variable/output reference: [USAGE.md](USAGE.md).
