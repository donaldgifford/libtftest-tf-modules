---
id: ADR-0012
title: "SSM access on the node role"
status: Accepted
author: Donald Gifford
created: 2026-05-13
---
<!-- markdownlint-disable-file MD025 MD041 -->

# 0012. SSM access on the node role

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

ADR-0002 commits the node role to two managed policies:
`AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly`.
This ADR settles the third-candidate question:
`AmazonSSMManagedInstanceCore` — keep it on the node role for
break-glass Session Manager access, or remove it entirely and reach
for a different mechanism when a node needs hands-on inspection?

The two relevant facts:

1. **Session Manager is operationally useful and replaces SSH cleanly.**
   With `AmazonSSMManagedInstanceCore` attached, `aws ssm
   start-session --target i-xxxxxxxx` lets an operator open a shell on
   a node without SSH keys, without inbound port 22, and with full
   CloudTrail logging of the session. For "the node is wedged, kubectl
   exec into the misbehaving DaemonSet isn't working, I need to look
   at containerd / cgroup state," this is the standard tool.
2. **It does broaden the node role beyond the "empty" posture.** SSM
   adds a credential set on the node that an attacker who reaches IMDS
   (per ADR-0007: pod-network pods *can* reach IMDS under hop=2) could
   use. The blast radius from `AmazonSSMManagedInstanceCore` alone is
   bounded — it grants the *node* the ability to be managed by SSM,
   not the ability to read parameters, run commands on other nodes, or
   move laterally to AWS APIs — but it is non-empty.

The load-bearing framing: SSM is a judgment call — operationally
useful, slightly broadens blast radius, generally acceptable. The right
move is to document it explicitly either way and make the opt-in
visible at the consuming Terragrunt stack.

The "dedicated path" alternatives to a node-role attachment are real:

- **Session Manager via an instance profile assumed on demand.**
  Attach a *separate* role with `AmazonSSMManagedInstanceCore`,
  associate it with the instance only when break-glass is needed,
  detach when done. Operationally clunky on EKS managed node groups —
  the instance profile is launch-template-bound, and rotating it
  requires a node replacement.
- **EKS Cluster Access Entries + kubectl debug.** Reach the node via
  `kubectl debug node/<name>` which runs a privileged pod with host
  filesystem mounts. Works for most diagnostic needs without any
  node-side IAM. Has limits (the node has to be reachable enough for
  kubelet to schedule the debug pod; can't recover a node where the
  kubelet itself is wedged).
- **No node access mechanism at all.** Treat nodes as cattle: if a
  node is broken, terminate it and let the ASG replace it. The
  Kubernetes-native answer. Works for transient issues, doesn't work
  for "we need to capture a memory image before this node dies" or
  for forensic investigation of a node that's been compromised.

In practice the team is one person operating a fleet that includes
clusters where `kubectl debug` won't help — clusters where the
kubelet itself is the issue, or clusters where a forensic capture
matters before the node is replaced. Removing the SSM escape hatch
entirely is the wrong tradeoff for an operationally-thin team.

The right answer is what ADR-0002 already records in the optional-
attachments table: `AmazonSSMManagedInstanceCore` is **off by
default**, opt-in via `var.enable_ssm`, and the cost of opting in is
visible at the Terragrunt layer. This ADR confirms that posture and
makes the rationale explicit.

## Decision

`AmazonSSMManagedInstanceCore` is **not** attached to the node role by
default. The secure managed-node-group module exposes
`var.enable_ssm` (default `false`); setting it to `true` attaches the
managed policy to the node role.

The attachment is per-instantiation of the module — a cluster running
both `arm64` and `amd64` secure node groups can have SSM on either,
both, or neither, decided per-Terragrunt-stack.

**When to opt in:**

- Production clusters where forensic capture matters before node
  replacement.
- Clusters running workloads sensitive enough that "terminate and
  replace" is the wrong default response to node misbehavior.
- Clusters in environments where the team's incident-response runbook
  explicitly relies on Session Manager.

**When to leave off:**

- Dev / scratch / homelab clusters where `kubectl debug node/<name>`
  is sufficient.
- Clusters where the workload class is genuinely "cattle, not pets" —
  CI runners, ephemeral build environments, batch workloads.
- Clusters where the team's runbook explicitly does not reach for
  node-side shell access.

Either choice is acceptable; the default is "no" so that the broader
blast radius is opt-in and visible at the consuming Terragrunt stack,
not silently inherited.

**What the opt-in does *not* grant:**

- It does not allow workload pods to use SSM. Workload-level SSM
  access (e.g., a controller pod that reads SSM Parameter Store)
  goes through Pod Identity with a scoped role per ADR-0002 — never
  via the node role.
- It does not modify the IMDS hop-limit posture from ADR-0007. The
  IMDS-from-pod-network concern is unchanged; what changes is that
  IMDS now hands back a slightly larger credential set when
  successfully reached. This is the bounded blast-radius increase
  the decision accepts in exchange for Session Manager utility.

## Consequences

### Positive

- **Operational escape hatch when nothing else works.** The team
  retains `aws ssm start-session` as the path of last resort for
  nodes where `kubectl debug` isn't viable (wedged kubelet, network
  partition, forensic capture needs). For a one-person team, this
  matters more than the marginal blast-radius reduction from removing
  it.
