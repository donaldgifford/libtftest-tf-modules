---
id: ADR-0007
title: "IMDS hop limit 2 with minimal node IAM"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0007. IMDS hop limit 2 with minimal node IAM

<!--toc:start-->
- [Status](#status)
- [Context](#context)
- [Decision](#decision)
- [Consequences](#consequences)
  - [Positive](#positive)
  - [Negative](#negative)
  - [Neutral](#neutral)
- [Alternatives Considered](#alternatives-considered)
- [References](#references)
<!--toc:end-->

## Status

Accepted

## Context

The launch template for the secure managed-node-group module (DESIGN-0001)
sets EC2 instance metadata options to:

```hcl
metadata_options {
  http_endpoint               = "enabled"
  http_tokens                 = "required"   # IMDSv2 only
  http_put_response_hop_limit = 2
  instance_metadata_tags      = "enabled"
}
```

`http_tokens = "required"` is uncontroversial — IMDSv1 is disabled
everywhere in the fleet. This ADR's job is to nail down the **hop
limit** as a non-negotiable consequence of the Pod Identity credential
model adopted in ADR-0002.

Hop limit is not a knob we get to tune. The Pod Identity model
*requires* hop=2:

- The **Pod Identity Agent** runs as a host-network DaemonSet and vends
  credentials at the link-local address `169.254.170.23`.
- Pod-network pods (which is to say: every workload pod in the secure
  node group, since `hostNetwork: true` is mutually exclusive with
  gVisor under ADR-0005) reach the agent by crossing one network hop
  out of their pod netns into the node netns, *then* up to the agent.
  That second hop is what `hop_limit = 2` permits.
- With `hop_limit = 1`, regular pod-network pods cannot reach the Pod
  Identity Agent's endpoint at all. Pod Identity stops working for
  every workload that needs AWS credentials, which under ADR-0002 is
  every workload that needs AWS credentials *full stop*. That is not a
  tradeoff to weigh; it is a system that no longer functions.

Some hardening guides (CIS EKS Benchmark, several public posture
checklists) recommend `hop_limit = 1` as a default. Those guides are
written from an IRSA-era posture, where workload credentials come from
the OIDC provider (`sts.amazonaws.com`), not from a node-local agent on
the link-local network. In that posture hop=1 has zero cost. In a Pod
Identity posture it breaks workload AWS access. This ADR exists so
that future readers don't apply the CIS guidance without seeing the
incompatibility.

There is a secondary question that *does* admit posture nuance: given
that hop=2 is required, does residual IMDS access from pod-network pods
matter? The load-bearing framing is: **the durable defense for IMDS
exposure is the empty node role from ADR-0002, not the hop limit.**
Tightening the hop limit was never the control that mattered.

Three facts hold together:

1. **`hostNetwork: true` pods always have IMDS access**, regardless of
   `hop_limit`. They're in the host network namespace; IMDS is reachable
   without crossing a hop. AWS docs are explicit:

   > Pods configured with hostNetwork: true will always have IMDS access,
   > but the AWS SDKs and CLI will use Pod Identity credentials when
   > enabled.

   `hop_limit = 1` doesn't close this. The IMDS-from-hostNetwork
   pathway is a property of the network namespace, not the hop count.
2. **The AWS SDK credential chain prefers Pod Identity over IMDS.** When
   `AWS_CONTAINER_CREDENTIALS_FULL_URI` is set (Pod Identity webhook
   injects it for associated workloads), the SDK uses the agent. IMDS is
   later in the chain. A hostNetwork pod on a modern SDK with a Pod
   Identity Association uses the scoped role, not the node role — even
   though IMDS is reachable.
3. **An older SDK, a misbehaving SDK, or a non-SDK process can still hit
   IMDS directly.** `curl http://169.254.169.254/...` from a hostNetwork
   pod works regardless. This is the residual concern.

Under ADR-0002, the node role carries only `AmazonEKSWorkerNodePolicy` +
`AmazonEC2ContainerRegistryPullOnly`. Those policies grant a node things
nodes need to join a cluster and pull images — kubelet cluster
registration, `eks-auth:AssumeRoleForPodIdentity`, ECR pull-only — none
of which are credentials a workload would want to steal. There is no
controller IAM on the node role, no CNI policy, no CSI policy, no
inline custom policies. "IMDS exposure" from a hostNetwork pod under
that posture is a near-empty threat: the credentials are real but
they're scoped to operations the node itself already performs.

So the posture is: hop=2 is required by Pod Identity, full stop. The
incidental fact that hop=2 also leaves pod-network pods able to reach
IMDS directly is the *only* posture concession at this layer — and
that concession is neutralized by the minimal node role, not by the
hop limit.

An earlier brief flagged "move to hop-limit=1 as a defense-in-depth
measure after the node role is minimized" as a possible future step.
That framing predates the firmed-up Pod Identity model in this fleet. As long as workload AWS
credentials come from a node-local agent at the link-local address,
hop=1 is not on the table — it would terminate workload AWS access,
not harden it. A move to hop=1 would require *either* abandoning Pod
Identity in favor of something not on the link-local network, *or* a
node-side network construct (iptables/eBPF) that distinguishes
`169.254.170.23` from `169.254.169.254`. Neither is on any near-term
roadmap, and neither would be a hop-limit decision — they'd be
credential-model or CNI decisions.

## Decision

The secure managed-node-group module sets:

- `http_endpoint = "enabled"`
- `http_tokens = "required"` — IMDSv2 only.
- `http_put_response_hop_limit = 2` — pod-network pods can reach the
  Pod Identity Agent.
- `instance_metadata_tags = "enabled"` — instance tags exposed via
  IMDS for legitimate node-side tooling that reads them.

`hop_limit = 2` is a **hard requirement** of the Pod Identity
credential model, not a posture preference. Pod-network pods reach the
Pod Identity Agent at `169.254.170.23` by crossing two hops out of
their pod netns; without hop=2 they cannot reach the agent and Pod
Identity is non-functional. Under ADR-0002 every workload AWS
credential flows through Pod Identity, so "Pod Identity non-functional"
means "workloads can't talk to AWS." This is not a setting to revisit
in isolation.

`hop_limit = 1` is *not* a valid value for this module as long as Pod
Identity is the credential model. A move to hop=1 would require
abandoning Pod Identity for an off-link-local credential mechanism, or
adopting a node-side iptables/eBPF redirect that distinguishes
`169.254.170.23` from `169.254.169.254`. Either is a credential-model
or CNI decision deserving its own ADR — not a hop-limit decision.

The residual concern — pod-network pods can reach IMDS directly under
hop=2 — is handled by the minimal node role from ADR-0002, which is
the durable defense and the one that actually scales to "every EC2
instance in the fleet."

The decision applies uniformly across both `arm64` and `amd64`
instantiations of the module — hop limit is architecture-agnostic.

## Consequences

### Positive

- **Pod Identity works for pod-network pods, as designed.** Every
  workload-class pod can reach the Pod Identity Agent at
  `169.254.170.23` and resolve `AWS_CONTAINER_CREDENTIALS_FULL_URI`.
  This is the load-bearing requirement; everything else follows from it.
- **Posture is coherent with ADR-0002.** The defense lives at the node
  role, where it can't be bypassed by `hostNetwork: true` and where
  it's enforceable in a single place via Terraform. Tightening hop
  limit would have layered a network-side control on top of a
  fundamentally identity-side problem.
- **Matches the EKS managed node group default.** Operators reading the
  AWS console or running `aws ec2 describe-instances` see the value
  they expect. No "why is this one cluster different from the rest of
  the fleet" question.
- **Reversible at the launch-template level.** `metadata_options` is a
  launch-template field — changing it is a Terraform apply, propagated
  to nodes as they roll. Not load-bearing on cluster identity or
  workload IAM.

### Negative

- **The hop=2 posture is not what CIS / public hardening guides
  recommend in isolation.** Some compliance scans will flag
  `http_put_response_hop_limit = 2` as a finding. The mitigation is
  the documented posture in ADR-0002 — pointing the scan author at the
  empty node role rather than chasing the finding to hop=1. This will
  generate audit-conversation overhead.
- **`hostNetwork: true` pods retain IMDS access.** Per the AWS docs
  quote above, hop=1 wouldn't close this either; but a reader looking
  at the launch template in isolation might assume hop=2 *causes* it.
  The cause is the network namespace, not the hop limit.
- **Pod-network pods can reach IMDS directly via the link-local
  address.** This is the actual posture concession. Under the minimal
  node role, what they get is "ECR pull-only + node-join + Pod Identity
  AssumeRole entrypoint" — not nothing, but not credentials that move
  an attacker anywhere they couldn't already go from a successful
  container escape on a node. Tracked as a residual; not solved here.

### Neutral

- **A future hop=1 move is not a launch-template change.** If the
  fleet ever moves to a credential model that doesn't go through the
  link-local address (or if a node-side CNI/eBPF redirect makes the
  two link-local destinations independently routable), hop=1 becomes
  available. That conversation belongs in a credential-model or CNI
  ADR, not here. From this module's perspective, hop=2 is fixed by
  the credential model in ADR-0002.
- **`instance_metadata_tags = "enabled"` is left on.** Legitimate
  node-side tooling (kubelet, monitoring agents) consumes instance
  tags. Disabling it would force tag lookups via the EC2 API, which
  costs an IAM permission and a round trip. The tags themselves are
  not sensitive; they're the same tags visible in the EC2 console.

## Alternatives Considered

**`http_put_response_hop_limit = 1`.** The CIS-recommended posture in
isolation. **Incompatible with this fleet's credential model**, not
merely worse on a tradeoff. Pod-network pods cannot reach the Pod
Identity Agent at `169.254.170.23` under hop=1; Pod Identity is the
*only* path workloads have to AWS credentials under ADR-0002. The
result of setting hop=1 here is not "hardened module" — it's "no
workload can call AWS APIs." Recorded as rejected so a future reader
looking at the CIS guidance doesn't apply it without seeing what it
would break.

**Disable IMDS entirely (`http_endpoint = "disabled"`).** Some
high-assurance fleets do this. Rejected because:

- Kubelet on AL2023 reads instance metadata for region detection and
  several bootstrap inputs.
- Several legitimate node-side tools (CloudWatch agent, SSM agent,
  Wiz/Falco/etc. node DaemonSets) read instance tags or metadata.
- The IMDSv2-required posture (`http_tokens = "required"`) already
  eliminates the SSRF-style theft pattern that motivates "disable IMDS"
  as a recommendation; that recommendation is from the IMDSv1 era.

**`hop_limit = 1` + a node-local iptables / eBPF rule that redirects
`169.254.170.23` to the agent for pod-network pods.** This is the
"have your cake and eat it too" option: pod-network pods reach the
agent, but `169.254.169.254` (IMDS) is unreachable. Rejected for now
because:

- It introduces a node-side network shim the team would own and
  maintain. AWS does not ship this pattern as a managed feature today.
- Failure modes for the shim (CNI plugin interactions, conntrack
  edge cases, ordering during node boot) are nontrivial to operate.
- The credential blast radius it would close is, again, near-empty
  under the minimal node role.

  Worth revisiting only if a future managed AWS or CNI feature makes
  this configuration declarative rather than hand-rolled.

**`http_tokens = "optional"` (allow IMDSv1).** Not seriously
considered. IMDSv1 is the historically-exploited surface
(`SSRF → STS → game over`); enforcing v2 is the table-stakes control
that makes any hop-limit conversation worth having. Mentioned only to
record that this is *not* a tradeoff.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state`
  (launch-template inputs are hoisted via Boilerplate-generated
  Terragrunt; module ships the posture defaults).
- ADR-0002 — Node IAM minimization via Pod Identity (the empty node
  role is the durable defense this ADR relies on).
- ADR-0005 — gVisor as the syscall sandboxing runtime
  (defense-in-depth at a different layer; composes with this one).
- ADR-0006 — ARM64 Graviton as default (hop limit is
  architecture-agnostic).
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (where
  `metadata_options` lives).
- AWS docs — EKS Pod Identity & IMDS access:
  <https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html>
- AWS docs — Configuring the instance metadata service:
  <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- AWS docs — IMDSv2 hop limit:
  <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-options.html>
