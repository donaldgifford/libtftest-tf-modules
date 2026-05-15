#--------------------------------------------------------------
# Provider Versions
#--------------------------------------------------------------

terraform {
  required_version = ">= 1.1"

  required_providers {
    # tflint-ignore: terraform_unused_required_providers  # consumed when resources land in Phase 2+
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.2"
    }
  }
}
