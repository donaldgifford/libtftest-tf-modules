# LocalStack findings — network/security-group

Community apply suite (`apply_localstack.tftest.hcl`) against
**token-free `localstack/localstack:4.4` (Community),
`SERVICES=ec2,sts,s3`**. Run and passing, **4/4** (2026-09-11).

Pure EC2 + STS, with S3 only for the fixture's seeded remote state: **no
Pro tier, no auth token, no named volume** — the `network/vpc-lookup`
precedent. Per fleet policy the Community tier stays tokenless; never
wire `LOCALSTACK_AUTH_TOKEN` into this suite.

## Managed prefix lists on token-free Community — POSITIVE (new)

**This is the finding worth carrying out of this module.** IMPL-0023
task 3.3 asked whether token-free 4.4 serves managed prefix lists at
all, because the fleet had only ever proved prefix-list `entries` under
the **Pro** container (the `eks/cluster` fence fixture, IMPL-0020 Phase
5). It does — fully:

```console
$ aws ec2 create-managed-prefix-list --prefix-list-name probe-corp \
    --address-family IPv4 --max-entries 5 \
    --entries 'Cidr=203.0.113.0/24,Description=A' 'Cidr=198.51.100.0/24,Description=B'
pl-b39b2788d57a3742c

$ aws ec2 get-managed-prefix-list-entries --prefix-list-id pl-b39b2788d57a3742c
{"Entries": [
  {"Cidr": "203.0.113.0/24", "Description": "A"},
  {"Cidr": "198.51.100.0/24", "Description": "B"}]}
```

`describe-managed-prefix-lists` reports `State: create-complete` and the
correct `MaxEntries`. So the prefix-list surface itself does **not**
require Pro — what required Pro in the fence fixture was EKS, which is
Pro-only on 4.4, not the prefix lists beside it.

### And the SG-rule half round-trips

```console
$ aws ec2 describe-security-group-rules --filters Name=group-id,Values=sg-…
{"Id": "sgr-ad2e…", "Egress": false, "Proto": "tcp", "From": 443,
 "PL": "pl-b39b2788d57a3742c", "Desc": "corp"}
```

The rule is served back **carrying the prefix list id** — i.e. a live
reference, not an expansion. `run "verify_readback"` asserts exactly
this through `data.aws_vpc_security_group_rule`, and the assertion is
**mutation-verified**: pointing it at a wrong `pl-…` turns the run red.

That assertion exists because the weaker one was already there and was
not enough. Asserting only that the rule came back with an `sgr-…` id
would pass even if the prefix list id had been dropped on the way in —
the "green at the tier where the logic lives, degenerate at the tier
that matters" gap the IMPL-0020 live-coverage sweep found three of.

## What the suite asserts

| Assertion | Why it is meaningful |
|---|---|
| The SG's `vpc_id` equals the fixture's | The account-scoped remote-state read resolved through a real S3 object and the `assume_role` — the end-to-end proof the plan suite's `override_data` stub cannot give |
| `name_prefix` yields a longer physical name | The provider-generated suffix is real, so the CBD replacement posture is on a real foundation |
| Every rule returns an `sgr-…` id | EC2 mints these; the provider cannot fabricate them |
| The prefix-list rule reads back its `pl-…` | The live reference survived (above) |
| The per-rule description reads back | It is the audit surface the description guard exists for |
| `all_egress_rule_id == null` under `allow_all_egress = false` | The restricted posture really emits no rule, rather than emitting one nobody asserted |

All four source types reach EC2 in one apply: prefix list, IPv4 CIDR,
IPv6 CIDR, and a referenced SG (the fixture creates a peer SG so that
last one points at something real rather than being the one path the
apply never exercises).

## Confirmed: the provider revokes AWS's default egress

Raw `aws ec2 create-security-group` against 4.4 leaves a default
`Egress: true, Proto: -1` rule in place:

```console
$ aws ec2 describe-security-group-rules --filters Name=group-id,Values=sg-…
{"Id": "sgr-9c2a…", "Egress": true, "Proto": "-1", "From": -1, "PL": null}
```

…and the Terraform-managed SG does **not** have it unless the module
emits one. That is the behavior `allow_all_egress = true` exists for
(DESIGN-0026 OQ 3a), reproduced on the emulator rather than taken on
faith from the provider docs.

## NEGATIVE: LocalStack does not enforce AWS string-charset constraints

The EC2 API restricts a security group description to ASCII
`a-z A-Z 0-9`, spaces and `._-:/()#,@[]+=&;{}!$*`; rule descriptions are
narrower still (no `&`). **4.4 accepts anything.** This suite applied a
description containing a U+2014 em dash (`e2 80 94`) and LocalStack
created the group, returned it, and read it back byte-identical. Real
AWS returns `InvalidParameterValue` after the create call.

This is not a curiosity — the module's own **default** description
carried that em dash, so every invocation that did not override it would
have failed against real AWS, and this suite **pinned the broken value
as expected**. A green apply tier was actively misleading here.

The general shape, worth carrying past this module: **an emulator proves
shape and wiring, never the provider's server-side string contracts.**
Charset, length and format constraints have to be validated at plan or
they are not validated at all. The module now does so for both
`var.description` and every rule description, and the fail cases live in
`tests/validation.tftest.hcl` where an emulator's tolerance cannot hide
them.

## What this suite does NOT prove

- **That any rule is enforced.** LocalStack does not carry traffic;
  this is a configuration-surface suite. Whether `203.0.113.0/24`
  actually reaches port 443 is not a question an emulator answers.
- **The world-open guard.** It is a plan-time validation, so it is
  tested where it lives (`tests/validation.tftest.hcl`, 22 rejections
  each verified against its own rule by isolated message probe). Nothing
  about it is reachable from an apply — including the IPv6
  spelling-evasion regressions, which are the ones that matter.
- **Any description charset constraint** — see the NEGATIVE above.
- **A zero-diff import.** The README's adoption runbook is exercised
  nowhere here; the actual imports are live-repo work against real
  SGs, which is why the runbook says match reality first.
