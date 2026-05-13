# Terraform Module: Secure EKS Managed Node Group with gVisor

> Working document. Source material for downstream docz artifacts (DESIGN, ADRs,
> IMPL plan). Defines a reusable Terraform module, consumed via Terragrunt, that
> provisions an EKS managed node group meeting our security baseline: minimal
> node IAM (Pod Identity for workload credentials), IMDSv2-only with hop limit
> 2, gVisor runtime for syscall sandboxing, configurable architecture
> (ARM64/Graviton or x86_64), and node labels/taints that gate scheduling to
> security-aware workloads.

---

## 1. Overview

This module provisions a hardened EKS managed node group intended to host
workloads that require additional isolation beyond standard container boundaries
— typically multi-tenant workloads, untrusted third-party code, internal-build
runners, or anything where defense-in-depth at the syscall layer is valuable.

The module supports both **ARM64 (AWS Graviton)** and **x86_64 (Intel/AMD)**
instance types via a single `architecture` input. Graviton is the recommended
default for new workloads (lower cost-per-vcpu, lower energy, mature gVisor
support). x86_64 remains supported for workloads that have not been ported to
ARM64 or require x86-specific instructions.

Four security properties are enforced at the node group level:

1. **Minimal node IAM** — node instance role carries only
   `AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly`. Workload
   AWS credentials come exclusively via EKS Pod Identity Associations attached
   to workload service accounts. No CNI policy, no CSI policy, no inline
   policies on the node role.
2. **IMDSv2-required with hop limit 2** — instance metadata access is
   token-required and bounded. Hop limit 2 (the EKS managed node group default)
   permits pod-network pods to use the Pod Identity Agent at the link-local
   address, while IMDSv1 is fully disabled.
3. **gVisor runtime** — `runsc` is the OCI runtime for opt-in workloads. The
   node ships with the architecture-matched runsc binary installed, containerd
   configured with the `runsc` runtime handler, and a Kubernetes `RuntimeClass`
   named `gvisor` that workloads reference via `spec.runtimeClassName`.
4. **Architecture-pinned scheduling** — each node group is single-architecture
   (EKS managed node groups require a single AMI type). Mixed-architecture
   clusters instantiate the module twice. The `kubernetes.io/arch` label routes
   workloads to the correct architecture; the `workload-class=secure` taint
   prevents accidental scheduling of unprepared workloads.

Node labels and taints route only opted-in workloads to these nodes. Regular
workloads cannot accidentally schedule on a gVisor node and silently fail when
they hit an unimplemented syscall.

---

## 2. Requirements Summary

| Property                | Setting                                                                                    | Rationale                                                                               |
| ----------------------- | ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| Node instance role      | `AmazonEKSWorkerNodePolicy` + `AmazonEC2ContainerRegistryPullOnly` only                    | ADR companion: node IAM minimization via Pod Identity                                   |
| Workload IAM            | Pod Identity Associations on service accounts                                              | Not on the node role                                                                    |
| IMDS version            | IMDSv2 required (`http_tokens = "required"`)                                               | Disable IMDSv1; prevent SSRF-style credential theft                                     |
| IMDS hop limit          | 2                                                                                          | Allows pod-network pods to reach the Pod Identity Agent; EKS managed node group default |
| Architecture            | `arm64` (default) or `amd64`                                                               | Configurable per node group                                                             |
| AMI type                | `AL2023_ARM_64_STANDARD` or `AL2023_x86_64_STANDARD`                                       | Derived from `architecture`                                                             |
| Instance types (arm64)  | Graviton: `m7g.*`, `c7g.*`, `r7g.*`, `m8g.*`, `c8g.*`, `r8g.*`                             | Validated against arm64 families                                                        |
| Instance types (amd64)  | Intel/AMD: `m6i.*`, `m7i.*`, `c6i.*`, `c7i.*`, `r6i.*`, `r7i.*`, `m7a.*`, `c7a.*`, `r7a.*` | Validated against amd64 families                                                        |
| Container runtime       | containerd with `runsc` handler registered                                                 | gVisor opt-in via RuntimeClass                                                          |
| gVisor binary           | `aarch64` or `x86_64` from official release URL                                            | Derived from `architecture`                                                             |
| Kubernetes RuntimeClass | `gvisor` (handler: `runsc`)                                                                | Workload opt-in mechanism                                                               |
| Node labels             | `workload-class=secure`, `runtime=gvisor`, `kubernetes.io/arch=<arch>` (automatic)         | Pod scheduling targeting                                                                |
| Node taints             | `workload-class=secure:NoSchedule`                                                         | Prevents accidental scheduling of non-tolerating workloads                              |
| Disk encryption         | EBS encryption with KMS                                                                    | Standard hardening                                                                      |
| Block public IPs        | `associate_public_ip_address = false`                                                      | Standard hardening                                                                      |
| Detailed monitoring     | Enabled                                                                                    | Operational visibility                                                                  |

---

## 3. Module Architecture

```
modules/eks-secure-nodegroup/
├── main.tf                  # node group, launch template orchestration
├── iam.tf                   # node role with minimal policies
├── launch_template.tf       # launch template with IMDSv2, user data, encryption
├── locals.tf                # architecture-derived locals (AMI type, gVisor URL, defaults)
├── user_data.tf             # user data template rendering
├── runtime_class.tf         # Kubernetes RuntimeClass for gvisor (kubernetes provider)
├── variables.tf             # module inputs
├── outputs.tf               # module outputs
├── versions.tf              # provider version constraints
├── templates/
│   └── user_data.sh.tftpl   # bootstrap + gVisor install + containerd config
└── README.md
```

The module produces:

- An IAM role and instance profile for the node group (architecture-agnostic)
- A launch template with all hardening properties baked in, including
  architecture-specific user data
- An EKS managed node group referencing the launch template, with the matching
  AMI type
- A Kubernetes `RuntimeClass` resource named `gvisor` (via the Kubernetes
  provider)

It expects an EKS cluster already exists and is passed in by name. It does not
manage the cluster itself.

