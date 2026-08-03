#--------------------------------------------------------------
# Provider Versions
#
# Unlike the family's other purpose modules this one owns a direct aws
# resource (the singleton aws_s3_bucket_notification), so the aws
# requirement is genuinely used — no tflint-ignore needed. random
# stays undeclared: it needs no configuration, so the core's ~> 3.7
# constraint aggregates through init on its own.
#--------------------------------------------------------------

terraform {
  required_version = ">= 1.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}
