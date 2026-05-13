# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records documenting significant
technical decisions.

## What are ADRs?

ADRs document **technical implementation decisions** for specific architectural
components. Each ADR focuses on a single decision and includes:

- **Context**: The problem or constraint that led to this decision
- **Decision**: What was chosen and why
- **Consequences**: Trade-offs, pros, and cons
- **Alternatives**: Other options that were considered

## Creating a New ADR

```bash
docz create adr "Your ADR Title"
```

## ADR Status

- **Proposed**: Under discussion, not yet approved
- **Accepted**: Approved and being implemented or already implemented
- **Deprecated**: No longer relevant or superseded
- **Superseded by ADR-XXXX**: Replaced by another ADR

<!-- BEGIN DOCZ AUTO-GENERATED -->
## All ADRs

| ID | Title | Status | Date | Author | Link |
|----|-------|--------|------|--------|------|
| ADR-0001 | Cross-module composition via terraform_remote_state | Accepted | 2026-05-13 | Donald Gifford | [0001-cross-module-composition-via-terraformremotestate.md](0001-cross-module-composition-via-terraformremotestate.md) |
| ADR-0002 | Node IAM minimization via Pod Identity | Accepted | 2026-05-13 | Donald Gifford | [0002-node-iam-minimization-via-pod-identity.md](0002-node-iam-minimization-via-pod-identity.md) |
| ADR-0003 | Pod Identity Agent installed on the addons module | Accepted | 2026-05-13 | Donald Gifford | [0003-pod-identity-agent-installed-on-the-addons-module.md](0003-pod-identity-agent-installed-on-the-addons-module.md) |
| ADR-0004 | Addon-managed Pod Identity Association pattern | Accepted | 2026-05-13 | Donald Gifford | [0004-addon-managed-pod-identity-association-pattern.md](0004-addon-managed-pod-identity-association-pattern.md) |
| ADR-0005 | gVisor as the syscall sandboxing runtime | Accepted | 2026-05-13 | Donald Gifford | [0005-gvisor-as-the-syscall-sandboxing-runtime.md](0005-gvisor-as-the-syscall-sandboxing-runtime.md) |
| ADR-0006 | ARM64 Graviton as default for secure workloads | Accepted | 2026-05-13 | Donald Gifford | [0006-arm64-graviton-as-default-for-secure-workloads.md](0006-arm64-graviton-as-default-for-secure-workloads.md) |
| ADR-0007 | IMDS hop limit 2 with minimal node IAM | Accepted | 2026-05-13 | Donald Gifford | [0007-imds-hop-limit-2-with-minimal-node-iam.md](0007-imds-hop-limit-2-with-minimal-node-iam.md) |
| ADR-0008 | AL2023 only for secure node groups | Accepted | 2026-05-13 | Donald Gifford | [0008-al2023-only-for-secure-node-groups.md](0008-al2023-only-for-secure-node-groups.md) |
| ADR-0009 | ON_DEMAND default for secure workloads | Accepted | 2026-05-13 | Donald Gifford | [0009-ondemand-default-for-secure-workloads.md](0009-ondemand-default-for-secure-workloads.md) |
| ADR-0010 | gVisor release pinning via Renovate | Accepted | 2026-05-13 | Donald Gifford | [0010-gvisor-release-pinning-via-renovate.md](0010-gvisor-release-pinning-via-renovate.md) |
| ADR-0011 | RuntimeClass delivered out-of-band, not by Terraform | Accepted | 2026-05-13 | Donald Gifford | [0011-runtimeclass-delivered-out-of-band-not-by-terraform.md](0011-runtimeclass-delivered-out-of-band-not-by-terraform.md) |
| ADR-0012 | SSM access on the node role | Accepted | 2026-05-13 | Donald Gifford | [0012-ssm-access-on-the-node-role.md](0012-ssm-access-on-the-node-role.md) |
<!-- END DOCZ AUTO-GENERATED -->
