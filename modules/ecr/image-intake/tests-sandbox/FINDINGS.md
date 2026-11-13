<!-- markdownlint-disable-file MD025 MD041 -->
# Sandbox findings: ecr/image-intake

## Status: runbook authored, live run PENDING

`run.sh` is written, passes `shellcheck`, and the two stacks it
generates pass `terraform validate`. It has **not been run live**:
this environment has no AWS credentials for a sandbox account pair. It
is an operator step, and per IMPL-0027 OQ 4a the release does not wait
for it.

When run, paste `results.txt` below. Two results feed straight back
into DESIGN-0031 and the module README:

- **cosign, strict** decides OQ 6's long-term default (keep `sha256-*`,
  or move to fully `IMMUTABLE` with OCI 1.1 referrers);
- **Encryption** decides the README's `kms_key_arn` guidance (whether a
  cross-account pull works under a CMK's default key policy).

## Already known (local, not ECR)

cosign 3.1.1 against `crane registry serve`, which has no referrers
API: `sign` plus two `attest`s all landed under one fallback tag,
`sha256-<digest>`, rewritten each time (IMPL-0027 Phase 6 build note).
ECR's own behaviour is what the strict leg asks.

## Results

| Leg | Result | Date / versions |
| --- | --- | --- |
| Writer: quarantine push (create-on-push) | pending | |
| Writer: mirror push denied | pending | |
| Services: scan-on-push completes in quarantine | pending | |
| Lifecycle: policy attached | pending | |
| Events: quarantine push delivers an event | pending | |
| Events: mirror push delivers none | pending | |
| Intake: quarantine pull, mirror push | pending | |
| Isolation: unrelated `ecr:*` role refused on quarantine and on mirror push | pending | |
| Isolation: consumer refused on quarantine, allowed on mirror | pending | |
| cosign: sign + attest on mirror; tags written | pending | |
| cosign, strict: default mode | pending | |
| cosign, strict: `oci-1-1` mode | pending | |
| Re-push of identical tag + digest to an immutable repository | pending | |
| Examples end to end | pending | |
| Encryption: consumer pull under a CMK's default policy | pending | |