---

## 4. Architecture-Driven Locals

A single `architecture` input drives every architecture-specific decision in the
module. All conditionals collapse into one `locals` block to avoid scattered
ternaries:

```hcl
# locals.tf
locals {
  is_arm64 = var.architecture == "arm64"

  ami_type = local.is_arm64 ? "AL2023_ARM_64_STANDARD" : "AL2023_x86_64_STANDARD"

  # gVisor release URL uses aarch64 or x86_64 as the arch component
  gvisor_arch = local.is_arm64 ? "aarch64" : "x86_64"

  # Kubernetes arch label value (matches Go's GOARCH convention used by Kubernetes)
  k8s_arch = local.is_arm64 ? "arm64" : "amd64"

  # Default instance types per architecture if none specified
  default_instance_types = local.is_arm64 ? [
    "m7g.large", "m7g.xlarge", "m7g.2xlarge",
    "c7g.large", "c7g.xlarge", "c7g.2xlarge",
  ] : [
    "m7i.large", "m7i.xlarge", "m7i.2xlarge",
    "c7i.large", "c7i.xlarge", "c7i.2xlarge",
  ]

  instance_types = length(var.instance_types) > 0 ? var.instance_types : local.default_instance_types

  # Standard labels merged with user-provided additions
  node_labels = merge(
    {
      "workload-class" = "secure"
      "runtime"        = "gvisor"
    },
    var.additional_labels,
  )
}
```

The `kubernetes.io/arch` label is set automatically by kubelet from the kernel —
no need to set it ourselves. It will report `arm64` or `amd64` correctly.

---

## 5. IAM: Minimal Node Role

The node role is intentionally narrow. Anything a workload needs from AWS is
granted via Pod Identity Associations on the workload's service account, not the
node role. This section is architecture-agnostic — IAM permissions are not
arch-specific.

```hcl
# iam.tf
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-${var.nodegroup_name}-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "worker_node" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_pull_only" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.enable_ssm ? 1 : 0
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = aws_iam_role.node.name
  role = aws_iam_role.node.name
}
```

What is _not_ attached, by design:

- `AmazonEKS_CNI_Policy` — moved to the `aws-node` service account via Pod
  Identity on the VPC CNI addon
- `AmazonEBSCSIDriverPolicy` / `AmazonEFSCSIDriverPolicy` — moved to CSI service
  accounts via Pod Identity
- Any inline policies for application controllers (cert-manager, external-dns,
  ALB controller, etc.) — also Pod Identity

The companion brief (`eks-pod-identity-node-iam-minimization.md`) describes the
broader Pod Identity migration. This module assumes that migration is complete
or in progress; it does not provision the addon Pod Identity Associations
itself.

---

## 6. Launch Template: IMDSv2 + Hardening

The launch template enforces IMDSv2, sets hop limit 2, disables IMDSv1, encrypts
the root EBS volume, and renders the gVisor-aware user data. The user data is
templated per-architecture so the correct gVisor binary is downloaded.

```hcl
# launch_template.tf
resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-${var.nodegroup_name}-"

  vpc_security_group_ids = [var.node_security_group_id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.disk_size_gib
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"          # IMDSv2 only
    http_put_response_hop_limit = 2                   # Pod Identity Agent reachable from pod netns
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/user_data.sh.tftpl", {
    cluster_name        = var.cluster_name
    cluster_endpoint    = var.cluster_endpoint
    cluster_ca          = var.cluster_ca_data
    gvisor_release      = var.gvisor_release         # e.g., "release/latest"
    gvisor_arch         = local.gvisor_arch          # "aarch64" or "x86_64"
    extra_kubelet_args  = var.extra_kubelet_args
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
      "Name"                                       = "${var.cluster_name}-${var.nodegroup_name}"
      "architecture"                               = var.architecture
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}
```

### Why hop limit 2 specifically

EKS managed node groups default to hop limit 2 because the Pod Identity Agent
runs in the host network namespace and pods reach it via the link-local address
`169.254.170.23`. With hop limit 1, regular pod-network pods cannot reach IMDS
or the Pod Identity Agent's endpoint — only hostNetwork pods can.

Hop limit 2 trades a small posture concession (pod-network pods _can_ reach
IMDS) for compatibility with the Pod Identity model. Because the node role is
minimal, the IMDS access is near-empty in blast radius. This is the explicit
tradeoff documented in the Pod Identity initiative brief — the durable defense
is the empty node role, not the hop limit.

---

## 7. User Data: Bootstrap + gVisor Installation

The user data is templated per-architecture. The `gvisor_arch` value (`aarch64`
for ARM64, `x86_64` for x86_64) selects the correct binary from the official
gVisor release URL.

```bash
# templates/user_data.sh.tftpl
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: text/x-shellscript; charset="us-ascii"
MIME-Version: 1.0

#!/bin/bash
set -euo pipefail

#-----------------------------------------------------------------------
# Install gVisor (runsc + containerd shim) for ${gvisor_arch}
#-----------------------------------------------------------------------
GVISOR_URL="https://storage.googleapis.com/gvisor/releases/${gvisor_release}/${gvisor_arch}"

cd /tmp
curl -fsSL -O "$${GVISOR_URL}/runsc"
curl -fsSL -O "$${GVISOR_URL}/runsc.sha512"
curl -fsSL -O "$${GVISOR_URL}/containerd-shim-runsc-v1"
curl -fsSL -O "$${GVISOR_URL}/containerd-shim-runsc-v1.sha512"

sha512sum -c runsc.sha512
sha512sum -c containerd-shim-runsc-v1.sha512

chmod +x runsc containerd-shim-runsc-v1
mv runsc containerd-shim-runsc-v1 /usr/local/bin/

#-----------------------------------------------------------------------
# Add runsc runtime to containerd via drop-in
# AL2023 EKS AMI manages /etc/containerd/config.toml; we use a drop-in
# in /etc/containerd/config.d/ to avoid conflicts with nodeadm-managed
# content.
#-----------------------------------------------------------------------
mkdir -p /etc/containerd/config.d

cat > /etc/containerd/config.d/runsc.toml <<'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
  pod_annotations = ["dev.gvisor.*"]
  privileged_without_host_devices = false

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
  TypeUrl = "io.containerd.runsc.v1.options"
  ConfigPath = "/etc/containerd/runsc.toml"
EOF

cat > /etc/containerd/runsc.toml <<'EOF'
log_path = "/var/log/runsc/%ID%/shim.log"
log_level = "warning"

[runsc_config]
debug = "false"
platform = "systrap"
network = "sandbox"
EOF

systemctl restart containerd

ctr --address=/run/containerd/containerd.sock plugins ls | grep -q "runsc" || {
  echo "runsc runtime not detected by containerd"
  exit 1
}

echo "gVisor installation complete for ${gvisor_arch}"
--//--
```

