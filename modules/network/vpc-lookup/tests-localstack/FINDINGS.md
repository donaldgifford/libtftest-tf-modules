<!-- markdownlint-disable-file MD025 MD041 -->
# tests-localstack findings — modules/network/vpc-lookup

## Summary

`vpc-lookup` is data-source-only over the **core EC2/VPC API**, so it
applies cleanly against **LocalStack Community** — no Pro tier, no auth
token, no named-volume workaround (contrast the RDS family, which needs
LocalStack Pro + a named volume for the embedded Postgres). The full
`apply_localstack.tftest.hcl` suite runs `command = apply` for real.

## Environment (verified 2026-07-15)

| Component | Value |
|-----------|-------|
| Image | `localstack/localstack:4.4` (Community) |
| Services | `SERVICES=ec2,sts` |
| Startup | token-free; healthy in ~20s |
| Result | `just tf test-localstack network/vpc-lookup` → **3 passed, 0 failed** |

Newer Community images (2026.6.x) gate startup behind an auth token
(container exits 55). The `4.4` image predates that gate and starts
token-free. The surface is not version-sensitive — any Community image
that serves EC2 works.

## What the apply exercised

`run "setup"` stands up a VPC (`10.0.0.0/16`) with 3 private subnets
(`Tier=private`) across 3 AZs, 2 public subnets (`Tier=public`), an
internet gateway, and one NAT gateway (+ EIP). The module then discovered
it two ways:

- `run "discover_by_tag"` — `tag:Name = var.name` (default path)
- `run "discover_by_id"` — explicit `var.vpc_id`

Both resolved `vpc_id`, all 3 private subnet IDs (3 distinct AZs), 2
public subnets, 1 NAT gateway, the IGW, and the route tables. Every
LocalStack EC2 data source used — `aws_vpc`, `aws_subnets`, `aws_subnet`,
`aws_nat_gateways`, `aws_route_tables`, and `aws_internet_gateway` with
the `attachment.vpc-id` filter — returned correct values. **No gaps.**

## To reproduce

```bash
docker run -d --name ls-vpc-lookup -p 4566:4566 \
  -e SERVICES=ec2,sts localstack/localstack:4.4
# wait for /_localstack/health to report ec2 running, then:
just tf test-localstack network/vpc-lookup
docker rm -f ls-vpc-lookup
```
