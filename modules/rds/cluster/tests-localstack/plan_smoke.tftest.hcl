# Community-safe plan-only smoke (IMPL-0012 Phase 10 / Q5-b).
#
# Aurora provisioned clusters reliably need LocalStack **Pro**'s native
# RDS provider for a full apply, so — following the modules/rds/proxy
# two-tier layout — the DEFAULT tests-localstack suite is plan-only: it
# confirms the cluster module plans against the LocalStack provider
# endpoints with the VPC remote state stubbed via override_data, WITHOUT
# applying the Pro-backed RDS resources. It therefore passes on
# LocalStack Community — and even with no LocalStack at all, since a plan
# with overridden data makes no API calls.
#
# The full apply lives in ../tests-localstack-pro/apply_pro.tftest.hcl,
# gated behind `just tf test-localstack-pro rds/cluster` (off by default).
#
# The `just tf test-localstack rds/cluster` recipe wires
# AWS_ENDPOINT_URL/key/secret/region automatically.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2            = "http://localhost:4566"
    iam            = "http://localhost:4566"
    kms            = "http://localhost:4566"
    rds            = "http://localhost:4566"
    s3             = "http://s3.localhost.localstack.cloud:4566"
    secretsmanager = "http://localhost:4566"
    sts            = "http://localhost:4566"
  }
}

variables {
  region                    = "us-east-1"
  remote_state_bucket       = "tftest-rds-cluster-state"
  vpc_name                  = "tftest-rds-cluster-vpc"
  identifier_prefix         = "tftest-rds"
  engine                    = "aurora-postgresql"
  instance_class            = "db.r6g.large"
  final_snapshot_identifier = "tftest-rds-final"
  kms_key_arn               = "arn:aws:kms:us-east-1:000000000000:key/byo-1234"
}

override_data {
  target = data.terraform_remote_state.vpc
  values = {
    outputs = {
      vpc_id                 = "vpc-0123456789abcdef0"
      private_subnet_ids     = ["subnet-aaa", "subnet-bbb", "subnet-ccc"]
      private_eks_subnet_ids = ["subnet-eks-aaa", "subnet-eks-bbb", "subnet-eks-ccc"]
      public_subnet_ids      = ["subnet-pub-aaa", "subnet-pub-bbb", "subnet-pub-ccc"]
      vpc_cidr_block         = "10.0.0.0/16"
      availability_zones     = ["us-east-1a", "us-east-1b", "us-east-1c"]
      nat_gateway_ids        = ["nat-0123456789abcdef0"]
      route_table_ids        = ["rtb-public0", "rtb-private0"]
      internet_gateway_id    = "igw-0123456789abcdef0"
    }
  }
}

run "plan_smoke" {
  command = plan

  assert {
    condition     = aws_rds_cluster.this.engine_mode == "provisioned"
    error_message = "cluster must plan engine_mode = provisioned against the LocalStack provider"
  }

  assert {
    condition     = length(aws_rds_cluster.this.serverlessv2_scaling_configuration) == 0
    error_message = "a provisioned cluster must NOT plan a serverlessv2_scaling_configuration block"
  }

  assert {
    condition     = aws_rds_cluster_instance.writer.instance_class == "db.r6g.large"
    error_message = "writer must plan a real instance_class (var.instance_class), never db.serverless"
  }
}
