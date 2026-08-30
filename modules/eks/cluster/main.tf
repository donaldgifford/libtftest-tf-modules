#--------------------------------------------------------------
# EKS Cluster
#--------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Managed log group. EKS will create one implicitly with no retention if
# the group does not pre-exist; managing it here pins retention and keeps
# the group under Terraform's lifecycle.
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.cluster_log_retention_in_days
  tags              = var.tags
}

resource "aws_eks_cluster" "this" {
  name                      = var.name
  version                   = var.eks_version
  role_arn                  = aws_iam_role.cluster.arn
  enabled_cluster_log_types = var.enabled_cluster_log_types
  tags                      = var.tags

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"

    # Explicit per DESIGN-0024 OQ 4 — this was the provider default
    # applying silently (INV-0011 F7), so writing it changes nothing
    # but makes the posture reviewable. NOTE the operational contract
    # in the README: the entry binds to whatever principal CREATES the
    # cluster, so cluster applies must run through the stable
    # automation path, never an ad-hoc SSO session whose
    # AWSReservedSSO_* suffix rotates.
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = data.terraform_remote_state.vpc.outputs.private_subnet_ids
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = local.public_access_cidrs
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = local.kms_key_arn
    }
  }

  lifecycle {
    # A cluster with neither endpoint is unreachable. The EKS API
    # permits the combination; the module does not.
    precondition {
      condition     = var.endpoint_private_access || var.endpoint_public_access
      error_message = "At least one API endpoint must be enabled: set endpoint_private_access and/or endpoint_public_access to true (a cluster with neither is unreachable)."
    }

    # A fence on a disabled public endpoint is a misconfiguration, not
    # a silent no-op — the operator believes they restricted access
    # that is in fact simply off (or, worse, expects the fence to
    # start applying if the endpoint is later enabled).
    precondition {
      condition     = var.endpoint_public_access || (length(var.endpoint_public_access_cidrs) == 0 && length(var.endpoint_public_access_prefix_list_ids) == 0)
      error_message = "endpoint_public_access_cidrs / endpoint_public_access_prefix_list_ids are set while endpoint_public_access is false. Either enable the public endpoint or drop the fence inputs (a private-only cluster needs neither)."
    }

    # EKS caps the public-endpoint allowlist at 40 CIDRs. The union is
    # plan-known, so this preempts an apply-time API rejection whose
    # message does not name the prefix-list expansion as the cause.
    precondition {
      condition     = length(local.public_access_cidrs) <= 40
      error_message = "The public-endpoint fence resolves to ${length(local.public_access_cidrs)} CIDRs, over the EKS limit of 40. Trim endpoint_public_access_cidrs or endpoint_public_access_prefix_list_ids — an expanded managed prefix list is the usual culprit."
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.cluster,
    aws_iam_role_policy_attachment.cluster,
  ]
}
