#--------------------------------------------------------------
# Bedrock application inference profiles (AIPs)
#
# One AIP per var.models entry. Provider-agnostic: the resource copies
# from the backing foundation-model (or system-defined inference
# profile) ARN regardless of vendor, so the same block serves Anthropic,
# Amazon, Meta, Mistral, Cohere, AI21, Stability, and OpenAI models.
#
# Each AIP carries the cost-allocation tag pair (local.cost_tag_map) so
# Bedrock usage attributes to the right team in Cost Explorer — the
# whole point of minting a per-team AIP rather than invoking the FM
# directly (DESIGN-0009 §1, Q5). The AIP ARNs feed the IAM policy scope
# via local.aip_arns (read at the use site in iam.tf).
#--------------------------------------------------------------

resource "aws_bedrock_inference_profile" "this" {
  for_each = var.models

  name = each.key
  tags = merge(var.tags, local.cost_tag_map)

  model_source {
    copy_from = each.value.model_id
  }
}
