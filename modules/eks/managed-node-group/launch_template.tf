#--------------------------------------------------------------
# Launch template — IMDSv2 hardening + KMS-encrypted EBS
#--------------------------------------------------------------
#
# IMDS posture per ADR-0007: tokens required (IMDSv2),
# hop-limit 2 (needed for the EKS Pod Identity Agent's intra-pod
# fetch path), instance metadata tags enabled.
#
# EBS root volume: gp3, encrypted with the cluster module's KMS key
# read from remote state at the use site (ADR-0001).
#
# image_id is intentionally omitted — EKS managed node group selects
# the right AL2023 AMI based on aws_eks_node_group.ami_type per
# ADR-0008.
#
# user_data is a base64 placeholder at this phase; Phase 4 swaps it
# for the rendered multipart MIME script.

resource "aws_launch_template" "node" {
  name_prefix            = "${var.nodegroup_name}-"
  description            = "Launch template for ${var.nodegroup_name} (${var.workload_class} workload class)"
  update_default_version = true
  vpc_security_group_ids = [data.terraform_remote_state.eks.outputs.node_security_group_id]
  # AL2023 nodeadm + gVisor install + containerd drop-in multipart MIME
  # body, rendered by templatefile() in user_data.tf at the use site.
  user_data = base64encode(local.user_data_body)
  # The template's own tags mirror the provider default set explicitly,
  # even though default_tags would fill tags_all anyway. Through v0.26.0
  # this was `tags = var.tags`. Dropping it would change `tags` (X -> {})
  # on upgrade, and the provider's CustomizeDiff marks latest_version
  # known-after-apply on ANY tags change, so the node group would plan
  # `launch_template.version = N -> (known after apply)`. Mirroring keeps
  # `tags` unchanged when the new default_tags equal the old var.tags
  # (DESIGN-0029 rollout step 3), so the upgrade plans zero-diff here
  # (IMPL-0026 Phase 4).
  tags = data.aws_default_tags.this.tags

  iam_instance_profile {
    arn = aws_iam_instance_profile.node.arn
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.disk_size_gib
      encrypted             = true
      kms_key_id            = data.terraform_remote_state.eks.outputs.kms_key_arn
      delete_on_termination = true
    }
  }

  # default_tags do not reach tag_specifications, so the provider's set is
  # merged in explicitly. Name merges LAST so the module-set value wins.
  # Keep the rendered map byte-identical across upgrades: the node group
  # pins version = latest_version, so any change here mints a new
  # launch-template version and rolls every node (DESIGN-0029).
  tag_specifications {
    resource_type = "instance"
    tags          = merge(data.aws_default_tags.this.tags, { Name = var.nodegroup_name })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(data.aws_default_tags.this.tags, { Name = "${var.nodegroup_name}-root" })
  }

  lifecycle {
    create_before_destroy = true
  }
}
