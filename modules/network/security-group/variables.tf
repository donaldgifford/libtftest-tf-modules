#--------------------------------------------------------------
# Identity
#--------------------------------------------------------------

variable "name" {
  description = "Logical name for this security group. Becomes the name_prefix (\"<name>-\", so the physical name carries a provider-generated suffix), the friendly Name tag, the default description, and the <name> segment of this stack's ADR-0020 remote-state key — which makes it triple-coupled: producer identifier == live-repo folder == future consumer input. Renaming is a deliberate SG replacement, not a refactor."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,99}$", var.name))
    error_message = "name must be 1-100 characters of alphanumerics, underscore, period or hyphen, starting with an alphanumeric or underscore — the name_prefix adds a suffix, so this leaves room under the AWS 255-character group-name limit."
  }

  nullable = false
}

variable "description" {
  description = "Security group description. Defaults to a line composed from var.name. NOTE: description is create-time on AWS (ForceNew) — editing it REPLACES the security group. The module's name_prefix + create_before_destroy make that replacement survivable, but it still mints a new security group id, so any chart-side or cross-stack consumer of the id needs updating in the same change. AWS restricts this field to ASCII: a-z A-Z 0-9 spaces and ._-:/()#,@[]+=&;{}!$* — a typographic dash or quote pasted from a doc or a chat window fails at APPLY, not at plan."
  type        = string
  default     = null

  # CreateSecurityGroup's GroupDescription charset, enforced server-side
  # by AWS and by nothing else in the pipeline. This validation exists
  # because the module's OWN default violated it: it contained a U+2014
  # EM DASH, so every invocation that did not override description would
  # have failed at apply against real AWS — after the create call, with
  # partial state.
  #
  # Nothing caught it. The plan gate cannot (the constraint is
  # server-side) and LOCALSTACK DOES NOT ENFORCE AWS STRING-CHARSET
  # CONSTRAINTS, so the Community apply accepted it and the suite
  # actively pinned the broken value. See tests-localstack/FINDINGS.md.
  validation {
    condition     = var.description == null || can(regex("^[a-zA-Z0-9 ._:/()#,@\\[\\]+=&;{}!$*-]+$", var.description))
    error_message = "description must use only the characters AWS accepts for a security group description: a-z A-Z 0-9 spaces and ._-:/()#,@[]+=&;{}!$* — no typographic dashes or quotes. AWS rejects the rest at apply, not at plan."
  }
}

variable "tags" {
  description = "Tags applied to the security group and to every rule resource. The Name tag is set by the module from var.name and must not be supplied here."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.tags), "Name")
    error_message = "tags must not set Name — the module sets it from var.name so the friendly name and the name_prefix cannot drift apart."
  }

  nullable = false
}

#--------------------------------------------------------------
# The rules surface
#
# One aws_vpc_security_group_{ingress,egress}_rule resource per map
# entry, keyed by LOGICAL name. That keying is the point: plan diffs
# read as named intentions, and adding or removing one webhook source
# never churns a sibling rule's address.
#
# DEVIATION FROM DESIGN-0026, deliberate: the design's object spec
# writes `from_port = number` (required) while also requiring a
# ports-with-"-1" rejection. Those two cannot both hold — a required
# from_port means every rule carries a port, so an all-protocols rule
# would always be rejected and "-1" would be unrepresentable. Every
# "-1" rule in the fleet (eks/cluster, rds/cluster, rds/serverless)
# omits ports, and this module's own allow_all_egress default emits
# exactly that shape. So from_port is optional(number) and the
# coherence is enforced by validation instead: ports are REQUIRED for
# tcp/udp and REJECTED for "-1".
#--------------------------------------------------------------

