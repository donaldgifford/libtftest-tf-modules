#--------------------------------------------------------------
# Mode A — Pod-Identity-trusting IAM role + policy attachments
#--------------------------------------------------------------
#
# All resources here are gated on var.create_role. Phase 3 lands
# the role + trust policy; Phase 4 lands managed/customer/inline
# policy attachments.
