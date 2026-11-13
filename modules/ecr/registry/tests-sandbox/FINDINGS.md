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
a build note. Three results change the module README:

- **V1 probe** decides the README's "Registry policy scope" section,
  which today says a V1 registry is *expected* to reject the pull
  grant at `PutRegistryPolicy`. If real ECR accepts it and refuses the
  pull instead, rewrite that sentence: the failure would surface at
  pull time, not at apply.
- **Destroy: scope and scanning left behind** replaces the README's
  "Destroy" placeholder ("recorded by the sandbox runbook's destroy
  leg") with what destroy actually leaves.
- **P3**: if a node built outside this repo needs anything beyond the
  `consumer_identity_policy_json` grant, the README's "What each
  account is granted" section must say what.

Any `FAIL` on P1, P2, narrowing or the destroy pull is a module
defect, not a documentation change. Open an issue before the next
release.

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
