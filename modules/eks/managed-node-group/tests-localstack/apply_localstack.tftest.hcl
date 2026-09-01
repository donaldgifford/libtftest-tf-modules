# Apply against LocalStack — the gap-discovery mode per RFC-0001.
#
# This file exercises `command = apply` against LocalStack Pro to
# surface what LocalStack actually serves for the managed-node-group's
# AWS API surface: IAM role + instance profile, EC2 launch template
# (incl. KMS-encrypted EBS), EKS node group registration.
#
# Required env vars (the harness wiring terraform test needs to reach
# LocalStack — same shape libtftest's helpers_test.go wires in Go):
#   AWS_ENDPOINT_URL=http://localhost:4566
#   AWS_ACCESS_KEY_ID=test
#   AWS_SECRET_ACCESS_KEY=test
#   AWS_REGION=us-east-1
#
# The `just tf test-localstack` recipe wires these for you.
#
# Findings are captured in FINDINGS.md as the LocalStack apply hits
# rough edges. Any 501 / NotImplemented becomes a sneakystack ticket
# per RFC-0001 §`terraform test` as the gap-discovery tool.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    cloudwatchlogs = "http://localhost:4566"
    ec2            = "http://localhost:4566"
    eks            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    kms            = "http://localhost:4566"
    s3             = "http://s3.localhost.localstack.cloud:4566"
    sts            = "http://localhost:4566"
  }
}

# Declarations for the Terragrunt globals this file references via var.* in the
# setup run. Values come from the shared var-file (test/fixtures/
# terragrunt-inputs.tfvars) via the `just tf test*` recipes — no default here.
variable "region" {
  type = string
}

variable "remote_state_bucket" {
  type = string
}

variable "account_name" {
  type = string
}

# region + remote_state_bucket now come from the shared var-file
# (test/fixtures/terragrunt-inputs.tfvars) via the `just tf test*` recipes —
# one shared test bucket across the fleet (IMPL-0015 Q2).
variables {
  cluster_name   = "tftest-mng-cluster"
  vpc_name       = "tftest-mng-vpc"
  nodegroup_name = "tftest-mng"
  tags = {
    Environment = "test"
    ClusterName = "tftest-mng-cluster"
  }
}

# Setup: VPC + subnets + KMS + cluster IAM + real aws_eks_cluster +
# node SG + S3 bucket holding stub VPC and EKS state files. The
# fixture's apply produces the prerequisites the node-group module's
# remote-state reads need.
run "setup" {
  command = apply

  variables {
    remote_state_bucket = var.remote_state_bucket
    vpc_name            = var.vpc_name
    cluster_name        = var.cluster_name
    region              = var.region
    account_name        = var.account_name
  }

  module {
    source = "./tests-localstack/fixtures/setup"
  }
}

# Default-config apply against LocalStack. Exercises IAM role +
# instance profile + 2 managed-policy attachments, EC2 launch template
# with KMS-encrypted EBS root, and aws_eks_node_group registration.
run "default_apply" {
  command = apply

  assert {
    condition     = length(aws_iam_role.node.arn) > 0
    error_message = "LocalStack IAM must populate node role ARN"
  }
  assert {
    condition     = length(aws_iam_instance_profile.node.arn) > 0
    error_message = "LocalStack IAM must populate instance profile ARN"
  }
  assert {
    condition     = length(aws_launch_template.node.id) > 0
    error_message = "LocalStack EC2 must populate launch template ID"
  }
  assert {
    condition     = aws_launch_template.node.latest_version >= 1
    error_message = "LocalStack EC2 must populate launch template latest_version"
  }
  assert {
    condition     = length(aws_eks_node_group.this.arn) > 0
    error_message = "LocalStack EKS must populate node group ARN"
  }
  assert {
    condition     = aws_eks_node_group.this.ami_type == "AL2023_ARM_64_STANDARD"
    error_message = "LocalStack EKS must accept the AL2023_ARM_64_STANDARD ami_type"
  }
  assert {
    condition     = aws_eks_node_group.this.capacity_type == "ON_DEMAND"
    error_message = "LocalStack EKS must reflect ON_DEMAND capacity type"
  }

  # The default class applies untainted (IMPL-0020 Phase 5). This is
  # the applied half of Gate 1: a hub built on the default must have
  # somewhere for the tolerate-nothing platform baseline to land.
  assert {
    condition     = aws_eks_node_group.this.labels["workload-class"] == "core"
    error_message = "the default class label must round-trip through the EKS API as core"
  }
  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint : t if t.key == "workload-class"
    ]) == 0
    error_message = "the default (core) node group must apply with no workload-class taint"
  }
}

# The secure class applied end-to-end: label, taint, and gVisor all on.
# Keeps the pre-DESIGN-0024 posture proven at apply, not just at plan.
run "secure_class_apply" {
  command = apply

  variables {
    nodegroup_name = "tftest-ng-secure"
    workload_class = "secure"
  }

  assert {
    condition     = aws_eks_node_group.this.labels["workload-class"] == "secure" && aws_eks_node_group.this.labels["runtime"] == "gvisor"
    error_message = "the secure class must apply with both the class and runtime labels"
  }

  assert {
    condition = length([
      for t in aws_eks_node_group.this.taint :
      t if t.key == "workload-class" && t.value == "secure" && t.effect == "NO_SCHEDULE"
    ]) == 1
    error_message = "the secure class taint must round-trip through the EKS API"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "gvisor/releases")
    error_message = "the applied secure launch template must carry the gVisor install part"
  }
}

# The independent-gating regression, applied.
#
# The ECR pull-through mirror config lives INSIDE the same shellscript
# MIME part as the gVisor install, so gating that whole part on gVisor
# (as DESIGN-0024 literally reads) would silently drop the mirror on
# every non-gVisor class — nodes that boot fine and then pull from
# upstream, which no assertion about gVisor would ever catch. The plan
# suite pins the rendered text; this run proves EC2 actually accepts the
# resulting multipart user data on a class with gVisor OFF, which is the
# combination the bug would have broken.
run "mirror_without_gvisor_apply" {
  command = apply

  variables {
    nodegroup_name = "tftest-ng-mirror"
    workload_class = "core"
    containerd_pull_through_mirror = {
      enabled          = true
      cache_url_prefix = "000000000000.dkr.ecr.us-east-1.amazonaws.com"
      upstreams = [
        { host = "docker.io", prefix = "docker-hub" },
        { host = "quay.io", prefix = "quay" },
      ]
    }
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node.user_data), "000000000000.dkr.ecr.us-east-1.amazonaws.com")
    error_message = "the mirror config must reach the applied launch template on a non-gVisor class"
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.node.user_data), "gvisor/releases")
    error_message = "core must not carry the gVisor install part — if this passes with gVisor present, the two fragments are no longer independently gated"
  }

  assert {
    condition     = !contains(keys(aws_eks_node_group.this.labels), "runtime")
    error_message = "a node with no runsc installed must not advertise a runtime label"
  }
}
