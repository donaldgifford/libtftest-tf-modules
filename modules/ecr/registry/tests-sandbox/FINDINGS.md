<!-- markdownlint-disable-file MD025 MD041 -->
# Sandbox findings: ecr/registry

## Status: runbook authored, live run PENDING

`run.sh` is written, passes `shellcheck`, and the two stacks it
generates pass `terraform validate`. It has **not been run live**:
this environment has no AWS credentials for a sandbox account pair. It
is an operator step, and per IMPL-0027 OQ 4a the release does not wait
for it.

When run, paste `results.txt` below, add the manual P3 result, and
write any result that contradicts DESIGN-0030 back into the design as
a build note.

## Results

| Leg | Result | Date / versions |
| --- | --- | --- |
| P1 ordering (one apply from V1) | pending | |
| P1 pull on V2, no repository policy | pending | |
| P2 quarantine refused | pending | |
| P2 over-broad pass-through, quarantine still refused | pending | |
| Narrowing (matching allowed, non-matching refused) | pending | |
| P1 V1 probe: `PutRegistryPolicy` accepted or rejected? | pending | |
| P1 V1 probe: consumer pull | pending | |
| Destroy: consumer refused | pending | |
| Destroy: scope and scanning left behind | pending | |
| P3: a node not built by this repo pulls by digest | pending (manual) | |
