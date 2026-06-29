#--------------------------------------------------------------
# Proxy IAM role + secret-access policy
#
# RDS Proxy assumes this role to read the target's AWS-managed master
# secret and decrypt it. Least privilege: GetSecretValue is scoped to
# exactly the target secret ARN (from remote state); kms:Decrypt is
# scoped to the secret's CMK when known (the serverless module always
# sets master_user_secret_kms_key_id, so secret_kms_key_arn is
# non-null and there is no wildcard). The null fallback (operator
# using the account default aws/secretsmanager key, whose key ARN is
# not knowable at plan) scopes to "*" but is fenced by the
# kms:ViaService condition so the role can only decrypt via Secrets
# Manager in this region.
#--------------------------------------------------------------

data "aws_iam_policy_document" "proxy_trust" {
  statement {
    sid     = "RDSProxyAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "proxy_secret_access" {
  statement {
    sid       = "GetMasterSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [local.master_user_secret_arn]
  }

  statement {
    sid       = "DecryptMasterSecretCMK"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = local.secret_kms_key_arn != null ? [local.secret_kms_key_arn] : ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy" {
  name               = "${var.name}-rds-proxy"
  assume_role_policy = data.aws_iam_policy_document.proxy_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "proxy_secret_access" {
  name   = "${var.name}-secret-access"
  role   = aws_iam_role.proxy.id
  policy = data.aws_iam_policy_document.proxy_secret_access.json
}
