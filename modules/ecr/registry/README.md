<!-- markdownlint-disable-file MD025 MD041 -->
# ECR Registry (registry-level owner, cross-account pull allow-list)

The **single owner** of an ECR registry's registry-level configuration
([DESIGN-0030](../../../docs/design/0030-ecr-registry-module-with-a-cross-account-pull-allow-list.md)):

- the registry policy, granting an **allow-list of accounts** pull access
  to listed repository prefixes;
- the account's `REGISTRY_POLICY_SCOPE` setting (pinned to `V2`);
- the registry scanning configuration (only when asked).

It creates no repositories. Repositories come from push-time creation
templates (`ecr/image-intake`) or from whatever already creates them.

## One owner per registry

The registry policy, the policy scope and the scanning configuration
are **per-registry singletons**: each API call replaces the whole
object. Two stacks that both manage one of them overwrite each other on
every apply, silently. So exactly one `ecr/registry` stack exists per
registry (account and region), and no other module touches these
objects. Purpose modules such as `ecr/image-intake` work at the
repository level only.

## Usage

```hcl
module "registry" {
  source = "git::https://github.com/donaldgifford/libtftest-tf-modules.git//modules/ecr/registry?ref=<tag>"

  # Placeholder account IDs. A typo here grants to a stranger's account,
  # so review this map like a trust policy.
  consumer_accounts = {
    "111111111111" = {}
    "222222222222" = {
      # Optional: only node roles in this account may pull.
      principal_arn_patterns = ["arn:aws:iam::222222222222:role/*-node-*"]
    }
  }

  # Feed this from ecr/image-intake's promoted_prefixes output.
  pull_repository_prefixes = ["mirror"]

  # Default ["quarantine"]: every listed account is explicitly denied it.
  # protected_prefixes = ["quarantine"]
}
```

### What each account is granted

Each account is a principal of the form `arn:aws:iam::<id>:root`. That
means **the account's own IAM decides** which of its principals may
pull; it does not mean the root user. A consumer principal needs both
halves:

1. this registry policy (resource side, here); and
2. an identity policy in its own account. The
   `consumer_identity_policy_json` output is that document:
   `ecr:GetAuthorizationToken` on `*` plus pull on the shared prefixes.

The consumer side does not need to use this repo's modules. For an EKS
node role built any other way, attach the JSON as an inline policy.
With this repo's modules:

- `eks/pod-identity-access`: pass the JSON in `inline_policies`;
- `eks/managed-node-group`: it takes policy **ARNs**, so create an
  `aws_iam_policy` from the JSON in the consumer stack and pass its ARN
  in `extra_node_policies`.

`principal_arn_patterns` narrows an account with an `ArnLike` condition
on `aws:PrincipalArn`. Patterns must name the same account, and the
whole-account pattern `arn:aws:iam::<id>:*` is rejected, because it is
the same as no narrowing.

### Protected prefixes are denied, not just ungranted

The policy carries an explicit `ConsumerDenyProtected` statement:
every listed account is denied **all** ECR actions on
`protected_prefixes`. A later `additional_policy_statements` entry that
grants an account `repository/*` still cannot reach quarantine, because
an explicit Deny always wins. The prefix inputs are also checked at
plan: a pull prefix may not equal, contain or sit inside a protected
one.

### Policy rendering

The policy is `jsonencode`d from sorted inputs. It does not use
`aws_iam_policy_document`, which collapses single-element sets into
strings and makes the rendered shape depend on how many accounts are
listed. Input order never changes the document. The reserved sid
prefix is `Consumer`; `additional_policy_statements` may not use it.

## Registry policy scope (V1 vs V2)

Pull grants in a registry policy need `REGISTRY_POLICY_SCOPE = V2`. A
V1 registry covers only replication and pull-through-cache actions, and
is expected to **reject** the pull grant at `PutRegistryPolicy`. So the
module pins the setting to `V2` and makes the policy `depends_on` it,
so the setting always lands first.

Set `manage_registry_policy_scope = false` only when another stack
already owns the setting and the registry is already on `V2`.

## Scanning

`scanning = null` (the default) manages **nothing**: it leaves the
registry's existing scanning setup alone and does not disable it. A
non-null value takes ownership and replaces the whole configuration.
`ENHANCED` turns on Amazon Inspector billing for the account.