variable "ingress_rules" {
  description = "Ingress allowlist, keyed by logical rule name (stable addresses). Each rule names exactly ONE source: cidr_ipv4 | cidr_ipv6 | prefix_list_id | referenced_security_group_id. prefix_list_id rules are LIVE references — edits to the list propagate without a Terraform apply, unlike the eks/cluster endpoint fence's plan-time expansion. description is required: every allowlist entry says why it exists, and AWS constrains its charset (ASCII only) server-side, so it is validated here. Ports depend on the protocol: tcp/udp require from_port and to_port collapses to it (the single-port rule); icmp/icmpv6 require BOTH, because there from_port is the ICMP TYPE and to_port is the CODE, not a range end — letting it collapse would silently set code = type; ip_protocol = \"-1\" and numeric protocols must omit both ports, since AWS ignores them there."
  type = map(object({
    description                  = string
    from_port                    = optional(number)
    to_port                      = optional(number)
    ip_protocol                  = optional(string, "tcp")
    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    prefix_list_id               = optional(string)
    referenced_security_group_id = optional(string)
  }))
  default = {}

  # Each guard is its own block so a rejection run can be verified
  # against the rule it names. Four-plus validations stack on this one
  # variable, and `expect_failures` proves only that the variable
  # errored — never which rule fired (the IMPL-0020 lesson).
  #
  # Every message names the offending keys. With a map of rules, "one of
  # your rules is wrong" is close to useless on a 30-entry allowlist.

  validation {
    condition = alltrue([
      for k, r in var.ingress_rules :
      length(compact([r.cidr_ipv4, r.cidr_ipv6, r.prefix_list_id, r.referenced_security_group_id])) == 1
    ])
    error_message = "Every ingress rule must name EXACTLY ONE source — cidr_ipv4, cidr_ipv6, prefix_list_id or referenced_security_group_id. Rules naming zero or several: ${join(", ", [for k, r in var.ingress_rules : k if length(compact([r.cidr_ipv4, r.cidr_ipv6, r.prefix_list_id, r.referenced_security_group_id])) != 1])}."
  }

  validation {
    condition     = alltrue([for k, r in var.ingress_rules : trimspace(r.description) != ""])
    error_message = "Every ingress rule needs a non-empty description — the allowlist is an audit surface, and a rule nobody can explain is a rule nobody can safely remove. Rules missing one: ${join(", ", [for k, r in var.ingress_rules : k if trimspace(r.description) == ""])}."
  }

  # Rule descriptions take a NARROWER charset than the group description
  # — no "&". Same server-side-only enforcement, same reason for the
  # rule: this field is explicitly the audit surface, so it is the one
  # most likely to be pasted in from a ticket or a chat window.
  validation {
    condition     = alltrue([for k, r in var.ingress_rules : can(regex("^[a-zA-Z0-9 ._:/()#,@\\[\\]+=;{}!$*-]+$", r.description))])
    error_message = "Ingress rule descriptions must use only the characters AWS accepts: a-z A-Z 0-9 spaces and ._-:/()#,@[]+=;{}!$* (note: no \"&\", unlike the group description). AWS rejects the rest at apply, not at plan. Offending rules: ${join(", ", [for k, r in var.ingress_rules : k if !can(regex("^[a-zA-Z0-9 ._:/()#,@\\[\\]+=;{}!$*-]+$", r.description))])}."
  }

  # PORT COHERENCE, three-way — AWS gives from_port/to_port three
  # different meanings depending on the protocol:
  #
  #   tcp / udp        ports. to_port null-collapses to from_port.
  #   icmp / icmpv6    from_port is the TYPE and to_port is the CODE.
  #                    Both are REQUIRED here, because the collapse
  #                    would otherwise silently produce code == type:
  #                    `{ from_port = 8, ip_protocol = "icmp" }` reads
  #                    as "allow ping" and plans as type 8 / code 8,
  #                    which matches nothing (echo requests are code 0).
  #                    The intended spelling is to_port = -1 (any code).
  #   anything else    ports are IGNORED by AWS, so a rule carrying them
  #                    reads as port-scoped and is not. Rejected.
  validation {
    condition = alltrue([
      for k, r in var.ingress_rules :
      contains(["tcp", "udp"], r.ip_protocol) ? r.from_port != null : (
        contains(["icmp", "icmpv6"], r.ip_protocol) ? r.from_port != null && r.to_port != null : r.from_port == null && r.to_port == null
      )
    ])
    error_message = "Port coherence. tcp/udp must set from_port. icmp/icmpv6 must set BOTH from_port (the ICMP type) and to_port (the CODE — use -1 for any code; omitting it would silently set code = type). Every other protocol, including \"-1\", must omit both ports because AWS ignores them there. Offending rules: ${join(", ", [for k, r in var.ingress_rules : k if contains(["tcp", "udp"], r.ip_protocol) ? r.from_port == null : (contains(["icmp", "icmpv6"], r.ip_protocol) ? r.from_port == null || r.to_port == null : r.from_port != null || r.to_port != null)])}."
  }

  validation {
    condition = alltrue([
      for k, r in var.ingress_rules :
      r.from_port == null || r.to_port == null || r.to_port >= r.from_port || contains(["icmp", "icmpv6"], r.ip_protocol)
    ])
    error_message = "to_port must be >= from_port (the pair is a range). This does not apply to icmp/icmpv6, where the two are a type and a code rather than a range. Offending rules: ${join(", ", [for k, r in var.ingress_rules : k if r.from_port != null && r.to_port != null && r.to_port < r.from_port && !contains(["icmp", "icmpv6"], r.ip_protocol)])}."
  }

  validation {
    condition = alltrue([
      for k, r in var.ingress_rules :
      contains(["tcp", "udp", "icmp", "icmpv6"], r.ip_protocol) || (can(tonumber(r.ip_protocol)) && tonumber(r.ip_protocol) >= -1 && tonumber(r.ip_protocol) <= 255)
    ])
    error_message = "ip_protocol must be tcp, udp, icmp, icmpv6, \"-1\" (all protocols), or an IANA protocol number 0-255. A typo like \"https\" would otherwise plan clean and fail at apply. Offending rules: ${join(", ", [for k, r in var.ingress_rules : k if !contains(["tcp", "udp", "icmp", "icmpv6"], r.ip_protocol) && !(can(tonumber(r.ip_protocol)) && tonumber(r.ip_protocol) >= -1 && tonumber(r.ip_protocol) <= 255)])}."
  }

  # THE WORLD-OPEN GUARD (DESIGN-0026 OQ 4a). This is the cross-variable
  # validation that sets the module's >= 1.9 floor — see versions.tf.
  #
  # Its boundary is deliberate and documented, not an oversight: it
  # inspects the LITERAL cidr fields only. A prefix_list_id whose list
  # contains 0.0.0.0/0 admits the world and this guard cannot see it,
  # BY DESIGN — the reference is live, so expanding the list at plan
  # would give false assurance (the list can be edited world-open a
  # minute after the apply, which is what "live" means). That is the
  # shape of IMPL-0020's HIGH fence finding, with the difference that
  # here resolution is impossible on purpose, so the boundary is
  # documented in the README instead of closed.
  #
  # referenced_security_group_id has no equivalent hole: an SG
  # reference admits that SG's members, never the world.
  #
  # THE GUARD TESTS THE PREFIX LENGTH, NOT THE SPELLING. An earlier
  # version compared strings (cidr_ipv4 != "0.0.0.0/0" && cidr_ipv6 !=
  # "::/0") and was evaded by IPv6, which has many legal spellings of
  # the same prefix: "0::/0" and the fully expanded
  # "0000:0000:0000:0000:0000:0000:0000:0000/0" both passed the guard,
  # both are accepted by the provider's CIDR validator, and AWS creates
  # the rule. (The v4 side happened to be safe only because the
  # provider's network-address validator leaves "0.0.0.0/0" as the sole
  # accepted v4 /0 spelling — luck, not design.)
  #
  # endswith(c, "/0") is exact: no other prefix length ends in the
  # literal "/0" — "10.0.0.0/10" ends in "10", not "/0". The "unset/32"
  # fallback is what a rule with no CIDR source at all (prefix list,
  # referenced SG) collapses to, and it is deliberately not world-open.
  #
  # This is the IMPL-0020 rule applied inward: validate the RESOLVED
  # value, not the raw input. Where resolution is impossible — a live
  # prefix list — the boundary is documented instead (above). Here
  # resolution is trivial, so there is no excuse for testing spelling.
  validation {
    condition = var.allow_world_open_ingress || alltrue([
      for k, r in var.ingress_rules :
      !endswith(coalesce(r.cidr_ipv4, r.cidr_ipv6, "unset/32"), "/0")
    ])
    error_message = "World-open ingress is fail-closed: set allow_world_open_ingress = true to permit a /0 prefix (0.0.0.0/0, ::/0, and every other spelling of them). A deliberately public frontend is one explicit, reviewable line; the guard exists for the pasted-wide-open accident. Rules opening to the world: ${join(", ", [for k, r in var.ingress_rules : k if endswith(coalesce(r.cidr_ipv4, r.cidr_ipv6, "unset/32"), "/0")])}."
  }

  nullable = false
}

variable "allow_world_open_ingress" {
  description = "Permit ingress rules whose literal source CIDR is a /0 — 0.0.0.0/0, ::/0, and every other legal spelling of them, since the guard tests the /0 suffix rather than comparing strings (IPv6 spells the world several ways). Default false, fail-closed. A deliberately public frontend sets this to true, which is one explicit line a reviewer can see. SCOPE, stated honestly — this is a guard against the accident, not a proof of non-exposure. It inspects literal CIDR fields only, so it does NOT look inside a prefix list (a prefix_list_id whose list contains 0.0.0.0/0 admits the world with this left false — the reference is live, and plan-time expansion would be false assurance; list contents are the list owner's audit surface), and it does not catch a /1 split: 0.0.0.0/1 plus 128.0.0.0/1 is the whole internet in two rules that are not /0s."
  type        = bool
  default     = false

  nullable = false
}

variable "egress_rules" {
  description = "Egress rules, keyed by logical rule name. Same object shape as ingress_rules. Setting this REQUIRES allow_all_egress = false: the two together are rejected at plan, because the all-egress rule is wider than anything written here and shows up in the plan only as an unchanged resource. The logical key \"all-egress\" is reserved (the module's own default rule already claims that Name tag)."
  type = map(object({
    description                  = string
    from_port                    = optional(number)
    to_port                      = optional(number)
    ip_protocol                  = optional(string, "tcp")
    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    prefix_list_id               = optional(string)
    referenced_security_group_id = optional(string)
  }))
  default = {}

  # The same six API-shape guards as ingress (exactly-one-source,
  # description non-empty, description charset, port coherence,
  # inverted range, protocol enum), plus two that only egress needs:
  # the reserved `all-egress` key and the allow_all_egress coherence
  # guard. Deliberately NO
  # world-open guard here (IMPL-0023 OQ 2a — NOT DESIGN-0026's OQ 2,
  # which is the naming and replacement posture): world egress IS the
  # module's default posture, so rejecting 0.0.0.0/0 in the typed map
  # would reject a shape allow_all_egress already grants by default. A
  # restricted-egress caller writing 0.0.0.0/0 has visibly re-created
  # the default they turned off, in a reviewed plan.

  validation {
    condition = alltrue([
      for k, r in var.egress_rules :
      length(compact([r.cidr_ipv4, r.cidr_ipv6, r.prefix_list_id, r.referenced_security_group_id])) == 1
    ])
    error_message = "Every egress rule must name EXACTLY ONE destination — cidr_ipv4, cidr_ipv6, prefix_list_id or referenced_security_group_id. Rules naming zero or several: ${join(", ", [for k, r in var.egress_rules : k if length(compact([r.cidr_ipv4, r.cidr_ipv6, r.prefix_list_id, r.referenced_security_group_id])) != 1])}."
  }

  validation {
    condition     = alltrue([for k, r in var.egress_rules : trimspace(r.description) != ""])
    error_message = "Every egress rule needs a non-empty description. Rules missing one: ${join(", ", [for k, r in var.egress_rules : k if trimspace(r.description) == ""])}."
  }

  validation {
    condition     = alltrue([for k, r in var.egress_rules : can(regex("^[a-zA-Z0-9 ._:/()#,@\\[\\]+=;{}!$*-]+$", r.description))])
    error_message = "Egress rule descriptions must use only the characters AWS accepts: a-z A-Z 0-9 spaces and ._-:/()#,@[]+=;{}!$*. Offending rules: ${join(", ", [for k, r in var.egress_rules : k if !can(regex("^[a-zA-Z0-9 ._:/()#,@\\[\\]+=;{}!$*-]+$", r.description))])}."
  }

  validation {
    condition = alltrue([
      for k, r in var.egress_rules :
      contains(["tcp", "udp"], r.ip_protocol) ? r.from_port != null : (
        contains(["icmp", "icmpv6"], r.ip_protocol) ? r.from_port != null && r.to_port != null : r.from_port == null && r.to_port == null
      )
    ])
    error_message = "Port coherence. tcp/udp must set from_port. icmp/icmpv6 must set BOTH from_port (type) and to_port (code). Every other protocol, including \"-1\", must omit both. Offending rules: ${join(", ", [for k, r in var.egress_rules : k if contains(["tcp", "udp"], r.ip_protocol) ? r.from_port == null : (contains(["icmp", "icmpv6"], r.ip_protocol) ? r.from_port == null || r.to_port == null : r.from_port != null || r.to_port != null)])}."
  }

  validation {
    condition = alltrue([
      for k, r in var.egress_rules :
      r.from_port == null || r.to_port == null || r.to_port >= r.from_port || contains(["icmp", "icmpv6"], r.ip_protocol)
    ])
    error_message = "to_port must be >= from_port. Offending rules: ${join(", ", [for k, r in var.egress_rules : k if r.from_port != null && r.to_port != null && r.to_port < r.from_port && !contains(["icmp", "icmpv6"], r.ip_protocol)])}."
  }

  validation {
    condition = alltrue([
      for k, r in var.egress_rules :
      contains(["tcp", "udp", "icmp", "icmpv6"], r.ip_protocol) || (can(tonumber(r.ip_protocol)) && tonumber(r.ip_protocol) >= -1 && tonumber(r.ip_protocol) <= 255)
    ])
    error_message = "ip_protocol must be tcp, udp, icmp, icmpv6, \"-1\", or an IANA protocol number 0-255. Offending rules: ${join(", ", [for k, r in var.egress_rules : k if !contains(["tcp", "udp", "icmp", "icmpv6"], r.ip_protocol) && !(can(tonumber(r.ip_protocol)) && tonumber(r.ip_protocol) >= -1 && tonumber(r.ip_protocol) <= 255)])}."
  }

  # "all-egress" is RESERVED. The module's own all-egress rule tags
  # itself Name = "<name>-all-egress", so a caller rule by that key
  # produces two rules with an identical Name tag — defeating the
  # console-lookup purpose the per-rule Name tag exists for. The
  # outputs deliberately avoided exactly this collision by giving
  # all_egress_rule_id its own output instead of a reserved map key;
  # the tag had the same collision and did not.
  validation {
    condition     = !contains(keys(var.egress_rules), "all-egress")
    error_message = "\"all-egress\" is a reserved egress rule key — the module's own allow_all_egress rule already tags itself Name = \"<name>-all-egress\", and a caller rule by that key would produce two rules with the same Name tag."
  }

  # THE COHERENCE GUARD (cross-variable, hence the >= 1.9 floor).
  #
  # A caller who writes egress_rules is by definition trying to RESTRICT
  # egress — and nothing in that edit surfaces allow_all_egress, which
  # is still true by default and still wider than anything they wrote.
  # Their intent silently resolves to the permissive default.
  #
  # The plan does show the all-egress rule, but it shows it as
  # UNCHANGED, and unchanged resources are the ones reviewers skim —
  # the exact mechanism behind IMPL-0022's silent re-grant.
  #
  # This is the IMPL-0021 object_lock shape: a partially-specified
  # intent that quietly resolves to the permissive default fails at
  # plan instead. DESIGN-0027 Part C does not apply — that was about
  # Terragrunt injecting a uniform GLOBAL into every module, whereas
  # both of these are module-local inputs a caller writes deliberately.
  validation {
    condition     = !(var.allow_all_egress && length(var.egress_rules) > 0)
    error_message = "allow_all_egress is true AND egress_rules is non-empty. The all-egress rule is wider than anything in that map, so the typed rules add nothing — if you meant to restrict egress, set allow_all_egress = false; if you meant wide-open egress, drop egress_rules."
  }

  nullable = false
}

variable "allow_all_egress" {
  description = "Emit one explicit all-protocols egress rule to 0.0.0.0/0 (default true). This is NOT redundant with AWS's default: the provider REVOKES the default allow-all egress when it creates a security group, so a module with no egress surface would ship SGs that silently fail ALB health checks and target traffic. The rule is emitted as a real resource so the posture is visible in every plan rather than implied. Set false to make egress_rules the whole posture — required, not optional, whenever egress_rules is non-empty."
  type        = bool
  default     = true

  nullable = false
}

#--------------------------------------------------------------
# VPC remote-state pointer
#--------------------------------------------------------------

variable "vpc_name" {
  description = "VPC name used to compose the VPC remote-state key (<account_name>/<region>/vpc/<vpc_name>/terraform.tfstate). Must match the VPC stack's identifier."
  type        = string
  nullable    = false
}

#--------------------------------------------------------------
# Terragrunt-injected multi-account globals (IMPL-0015)
#
# In production Terragrunt injects these into every module via includes,
# regardless of whether the module uses them. At test time the shared
# test/fixtures/terragrunt-inputs.tfvars var-file supplies them.
#--------------------------------------------------------------

variable "region" {
  description = "AWS region the security group is created in."
  type        = string
  nullable    = false
}

variable "account_name" {
  description = "Terragrunt account name — the <account_name> prefix of the account-scoped VPC remote-state key this module reads."
  type        = string
  nullable    = false
}

variable "account_id" {
  description = "12-digit AWS account ID that owns the remote-state bucket. Composed into the assume_role role_arn (arn:aws:iam::<account_id>:role/<deploy_role_name>) for the cross-account state read."
  type        = string
  nullable    = false
}

variable "remote_state_bucket" {
  description = "S3 bucket holding the VPC stack's terraform state, read at <account_name>/<region>/vpc/<vpc_name>/terraform.tfstate for vpc_id."
  type        = string
  nullable    = false
}

variable "remote_state_bucket_region" {
  description = "Region of the remote-state S3 bucket — distinct from var.region (the deployment region) in production Terragrunt."
  type        = string
  nullable    = false
}

variable "deploy_role_name" {
  description = "Name of the IAM role Terraform assumes to read the remote-state bucket cross-account. Composed into the assume_role role_arn with account_id."
  type        = string
  nullable    = false
}