### Why `systrap` platform

gVisor supports multiple "platforms" — the mechanism by which it intercepts
syscalls — including `ptrace`, `kvm`, and `systrap`. `systrap` is the modern
default, uses `seccomp` + signals, supports both ARM64 and x86_64, and works on
Nitro-based EC2 instances without nested virtualization. `kvm` would be faster
but requires nested virtualization (not available on most EC2 instance types).
`ptrace` is the legacy fallback.

### Why `network = "sandbox"`

gVisor's sandboxed network stack (`netstack`) provides a userspace TCP/IP
implementation that doesn't share state with the host kernel. The alternative
(`network = "host"`) gives the container direct host network access, which
negates much of the isolation value of running gVisor in the first place. Use
sandbox network unless a specific workload demonstrably requires host network.

---

## 8. EKS Managed Node Group

```hcl
# main.tf
resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = var.nodegroup_name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  ami_type       = local.ami_type           # AL2023_ARM_64_STANDARD or AL2023_x86_64_STANDARD
  capacity_type  = var.capacity_type
  instance_types = local.instance_types     # validated against the architecture

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  update_config {
    max_unavailable_percentage = var.max_unavailable_percentage
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  labels = local.node_labels

  taint {
    key    = "workload-class"
    value  = "secure"
    effect = "NO_SCHEDULE"
  }

  dynamic "taint" {
    for_each = var.additional_taints
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = merge(var.tags, {
    "Name"         = "${var.cluster_name}-${var.nodegroup_name}"
    "architecture" = var.architecture
  })

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      scaling_config[0].desired_size,  # let autoscaler manage
    ]
  }
}
```

### Architecture-specific instance type guidance

**ARM64 (default).** Use Graviton families (m7g/c7g/r7g/m8g/c8g/r8g). Lower
cost, better energy efficiency, increasingly broad EC2 availability. Recommended
for new secure workloads.

**x86_64.** Use current-gen Intel (m7i/c7i/r7i) or AMD (m7a/c7a/r7a). Required
for workloads with x86-specific dependencies or workloads not yet ported to
ARM64. Slightly broader instance type selection and feature parity with legacy
tooling.

Avoid burstable instances (`t4g`, `t3`) in production for predictable gVisor
performance. gVisor's syscall interception has measurable CPU overhead
(typically 5–15% depending on syscall mix); burstable credits would mask this
and cause throttling under load.

---

## 9. Kubernetes RuntimeClass + Workload Opt-In

A `RuntimeClass` resource in the cluster declares the `gvisor` handler.
Workloads opt in by setting `spec.runtimeClassName: gvisor`. The RuntimeClass is
architecture-agnostic — workloads still need to pull architecture-matched
container images.

```hcl
# runtime_class.tf
resource "kubernetes_manifest" "gvisor_runtime_class" {
  count = var.create_runtime_class ? 1 : 0

  manifest = {
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata = {
      name = "gvisor"
    }
    handler = "runsc"
    scheduling = {
      nodeSelector = {
        "workload-class" = "secure"
        "runtime"        = "gvisor"
      }
      tolerations = [{
        key      = "workload-class"
        value    = "secure"
        operator = "Equal"
        effect   = "NoSchedule"
      }]
    }
  }
}
```

The RuntimeClass `scheduling` block injects the matching nodeSelector and
toleration into any pod that references it — workload authors don't manage both
themselves. For mixed-architecture clusters where workloads target a specific
arch, add `kubernetes.io/arch` to the pod's own nodeSelector:

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      runtimeClassName: gvisor
      nodeSelector:
        kubernetes.io/arch: arm64 # or amd64
      containers:
        - name: app
          image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/secure-app:v1.2.3
