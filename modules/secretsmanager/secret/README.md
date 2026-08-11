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

<!-- Remote-state key contract section lands in Phase 2 (IMPL-0019
     task 2.2). -->