- **Default is the smaller blast radius.** Consumers who don't need
  SSM don't get SSM. The empty-node-role posture remains the default
  starting point.
- **Per-cluster opt-in is visible in code.** Setting
  `enable_ssm = true` in a Terragrunt stack is a deliberate choice
  recorded in the live repo. Audit-trail-friendly; reviewable in PRs;
  greppable across the fleet.
- **No new components to operate.** Session Manager is an AWS-managed
  service. No agents to deploy beyond the AL2023 default (SSM agent
  ships in the AL2023 EKS AMI). The opt-in is a single managed-
  policy attachment, no node-side configuration changes, no separate
  module.
- **CloudTrail logs Session Manager sessions.** Every `start-session`
  is recorded. The audit posture for "who shelled into the node and
  when" is stronger than SSH would be.

### Negative

- **Slightly broadened IMDS-reachable credential set.** Under
  ADR-0007's hop=2, pod-network pods can hit IMDS. With SSM attached,
  what they get back includes the SSM-management credential. The
  credential's scope is "this node can be managed by SSM" — not
  "read SSM Parameter Store," not "run commands on other instances,"
  not "talk to AWS APIs in general" — but it's a non-empty
  expansion from the ADR-0002 baseline. Accepted, with the per-
  cluster opt-in as the gate.
- **A CIS-aligned auditor will flag any managed policy beyond the
  two ADR-0002 commits.** The compliance-conversation overhead is
  the same shape as ADR-0007's hop-limit conversation: point at the
  documented posture, justify with the operational tradeoff, move
  on. Real but bounded.
- **A wedged-kubelet diagnosis still depends on the SSM agent being
  reachable.** If the kernel is broken badly enough that the SSM
  agent isn't running either, Session Manager fails too. SSM is a
  better escape hatch than nothing; it isn't a universal one. For
  deeply wedged nodes the answer is still "terminate and replace."

### Neutral

- **The opt-in is the only knob.** There is no per-cluster "SSM for
  some operators, not others" — once attached, every operator with
  `ssm:StartSession` against the instance can connect. Access
  control is on the IAM side (which principals can call
  `StartSession` against which instances), not on the node side.
- **SSM agent presence is not in scope.** The AL2023 EKS AMI ships
  with the SSM agent installed. The module's user data does not
  install or remove it. If `enable_ssm = false`, the agent is
  present but lacks the IAM credentials to register with SSM, so it
  no-ops harmlessly.
- **The decision is per-module, not fleet-wide.** Other node groups
  in the fleet (non-secure) can have their own SSM posture. This ADR
  applies only to the secure managed-node-group module's default.

## Alternatives Considered

**Attach `AmazonSSMManagedInstanceCore` by default.** Operationally
slightly more ergonomic — every cluster has the escape hatch out of
the box. Rejected because:

- ADR-0002's posture is "default to the smaller node role; broader
  attachments are visible opt-ins." Defaulting SSM on flips that
  inversion for an operational convenience that the per-cluster
  opt-in handles cleanly.
- The blast-radius expansion (small but real) gets applied uniformly
  to clusters that don't need it (dev, scratch, homelab), not just
  to the production clusters where it pays off.

**Remove SSM entirely, no opt-in.** Force every cluster to use
`kubectl debug` or terminate-and-replace. Rejected for the
operationally-thin-team reason in the Context section. `kubectl
debug` covers most cases but not all; for a one-person operator
running production-relevant secure workloads, foreclosing the
escape hatch is the wrong tradeoff.

**Detached opt-in: a separate "break-glass" IAM role assumed on
demand, never attached to the running node.** A specifically-narrow
role with `AmazonSSMManagedInstanceCore` attached, plus an automation
path (e.g., a Step Functions / Lambda) that attaches the role's
instance profile to a chosen node, opens the session, and detaches
when done. Rejected because:

- EKS managed node groups don't permit instance-profile rotation
  without a node replacement, so "attach for the session, detach
  after" isn't a real shape.
- The automation surface (Step Functions + Lambda + IAM-passing
  permissions) introduces more attack surface than the credential
  it's protecting against.
- The operational cost (latency between "I need to debug this node"
  and "I have a shell") is high for an incident-response path that
  needs to be fast.

**Use a separate instance profile via launch-template version
toggling.** Maintain two launch-template versions, one with SSM and
one without, and roll the node group to the SSM-enabled version
during break-glass. Rejected for the same reason as the detached
opt-in: rolling a node group is an expensive operation to perform in
the middle of an incident.

## References

- ADR-0001 — Cross-module composition via `terraform_remote_state`
  (`var.enable_ssm` is hoisted to Boilerplate-generated Terragrunt;
  module defaults to off).
- ADR-0002 — Node IAM minimization via Pod Identity (the baseline
  node role this ADR refines; SSM is listed there as the documented
  optional attachment).
- ADR-0007 — IMDS hop limit 2 with minimal node IAM (the
  pod-to-IMDS pathway whose blast radius this ADR slightly expands
  when SSM is on).
- DESIGN-0001 — Secure EKS Managed Node Group with gVisor (where
  `var.enable_ssm` and the conditional `aws_iam_role_policy_attachment`
  for `AmazonSSMManagedInstanceCore` live).
- AWS Systems Manager Session Manager:
  <https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html>
- `AmazonSSMManagedInstanceCore` managed policy:
  <https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html>