```

If the container image is a multi-arch manifest, no nodeSelector arch pin is
needed — Kubernetes will pull the right variant for whichever node the pod lands
on.

When provisioning multiple secure node groups (e.g., both ARM64 and x86_64 in
the same cluster), set `create_runtime_class = true` on only one of the module
instantiations and `false` on the rest. The RuntimeClass is cluster-scoped;
multiple creators would conflict.

---

## 10. gVisor Syscall Compatibility — Detail

This is the section most often skipped during gVisor evaluations. Workload
compatibility with gVisor is determined entirely by which syscalls the workload
uses and whether gVisor implements them. The numbers and categorization below
are derived from the official gVisor compatibility tables (linked in References)
and grouped by practical impact for typical container workloads.

### Coverage summary

| Architecture           | Total syscalls | Implemented (full or partial) | Unsupported |
| ---------------------- | -------------- | ----------------------------- | ----------- |
| ARM64 (`linux/arm64`)  | 294            | 240                           | 54          |
| x86_64 (`linux/amd64`) | ~360           | ~310                          | ~50         |

x86*64 has more syscalls in absolute numbers because it carries the legacy
pre-2.6.16 syscall set (`open`, `stat`, `fork`, `dup2`, `epoll_create`, etc.)
that ARM64 architecture deprecates in favor of the `*at` variants. The set of
\_gVisor design-level unsupported* syscalls is largely the same across both
architectures — they represent decisions about what to implement, not
architecture limitations.

For most modern workloads, the compatibility profile is effectively identical on
both architectures.

### Impact categories — unsupported syscalls

The 54 ARM64 unsupported syscalls (and the equivalent x86_64 set) fall into
seven categories with very different practical implications:

#### Category A — Privileged kernel operations (no workload impact)

These require capabilities containers normally don't have (`CAP_SYS_ADMIN`,
`CAP_SYS_MODULE`, `CAP_SYS_BOOT`, etc.) and would be blocked on any production
Kubernetes cluster regardless of runtime. Their absence in gVisor is not a
regression — they're already inaccessible to standard containerized workloads.

- `kexec_load`, `init_module`, `delete_module`, `finit_module` — kernel module
  loading
- `reboot`, `swapon`, `swapoff` — system management
- `acct` — process accounting
- `nfsservctl` — NFS server (removed from Linux 3.1 anyway)
- `quotactl` — disk quota administration
- `settimeofday`, `adjtimex`, `clock_adjtime` — system time setting
- `vhangup` — terminal control
- `lookup_dcookie` — opaque cookie lookup
- `ioprio_set`, `ioprio_get` (without `CAP_SYS_ADMIN`)

**Impact: none.** No legitimate containerized workload uses these.

#### Category B — Filesystem operations (some workload impact)

- `fanotify_init`, `fanotify_mark` — file access notification API. Used by AV
  scanners, audit daemons, some backup tools. **Impacted workloads:**
  in-container AV scanners (rare), Sysdig/Falco-style runtime security agents
  running _inside_ the sandbox (these should be on the host anyway).
- `name_to_handle_at`, `open_by_handle_at` — file handle operations. Used by
  some backup tools (e.g., for incremental snapshots) and overlayfs internals.
  **Impacted workloads:** specialized backup tools that operate on file handles.
  Most don't.
- `open_tree`, `move_mount`, `fsopen`, `fsconfig`, `fsmount`, `fspick` — the new
  Linux mount API (Linux 5.2+). Most tools still use the legacy `mount(2)` which
  gVisor supports. **Impacted workloads:** systemd-nspawn, some
  container-in-container tools (unlikely in our secure-workload context).
- `copy_file_range` — kernel-space file copy fast path. **Impacted workloads:**
  none meaningfully — `cp`, `rsync`, and `dd` all fall back to read/write loops,
  just with measurable performance cost on large file copies.

**Impact: low to moderate.** Most workloads have transparent fallbacks.
Specialized filesystem tools may behave differently. Backup workloads should be
validated.

#### Category C — Async I/O (potentially significant performance impact)

- `io_setup`, `io_destroy`, `io_submit`, `io_cancel`, `io_getevents` — Linux
  native AIO. _Partial_ support — user ring optimizations aren't implemented, so
  it functions but slower.
- `io_uring_register` — fully unimplemented.
- `io_uring_setup`, `io_uring_enter` — partial support, not all flags work.
- `io_pgetevents` — unimplemented.

**Impact: significant for I/O-heavy workloads.** Modern high-performance
databases and storage engines increasingly target `io_uring` (ScyllaDB, modern
PostgreSQL builds, some Rust async runtimes via `tokio-uring`). Falling back to
epoll-based polling is generally functional but materially slower. Workloads
where IOPS is the limiting factor should be benchmarked before opting into
gVisor. Databases using Linux AIO via `O_DIRECT` (PostgreSQL with
`effective_io_concurrency`, MySQL with `innodb_use_native_aio`) will run but
with reduced throughput.

#### Category D — Memory and NUMA operations (moderate impact)

- `mlock`, `munlock`, `mlockall`, `munlockall`, `mlock2` — _stub_
  implementations. The sandbox lacks permissions to actually lock pages in
  memory. Calls succeed but pages aren't actually pinned.
- `mbind`, `set_mempolicy`, `get_mempolicy` — NUMA memory policies. Stub
  implementations. gVisor advertises a single NUMA node regardless of host
  topology.
- `migrate_pages`, `move_pages` — NUMA page migration. Unimplemented.
- `pkey_mprotect`, `pkey_alloc`, `pkey_free` — memory protection keys (Intel MPK
  / ARM equivalent). Unimplemented.
- `userfaultfd` — userspace page fault handling. Unimplemented.
- `remap_file_pages` — deprecated since Linux 3.16. Unimplemented.
- `madvise` — partial; only `MADV_DONTNEED` and `MADV_DONTFORK` honored. Others
  silently ignored.

**Impact: moderate.** Crypto libraries that rely on `mlock` to prevent secrets
from swapping to disk (libsodium, OpenSSL with `OPENSSL_MLOCK`) will not
actually lock memory — the call succeeds but the memory is still swappable.
Functionally OK on most cloud VMs (which don't swap anyway), but worth knowing.
NUMA-aware databases (Redis, Cassandra, large JVMs) will see a single NUMA node
and lose tuning effectiveness. JVMs using `userfaultfd` for GC concurrency (ZGC
under some configurations) won't function — use a different GC. Apps using
memory protection keys for in-process isolation (CRIU, some hardened crypto)
won't work.

#### Category E — Scheduling primitives (minor impact)

- `sched_setattr`, `sched_getattr` — extended scheduling. Unimplemented
  entirely.
- `sched_setscheduler`, `sched_getscheduler`, `sched_setparam`, `sched_getparam`
  — _stub_ implementations.
- `sched_setaffinity`, `sched_getaffinity` — stub implementations.
- `sched_get_priority_max`, `sched_get_priority_min` — stubs.
- `sched_rr_get_interval` — unimplemented.
- `setpriority`, `getpriority` — stubs.

**Impact: minor for typical workloads, significant for real-time apps.** gVisor
does not implement a Linux-compatible scheduler — the host's scheduler runs
everything. CPU affinity calls succeed but don't pin threads. Real-time
scheduling (`SCHED_FIFO`, `SCHED_RR`) won't behave as expected. Most container
workloads (web services, batch jobs, databases) don't depend on Linux scheduler
primitives. Game servers, audio processing, and latency-sensitive HFT-style
workloads may need to stay off gVisor.

#### Category F — eBPF and observability (significant for specific workloads)

- `bpf` — the entire BPF syscall family is unimplemented when called by
  unprivileged processes (returns `EPERM`; returns `ENOSYS` to root).
- `perf_event_open` — performance counters. Unimplemented.

**Impact: blocks eBPF-internal workloads.** Workloads that load BPF programs
_inside_ the sandbox (modern observability agents trying to self-instrument,
certain Cilium-based service mesh data planes, internal-network tracing tools)
will fail. The vast majority of workloads don't load their own BPF programs —
they're observed _from outside_ by host-level agents (Falco, Tetragon, Cilium
agent), which run on the node, not inside sandboxed pods, and continue working
normally. Profilers using `perf_event_open` (e.g., perf, async-profiler in some
modes) won't function inside the sandbox.

#### Category G — IPC and signaling (minor impact)

- `mq_timedsend`, `mq_timedreceive`, `mq_notify`, `mq_getsetattr` — POSIX
  message queues `mq_*` variants. Note that `mq_open` and `mq_unlink` _are_
  supported. **Impact:** apps using POSIX message queues with timed operations
  will fail. Rare.
- `vmsplice` — zero-copy splice from user pages. Used in some high-performance
  media processing and HFT. **Impact:** workloads relying on it will see
  fallback behavior, but most don't use it.
- `kcmp` — compare two processes for shared resources. Used by some debuggers.
  **Impact:** minor.
- `setfsuid`, `setfsgid` — deprecated filesystem UID/GID. Most apps don't use
  them. **Impact:** minor.
- `personality` — emulate other UNIX behaviors. Unable to change personality.
  **Impact:** ancient binary compatibility shims — minor.
- `add_key`, `request_key` — kernel keyring. Not available to user. **Impact:**
  apps using kernel keyring for credential caching (some Kerberos / SSSD
  configurations) won't work.

### Partial-support syscalls worth knowing

Some syscalls work but with caveats that matter for specific workloads:

- `clone` / `clone3` — most flags supported. Missing: `CLONE_NEWCGROUP`,
  `CLONE_NEWTIME`, `CLONE_PARENT`, `CLONE_CLEAR_SIGHAND`, `CLONE_SYSVSEM`,
  `CLONE_INTO_CGROUP`. **Impact:** apps that create new cgroup namespaces or use
  time namespaces won't work. Most apps don't.
- `unshare` — same missing namespace flags as `clone`. **Impact:** same as
  above.
- `futex` — robust futexes (`FUTEX_LOCK_PI`, `FUTEX_TRYLOCK_PI` with robust list
  integration) not supported. **Impact:** glibc's robust mutex feature won't
  recover from crashed mutex-holders. Rarely depended on.
- `ptrace` — `PTRACE_PEEKSIGINFO` and `PTRACE_SECCOMP_GET_FILTER` not supported.
  Most gdb and strace functionality works.
- `inotify_*` — only events from inside the sandbox are visible. **Impact:** if
  a workload watches files that other host processes are modifying, it won't see
  those events. Inside-pod file watching works normally.
- `syslog` — returns a dummy message for security. **Impact:** apps that read
  the kernel log buffer get nothing useful. Most apps log to files or stdout,
  not syslog.
- `getrusage` — `ru_maxrss`, `ru_minflt`, `ru_majflt`, `ru_inblock`,
  `ru_oublock` are zero. CPU time fields are low precision. **Impact:** in-app
  resource reporting is incomplete.
- `sysinfo` — `loads`, `sharedram`, `bufferram`, `totalswap`, `freeswap`,
  `totalhigh`, `freehigh` are zero. **Impact:** apps using sysinfo for memory
  pressure detection get incomplete data; use cgroup metrics instead.
- `prctl` — many options supported but not all. **Impact:** specific options
  (e.g., `PR_SET_MM_*` for advanced memory map manipulation) won't work. Most
  common uses (`PR_SET_NAME`, `PR_SET_DUMPABLE`, `PR_GET_KEEPCAPS`) work fine.
- `keyctl` — only session keyrings with zero keys. **Impact:** apps trying to
  use the kernel keyring fail.

### Workload compatibility matrix

Practical guidance for evaluating workload candidates:

| Workload type                            | gVisor compatibility           | Notes                                                                                          |
| ---------------------------------------- | ------------------------------ | ---------------------------------------------------------------------------------------------- |
| Go services (gRPC, HTTP)                 | **Excellent**                  | Go runtime uses well-supported syscalls; minimal overhead beyond baseline syscall interception |
| Python services (Flask/Django/FastAPI)   | **Excellent**                  | CPython uses standard syscalls; multiprocessing works                                          |
| Node.js services                         | **Excellent**                  | libuv works on supported syscalls; no major gaps                                               |
| Java services (Spring, etc.)             | **Good**                       | Works with G1/Parallel GC; avoid ZGC configurations that use userfaultfd                       |
| Rust services (tokio)                    | **Excellent**                  | tokio uses epoll; tokio-uring will fall back or fail                                           |
| nginx, Caddy, Apache                     | **Excellent**                  | Standard syscalls only                                                                         |
| PostgreSQL (no AIO)                      | **Good**                       | Without `effective_io_concurrency` tuning; with AIO, reduced throughput                        |
| MySQL/MariaDB                            | **Good**                       | InnoDB AIO works but slower                                                                    |
| Redis                                    | **Good**                       | Single-threaded I/O works fine; cluster mode works; lose NUMA tuning                           |
| Cassandra/ScyllaDB                       | **Poor**                       | Heavy AIO/io_uring use; expect significant performance regression                              |
| Modern observability agents (in-pod BPF) | **Fails**                      | bpf syscall unimplemented                                                                      |
| CI/CD job runners (Buildah, kaniko)      | **Variable**                   | Container build often needs mount API; validate per-tool                                       |
| Game servers, real-time audio            | **Poor**                       | Scheduling primitives are stubs                                                                |
| HPC/scientific computing with NUMA       | **Poor**                       | NUMA invisible; mlock is a stub                                                                |
| Crypto with mlock-secured secrets        | **Functional but unprotected** | mlock succeeds but doesn't actually lock                                                       |
| ML inference (CPU)                       | **Good**                       | Provided no GPU access needed; gVisor GPU passthrough is separate concern                      |

### Recommended evaluation procedure for new workloads

Before declaring a workload eligible for the secure node group:

1. **Static check**: review the workload's runtime/language for known patterns:
   - Uses Linux AIO or io_uring → expect performance regression, benchmark
   - Loads BPF programs → will fail, use a different node group
   - Uses NUMA pinning → will lose tuning, validate behavior
   - Real-time scheduling → will lose timing guarantees
   - mlock for secrets → review the security model; mlock is a stub

2. **Runtime test**: deploy the workload to a dev gVisor node, run for a
   representative period, and check:
   - Process startup logs for `ENOSYS`, `EPERM`, "Operation not permitted"
     errors
   - Application-level error rates compared to baseline
   - p95/p99 latency vs baseline (syscall overhead typically adds 5-15%)
   - Sandboxed-process unexpected crashes or restarts

3. **Compatibility sweep**: run `strace -c` (or equivalent) against the workload
   on a non-gVisor node to inventory syscalls actually used, then
   cross-reference against the gVisor compatibility table.

4. **Document the result**: workload compatibility is per-workload and
   per-release. Capture the evaluation in the workload's documentation so future
   changes can be re-validated.

---

## 11. Module Inputs and Outputs

### Inputs

```hcl
# variables.tf
variable "cluster_name" {
  description = "Name of the EKS cluster to attach the node group to"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint (passed to bootstrap)"
  type        = string
}

