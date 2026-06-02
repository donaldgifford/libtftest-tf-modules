#--------------------------------------------------------------
# Module outputs (consumer contract)
#
# Stable surface; renaming or removing an output breaks downstream
# remote-state consumers — notably the future developer-onboarding
# stack that reads aip_arns to populate Claude Code's settings.json
# (ANTHROPIC_MODEL / ANTHROPIC_SMALL_FAST_MODEL) per DESIGN-0009.
#
# Deliberately NO credential output. The bearer token (the IAM
# service-specific credential's one-time secret) is never produced by
# Terraform — it is minted out-of-band by the bedrock-keyctl Go tool
# and written to a secret sink. There is no bedrock_api_key / secret /
# credential output here, by design (DESIGN-0009 §1).
#
# Outputs land in Phase 8.
#--------------------------------------------------------------
