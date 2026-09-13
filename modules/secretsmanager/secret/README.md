# secretsmanager/secret

The fleet's Secrets Manager secret producer (DESIGN-0020 / INV-0010
resolution 1b): creates a customer-managed secret whose value — a
generated password, bare or wrapped in RDS-format DB-credentials JSON —
**never exists in Terraform state, plan output, or code**. The value's
entire lifecycle is: generated in memory during the operation
(`ephemeral "random_password"`, local, no API call) → sent write-only
(`secret_string_wo`) → durable in exactly one place: the secret itself.

Two standing constraints, before anything else:

1. **Test suites for this module must use the real-provider-fake-creds
   pattern — never `mock_provider "aws"`.** Terraform's provider-mocking
   mechanism rejects ephemeral resource *types* outright (even when
   count-gated to zero), and no `override_ephemeral` block exists
   (INV-0010 F3.1/F3.2, probed on Terraform 1.15.8). A `mock_provider`
   in any `.tftest.hcl` here fails every run in that file.
2. **Outputs are pointer-only — never the value** (INV-0010 F7).
   Remote-state outputs re-persist into every consumer's state, so an
   output carrying the secret value would leak it into N+1 state files.
   The contract set is the secret ARN / id / name, the KMS key ARN
   (null ⇒ the AWS-managed `aws/secretsmanager` key), the version-gate
   integer, and the non-secret `username`. Nothing else may reference
   `ephemeral.random_password.this.result` — the plan suite's
   `secret_string_wo == null` assertion is the mechanical backstop.

Terraform **>= 1.11** is required (write-only arguments — the fleet's
first 1.11 floor; the repo CLI pin 1.15.8 satisfies it).

Rotation: bump `secret_string_version` — one apply mints one new
password. There is no rotation Lambda by design (DESIGN-0020 Non-Goal;
rotation of a customer-managed secret needs a Lambda AWS only ships via
CloudFormation/SAM). Consumers that copy the value onward (e.g. an RDS
master password set from this secret) do **not** pick a rotation up
automatically — they re-send on their own version bump (INV-0010 F4).

## Remote-state key contract

Consumers read this module's outputs from its Terraform state at the
ADR-0020 account-scoped key:

```text
<account_name>/<region>/secrets/<name>/terraform.tfstate
```

- The key itself is produced by the Terragrunt live repo's folder
  layout, as always — this repo never writes it.
- `<name>` is **triple-coupled**: this module's `var.name` == the
  live-repo folder name == the consumer's input. It couples to
  `var.name`, **not** the suffixed physical secret name (`name_prefix`
  appends a random suffix; consumers resolve the secret by `secret_arn`
  from state, never by constructing the name).
- The outputs are the pointer only: `secret_arn`, `secret_id`,
  `secret_name`, `kms_key_arn`, `secret_string_version`, `username`.
  Never the value. Consumers read the value ephemerally
  (`ephemeral "aws_secretsmanager_secret_version"`) at apply and feed
  it to a write-only argument — it must not land in their state either.
- First intended consumer: the RDS reference mode (DESIGN-0020
  Follow-up 1), which composes the key from its `master_password`
  object's stack-name member with the standard cross-account
  `assume_role` block.

## Caveats

- **Cross-account reads require the BYO CMK path.** The AWS-managed
  `aws/secretsmanager` key cannot be used across accounts at all (AWS
  restriction) — set `kms_key_arn` and grant the reading principal
  `kms:Decrypt` in that key's own policy, which this module does not
  own. `read_principals` handles only the secret's resource policy; a
  missing key-policy grant surfaces as `AccessDenied` on
  `GetSecretValue` even though the secret policy allows the read.
- **Rotation does not auto-propagate** (INV-0010 F4). Bumping
  `secret_string_version` mints one new password in the secret — but a
  consumer that copied the value onward (e.g. an RDS master password
  set from this secret) keeps the old value until it re-sends on its
  own version bump. Coordinate the two bumps.
- **Name reuse is blocked for the recovery window.** A destroyed secret
  holds its physical name for `secret_recovery_window_days` (up to 30
  days). `name_prefix` makes recreates collision-free; set the window
  to `0` only for test teardown / break-glass permanent deletion.
- **An existing secret cannot be adopted without losing its value** —
  see the section below. This module is for secrets it creates.
- **Deferred by design** (DESIGN-0020 Follow-up 4): raw `policy_json`
  passthrough, multi-region replicas, BYO-caller-value via ephemeral
  variables, and any rotation Lambda.

## Adopting an existing secret: don't

There is no import runbook here, and that is a finding rather than an
omission. **Importing a secret this module did not create plans as a
REPLACEMENT, and the replacement mints a new secret value.**

The provider infers `name_prefix` on read by stripping **exactly 26
characters** off the physical name. A secret created out of band as
`app-db-master` has no such suffix, so `name_prefix` comes back unset
and this module's `name_prefix = "app-db-master-"` lands on a
**ForceNew** argument:

```text
~ name        = "app-db-master" -> (known after apply)
+ name_prefix = "app-db-master-" # forces replacement
Plan: 1 to import, 1 to add, 0 to change, 1 to destroy.
```

Probed against LocalStack 4.4 during IMPL-0023, where
`network/security-group` hit the same wall. Three things make it worse
here than for a security group:

1. **The value changes.** `secret_string_wo` is fed by
   `ephemeral.random_password`, which is regenerated on every create.
   The replacement does not carry the old secret across — it mints a
   new password, and every consumer holding the old one breaks.
2. **There is no `create_before_destroy`** on `aws_secretsmanager_secret`
   in this module, so it is destroy-then-create.
3. **The old name is then held** for `secret_recovery_window_days`.

**No test pins this**, and cannot: `terraform test` has no plan-diff
introspection, so you can assert resource attributes but not that a plan
is a replacement. If the provider ever starts inferring `name_prefix`
for arbitrary names, this section silently becomes wrong and nothing
goes red — re-probe before trusting it across a major provider bump.

If you must bring an out-of-band secret under Terraform, treat it as a
**migration, not an import**: create a new secret with this module,
point consumers at the new ARN, and retire the old one once nothing
reads it. That is a credential rotation, so sequence it like one.