variable "cluster_ca_data" {
  description = "Base64-encoded cluster CA certificate"
  type        = string
}

variable "nodegroup_name" {
  description = "Name of this node group"
  type        = string
}

variable "architecture" {
  description = "CPU architecture for this node group. arm64 (Graviton, recommended) or amd64 (Intel/AMD)."
  type        = string
  default     = "arm64"
  validation {
    condition     = contains(["arm64", "amd64"], var.architecture)
    error_message = "architecture must be 'arm64' or 'amd64'."
  }
}

variable "subnet_ids" {
  description = "Subnet IDs for node placement (private only, typically)"
  type        = list(string)
}

variable "node_security_group_id" {
  description = "Security group ID applied to node ENIs"
  type        = string
}

variable "instance_types" {
  description = "Instance types eligible for the node group. Must match the chosen architecture. If empty, sensible defaults are used."
  type        = list(string)
  default     = []
  validation {
    condition = (
      length(var.instance_types) == 0 ||
      (var.architecture == "arm64" && alltrue([
        for it in var.instance_types : can(regex("^(m|c|r|x|t)[0-9]+g[a-z]*\\.", it))
      ])) ||
      (var.architecture == "amd64" && alltrue([
        for it in var.instance_types : can(regex("^(m|c|r|x|t)[0-9]+(i|a)?\\.", it)) && !can(regex("g[a-z]*\\.", it))
      ]))
    )
    error_message = "instance_types must match the chosen architecture. arm64 requires Graviton families (e.g., m7g, c7g, r7g). amd64 requires Intel (m7i, c7i, r7i) or AMD (m7a, c7a, r7a) families."
  }
}