```hcl
scanning = {
  scan_type = "BASIC"
  rules     = [{ scan_frequency = "SCAN_ON_PUSH", filters = ["quarantine/*", "mirror/*"] }]
}
```

## Destroy

Destroying the stack deletes the registry policy, so **every consumer
account loses pull access at once**. Repositories and images are
untouched. What happens to the two other singletons (the scope setting
and the scanning configuration) is recorded by the sandbox runbook's
destroy leg. Until that has run, check them by hand afterwards with
`aws ecr get-account-setting --name REGISTRY_POLICY_SCOPE` and
`aws ecr get-registry-scanning-configuration`.

## Adopting an existing registry

A registry that already has a policy, scope setting or scanning
configuration is adopted with `import` blocks in the stack:

```hcl
import {
  to = module.registry.aws_ecr_registry_policy.this[0]
  id = "111111111111" # the registry (account) ID
}

import {
  to = module.registry.aws_ecr_account_setting.registry_policy_scope[0]
  id = "REGISTRY_POLICY_SCOPE"
}

import {
  to = module.registry.aws_ecr_registry_scanning_configuration.this[0]
  id = "111111111111"
}
```

Import only what the inputs will manage (the policy only renders when
`consumer_accounts` and `pull_repository_prefixes` are set; scanning
only when `scanning` is non-null). Then **read the plan**: the module
replaces the whole policy with its own rendering, so any statement not
expressed in the inputs disappears on apply. Carry such statements over
in `additional_policy_statements` first.

## Remote-state key contract

Published at a **flat reserved key**, with no `<name>` segment:

```text
<account_name>/<region>/ecr/registry/terraform.tfstate
```

There is exactly one instance per account and region, because every
object the module owns is a per-registry singleton (ADR-0020, the
`ecr/registry` reserved stack name). The key is reserved ahead of any
consumer; nothing in this repo reads it yet. The module itself reads no
remote state.

## Related modules

- [`ecr/image-intake`](../image-intake/README.md): the creation
  templates whose `promoted_prefixes` output feeds
  `pull_repository_prefixes`, and whose quarantine prefix this module's
  `protected_prefixes` default keeps shut.
- [`kms/signing-key`](../../kms/signing-key/README.md): the key that
  signs promoted images, so consumers can verify what they pull.

## LocalStack

This module has **no LocalStack apply tier**, Community or Pro
(IMPL-0027 Phase 1, OQ 2a):

- token-free Community 4.4 serves no ECR API at all;
- LocalStack Pro 2026.10.7 was probed and cannot apply the module.

| API / behaviour (Pro 2026.10.7) | Result |
| --- | --- |
| `PutRegistryPolicy` with V1-scope actions | Accepted and round-trips |
| `PutRegistryPolicy` with pull actions, or a `Deny ecr:*` | **Rejected** (`InvalidParameterException`). Pro models the V1 scope only |
| `PutAccountSetting` / `GetAccountSetting` | **Not implemented** |
| Registry scanning configuration | Served, round-trips |
| A deny-all repository policy | **Not enforced** |

The module's pull grant and `ConsumerDenyProtected` are both rejected,
and the account setting does not exist, so only the off-by-default
scanning resource would apply. The plan suite is the gate, and
enforcement is proven against real AWS by the `tests-sandbox/` runbook.

## Tagging

None of the three resources is taggable, so provider `default_tags`
have nothing to reach and the module has no tag inputs (DESIGN-0029).

## Tests

| Suite | Tier | What it proves |
| --- | --- | --- |
| `tests/` | plan (the gate), 45 runs | The policy decoded statement by statement (plain and narrowed grants, `ConsumerDenyProtected`, additional statements), input-order stability, the scope setting and its ordering, both scanning types, the consumer-contract outputs, and 26 rejections, each verified by isolated message probe to fire its own rule |
| `tests-sandbox/` | real AWS, operator-run | Cross-account enforcement: P1 (including the V1 ordering and the V1 probe), P2 with and without an over-broad pass-through, narrowing, destroy, and a manual P3 on a node this repo did not build. Live run pending: see `tests-sandbox/FINDINGS.md` |

Full variable and output reference: [USAGE.md](USAGE.md).
