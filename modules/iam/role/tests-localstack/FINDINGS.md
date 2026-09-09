# LocalStack findings — iam/role

Community apply suite (`apply_localstack.tftest.hcl`) against
**token-free `localstack/localstack:4.4` (Community),
`SERVICES=iam,sts`**. Run and passing, 3/3 (2026-09-04). Pure IAM +
STS: no Pro tier, no auth token, no named volume.

## ⚠️ Read first: STS AssumeRole against LocalStack proves NOTHING about trust

LocalStack's STS **mints credentials for any role ARN**, regardless
of whether the role's trust policy allows the caller — the IMPL-0015
Phase 1 finding (it is why the fleet's cross-account remote-state
reads work on LocalStack without pre-creating a single IAM role).

So an `AssumeRole` in this suite would succeed against a trust policy
naming nobody at all. **This suite therefore never asserts
"assumability."** It asserts the IAM *surface* — what the API stored
and serves back — and the module's real trust guarantee is enforced
at plan time by `trusted_role_arns`' four validations, not here.

## What the suite does assert

| Assertion | Why it is meaningful |
|---|---|
| `role_unique_id` starts with `AROA` | IAM mints the unique id at create; the provider cannot fabricate it — the strongest single signal the role really landed |
| `role_arn` / `role_name` | The by-name contract survives a real apply |
| Both attachment channels non-empty | AWS-managed **and** caller-owned ARNs attach live (4.4 resolves `arn:aws:iam::aws:policy/ReadOnlyAccess`) |
| Inline policy applied under its map key | The name-keyed address is real, not just a plan artifact |

The `verify_readback` run then reads the role **back** through
`data.aws_iam_role` in a separate fixture — an independent check of
the far side rather than of what the provider recorded. It confirms
4.4 stores and serves back: the path, `max_session_duration`, tags,
the permissions boundary, and the **full trust document** (one
statement, exactly `sts:AssumeRole`, both principals).

## Probe: the empty-string permissions boundary — POSITIVE

`permissions_boundary = ""` was accepted by the module before the
review. The question was what it *does*, and 4.4 answers it
faithfully: the apply succeeds with no error and no warning, and
reading the role back through `fixtures/verify` returns
`permissions_boundary == ""` — IAM stored **no boundary at all**.

That matches the provider source (create uses `d.GetOk`, false for
`""`, so the argument is omitted from `CreateRole`; update takes the
`DeleteRolePermissionsBoundary` branch), and it means the emulator
reproduced a security-relevant provider behavior well enough to
prove the defect without touching real AWS.

The value is now rejected at **plan** by a variable validation, so
this state is no longer reachable and the apply suite does not
re-probe it — the regression lives at the tier where the logic does
(`tests/validation.tftest.hcl`,
`empty_string_permissions_boundary_rejected`). Recorded here because
the *emulator finding* — that 4.4 is faithful on boundary omission —
is reusable, and because the suite's existing
`output.permissions_boundary != ""` assertion was already the right
check; it had simply never been fed `""`.

## Probe: `import` blocks inside `terraform test` — POSITIVE

DESIGN-0025 OQ 4a records this as a **stretch, not a gate**: evidence
for the README adoption runbook, since the actual deploy-role imports
are live-repo work. Probed here and it works end to end.

Method — seed a role out-of-band, then apply the module over it with
an `import` block targeting `aws_iam_role.this`:

```bash
aws iam create-role --role-name adopt-me --assume-role-policy-document '…'
aws iam put-role-policy   --role-name adopt-me --policy-name legacy-inline …
aws iam attach-role-policy --role-name adopt-me --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
```

```hcl
import {
  to = aws_iam_role.this
  id = "adopt-me"
}
```

**Result:** the apply passes, and the pre-existing role is gone after
the test tears down — i.e. the out-of-band role genuinely became
module-managed.

**The control that makes this evidence rather than a coincidence:**
the identical apply *without* the import block fails —

```text
Error: creating IAM Role (adopt-me): … StatusCode: 409,
EntityAlreadyExists: Role with name adopt-me already exists.
```

A green run alone would not have distinguished "the import adopted
the role" from "the import block was ignored and the create happened
to work." The 409 control is what separates them.

Caveat on scope: this proves the *mechanism* (Terraform's import
block, the module's addresses, LocalStack's IAM). It does not prove
a zero-diff import of any real deploy role — that depends on each
account's actual role contents, which is exactly why the runbook says
**match reality first, converge second**.

## Suite shape

`fixtures/policies` creates the caller-owned policy and the boundary
policy the module attaches (the module deliberately does not create
policies — DESIGN-0025 OQ 3a attach-only), and `fixtures/verify`
holds the read-back data sources. Same env wiring as the fleet
(`AWS_ENDPOINT_URL`, and explicit `iam`/`sts` endpoints in the
provider block).