variable "capacity_type" {
  type    = string
  default = "ON_DEMAND"
  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "desired_size" {
  type    = number
  default = 1
}

variable "min_size" {
  type    = number
  default = 0
}

variable "max_size" {
  type    = number
  default = 10
}

variable "max_unavailable_percentage" {
  type    = number
  default = 33
}

variable "disk_size_gib" {
  type    = number
  default = 100
}

variable "ebs_kms_key_arn" {
  description = "KMS key for EBS volume encryption"
  type        = string
}

variable "enable_ssm" {
  description = "Attach AmazonSSMManagedInstanceCore for Session Manager break-glass"
  type        = bool
  default     = true
}

variable "gvisor_release" {
  description = "gVisor release channel (e.g., 'release/latest', 'release/20260301.0')"
  type        = string
  default     = "release/latest"
}

variable "create_runtime_class" {
  description = "Create the cluster-wide gVisor RuntimeClass. Set false on all but one node group when multiple are deployed to the same cluster."
  type        = bool
  default     = true
}

variable "additional_labels" {
  type    = map(string)
  default = {}
}

variable "additional_taints" {
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

variable "extra_kubelet_args" {
  description = "Additional kubelet arguments appended to bootstrap"
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

### Outputs

```hcl
# outputs.tf
output "nodegroup_name" {
  value = aws_eks_node_group.this.node_group_name
}

output "architecture" {
  value = var.architecture
}

output "ami_type" {
  value = local.ami_type
}

output "node_role_arn" {
  description = "ARN of the node instance role. Pod Identity Associations attach to workload SAs, not this role."
  value       = aws_iam_role.node.arn
}

output "launch_template_id" {
  value = aws_launch_template.node.id
}

output "launch_template_latest_version" {
  value = aws_launch_template.node.latest_version
}

output "runtime_class_name" {
  description = "Kubernetes RuntimeClass name workloads should reference via spec.runtimeClassName"
  value       = var.create_runtime_class ? "gvisor" : null
}

output "node_labels" {
  value = local.node_labels
}

output "node_taints" {
  value = concat(
    [{ key = "workload-class", value = "secure", effect = "NoSchedule" }],
    var.additional_taints,
  )
}
```

---

## 12. Terragrunt Usage Pattern

Terragrunt wraps the module at the environment level. For mixed-architecture
clusters, the module is instantiated once per architecture under sibling
directories.

### Graviton (default)

```hcl
# live/prod/us-east-1/clusters/platform/secure-nodegroup-arm64/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "git::ssh://git@github.com/our-org/terraform-modules.git//modules/eks-secure-nodegroup?ref=v1.4.2"
}

dependency "cluster" {
  config_path = "../cluster"
}

dependency "vpc" {
  config_path = "../../../network/vpc"
}

dependency "kms" {
  config_path = "../../../security/kms-ebs"
}

inputs = {
  cluster_name           = dependency.cluster.outputs.cluster_name
  cluster_endpoint       = dependency.cluster.outputs.cluster_endpoint
  cluster_ca_data        = dependency.cluster.outputs.cluster_ca_data
  node_security_group_id = dependency.cluster.outputs.node_security_group_id
  subnet_ids             = dependency.vpc.outputs.private_subnet_ids
  ebs_kms_key_arn        = dependency.kms.outputs.key_arn

  nodegroup_name = "secure-gvisor-arm64"
  architecture   = "arm64"

  instance_types = [
    "m7g.large", "m7g.xlarge",
    "c7g.large", "c7g.xlarge",
  ]

  desired_size = 2
  min_size     = 2
  max_size     = 12

  enable_ssm           = true
  gvisor_release       = "release/latest"
  create_runtime_class = true     # this NG creates the cluster RuntimeClass

  tags = {
    environment    = "prod"
    cluster        = "platform"
    workload-class = "secure"
    managed-by     = "terragrunt"
  }
}
```

### x86_64 (companion node group, same cluster)

```hcl
# live/prod/us-east-1/clusters/platform/secure-nodegroup-amd64/terragrunt.hcl
include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "git::ssh://git@github.com/our-org/terraform-modules.git//modules/eks-secure-nodegroup?ref=v1.4.2"
}

dependency "cluster" {
  config_path = "../cluster"
}

dependency "arm64_nodegroup" {
  config_path = "../secure-nodegroup-arm64"        # ensure arm64 NG creates RuntimeClass first
  skip_outputs = true
}

dependency "vpc" {
  config_path = "../../../network/vpc"
}

dependency "kms" {
  config_path = "../../../security/kms-ebs"
}

inputs = {
  cluster_name           = dependency.cluster.outputs.cluster_name
  cluster_endpoint       = dependency.cluster.outputs.cluster_endpoint
  cluster_ca_data        = dependency.cluster.outputs.cluster_ca_data
  node_security_group_id = dependency.cluster.outputs.node_security_group_id
  subnet_ids             = dependency.vpc.outputs.private_subnet_ids
  ebs_kms_key_arn        = dependency.kms.outputs.key_arn

  nodegroup_name = "secure-gvisor-amd64"
  architecture   = "amd64"

  instance_types = [
    "m7i.large", "m7i.xlarge",
    "c7i.large", "c7i.xlarge",
  ]

  desired_size = 1
  min_size     = 0
  max_size     = 6

  enable_ssm           = true
  gvisor_release       = "release/latest"
  create_runtime_class = false      # arm64 NG already created it

  tags = {
    environment    = "prod"
    cluster        = "platform"
    workload-class = "secure"
    managed-by     = "terragrunt"
  }
}
```

---

## 13. Validation

### Post-deploy checks

After the node group provisions and at least one node is `Ready`:

```sh
# Verify the node has the expected labels and taints
kubectl get nodes -l workload-class=secure -o custom-columns=\
NAME:.metadata.name,ARCH:.metadata.labels.kubernetes\\.io/arch,RUNTIME:.metadata.labels.runtime,TAINTS:.spec.taints

# Verify RuntimeClass is registered (only one, regardless of how many node groups)
kubectl get runtimeclass gvisor

# Validate the runsc handler on each architecture
for arch in arm64 amd64; do
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gvisor-validation-${arch}
spec:
  runtimeClassName: gvisor
  nodeSelector:
    kubernetes.io/arch: ${arch}
  containers:
  - name: dmesg
    image: public.ecr.aws/docker/library/busybox:latest
    command: ["sh", "-c", "dmesg | head -5 && uname -a && sleep 30"]
EOF
done

kubectl logs gvisor-validation-arm64
kubectl logs gvisor-validation-amd64
# Expected: dmesg output mentions "Starting gVisor..." and uname reports the matching architecture
```

### Smoke test for IMDS lockdown

```sh
# From a workload pod on a secure node, verify IMDSv1 is blocked
kubectl exec -it <pod-on-secure-node> -- sh -c '
  curl -sS http://169.254.169.254/latest/meta-data/ || echo "IMDSv1 correctly blocked"
  TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
  curl -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id
'
# Expected: IMDSv1 returns 401, IMDSv2 returns the instance ID
```

---

## 14. Caveats and Gotchas

**Architecture-specific image requirements.** Workloads need container images
matching the node architecture. Multi-arch images (built with
`docker buildx --platform linux/amd64,linux/arm64`) work transparently.
Single-arch images fail to schedule with `exec format error`. Confirm CI/CD
produces multi-arch images for any workload that might target either node group.

**gVisor syscall coverage gaps are real and consequential for specific workload
classes.** See Section 10. Plan for a compatibility validation phase before any
production workload is migrated. Highest-risk categories: heavy async I/O
(databases, storage engines), eBPF-internal workloads, NUMA-tuned applications,
real-time scheduling.

**Performance overhead is real.** Expect 5–15% CPU overhead for typical
workloads, occasionally higher for syscall-intensive applications. Right-size
accordingly.

**gVisor + hostNetwork is incompatible-ish.** gVisor's `netstack` sandboxed
networking is the point of running gVisor; using `hostNetwork: true` bypasses
it. If a workload needs both gVisor sandboxing _and_ hostNetwork, gVisor is the
wrong tool — use a different node group. The hostNetwork optimization initiative
and this secure node group target distinct workload classes.

**RuntimeClass is cluster-scoped, not per-node-group.** With multiple node
groups in the same cluster, set `create_runtime_class = true` on exactly one and
`false` on the others. Terragrunt's `dependency` block can enforce ordering (see
Section 12). The `scheduling` block on the RuntimeClass injects labels that
match any secure node group regardless of architecture — for arch-specific
targeting, pods add their own `kubernetes.io/arch` nodeSelector.

**Container image architecture must match.** Stated again because it's a
frequent stumbling block. Single-arch x86_64 images on Graviton fail to
schedule. Single-arch arm64 images on x86_64 fail to schedule. Multi-arch images
work everywhere.

**Containerd config drop-in directory.** The drop-in path
`/etc/containerd/config.d/` requires containerd 1.6+ with `imports` support. The
EKS AL2023 AMI ships containerd 1.7+, which supports this. For older AMIs, the
user data would need to append to `/etc/containerd/config.toml` directly.

**Pod Identity Agent must be installed at cluster level.** This module assumes
the Pod Identity Agent addon is installed on the cluster. Without it, Pod
Identity Associations won't function, and workloads that need AWS credentials
will fail (correctly, since the node role has nothing for them to fall back to).

**EBS encryption KMS key must permit the node role to use it.** The KMS key
policy must allow the node role's `kms:Decrypt`, `kms:GenerateDataKey`, etc.

**Spot capacity availability for Graviton vs x86_64.** Graviton spot capacity
varies by region and family. x86_64 spot capacity is generally deeper. For
production-critical secure workloads, default to ON_DEMAND.

**gVisor version pinning.** `release/latest` is convenient for dev but in
production pin to a specific dated release (e.g., `release/20260301.0`) and
update via Renovate or a planned cadence. Latest-tracking introduces silent
behavioral changes — and since the syscall implementation set changes between
releases, a previously-working workload could break after a gVisor update.

---

## 15. Open Questions / Decisions Needed

These should become ADRs:

1. **Default architecture for new secure workloads.** ARM64 / Graviton is the
   recommended default per this doc, but should that be an org-wide standard or
   per-workload? Recommendation: ARM64 default; opt out per workload only with
   documented justification.
2. **Default instance type sets per architecture.** The defaults above are
   starting points. Validate against actual workload sizing requirements before
   committing the module to v1.
3. **Spot capacity strategy for secure workloads.** ON_DEMAND only for the
   security-sensitive class? Or allow SPOT with appropriate PDBs?
   Recommendation: ON_DEMAND default with explicit per-workload SPOT opt-in.
4. **gVisor release pinning strategy.** Pin to a dated release fleet-wide and
   update via Renovate, or allow per-cluster pinning? Recommendation: org-wide
   Renovate-managed pin.
5. **AL2 fallback support.** Recommendation: AL2023 only.
6. **Bottlerocket as an alternative AMI option.** Bottlerocket supports gVisor
   and has a reduced attack surface — worth evaluating as a future variant.
7. **GuardDuty Runtime Monitoring + gVisor interaction.** GuardDuty's runtime
   agent uses eBPF. gVisor's syscall interception may interfere with or
   invalidate some findings on sandboxed workloads. Validate before relying on
   both.
8. **Wiz sensor compatibility on Graviton ARM64.** Confirm Wiz Kubernetes
   sensor's ARM64 build is available and tested. Secure nodes without runtime
   security telemetry would be a gap.
9. **Multi-cluster RuntimeClass coordination.** Documented above; consider
   whether a separate cluster-bootstrap module should own the RuntimeClass
   instead of any individual node group module.
10. **Workload compatibility documentation pattern.** Where do per-workload
    compatibility evaluations live? Recommendation: in the workload's own repo
    as part of its deployment manifest documentation.

---

## 16. Proposed docz Decomposition

| Doc Type | Title                                                      | Contents                                                                                                             |
| -------- | ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| DESIGN   | Secure EKS Managed Node Group Module                       | Sections 3-12 (architecture, IAM, launch template, gVisor, EKS node group, RuntimeClass, inputs/outputs, Terragrunt) |
| ADR      | gVisor as the syscall sandboxing runtime                   | Why gVisor over Kata, Firecracker, or seccomp-only                                                                   |
| ADR      | ARM64 as default secure-workload architecture              | Why Graviton default, x86_64 opt-in                                                                                  |
| ADR      | IMDS hop limit 2 with minimal node IAM                     | The explicit tradeoff between hop=1 and hop=2                                                                        |
| ADR      | RuntimeClass scheduling injection vs explicit nodeSelector | Why we let RuntimeClass drive scheduling                                                                             |
| PLAN     | Workload compatibility validation procedure                | Section 10's evaluation procedure formalized                                                                         |
| IMPL     | Phase 1 — Module scaffold and homelab validation           | First implementation milestone                                                                                       |
| IMPL     | Phase 2 — Single dev cluster deployment                    | Both arm64 and amd64 NGs on one dev cluster                                                                          |
| IMPL     | Phase 3 — Production rollout per cluster                   | Per-cluster rollout with workload compatibility gating                                                               |

---

## 17. References

- gVisor official documentation — <https://gvisor.dev/docs/>
- gVisor ARM64 syscall compatibility —
  <https://gvisor.dev/docs/user_guide/compatibility/linux/arm64/>
- gVisor x86_64 syscall compatibility —
  <https://gvisor.dev/docs/user_guide/compatibility/linux/amd64/>
- gVisor installation guide — <https://gvisor.dev/docs/user_guide/install/>
- gVisor production guide — <https://gvisor.dev/docs/user_guide/production/>
- gVisor + containerd quick start —
  <https://gvisor.dev/docs/user_guide/containerd/quick_start/>
- Kubernetes RuntimeClass —
  <https://kubernetes.io/docs/concepts/containers/runtime-class/>
- EKS managed node groups with launch templates —
  <https://docs.aws.amazon.com/eks/latest/userguide/launch-templates.html>
- AL2023 AMI nodeadm bootstrap —
  <https://awslabs.github.io/amazon-eks-ami/nodeadm/>
- AWS Graviton getting started —
  <https://github.com/aws/aws-graviton-getting-started>
- EC2 IMDS metadata options —
  <https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html>
- Companion brief: `eks-pod-identity-node-iam-minimization.md`
- Companion brief: `eks-hostnetwork-optimization-brief.md` (gVisor and
  hostNetwork are mutually exclusive — see Section 14)
