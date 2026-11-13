#--------------------------------------------------------------
# Identity
#--------------------------------------------------------------

variable "name" {
  description = "Key name: the alias becomes alias/<name>. Use a placeholder-style class name (for example example-mirror-signing), one instance per signing class. Renaming replaces the alias (not the key)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9/_-]{1,250}$", var.name))
    error_message = "name must be 1-250 characters of alphanumerics, '/', '_' or '-' (the KMS alias charset, without the alias/ prefix)."
  }

  validation {
    condition     = !startswith(lower(var.name), "aws/")
    error_message = "name must not start with aws/, which KMS reserves for AWS managed keys."
  }

  nullable = false
}

variable "key_spec" {
  description = "Asymmetric key spec. ECC_NIST_P256 (default) is cosign's default; RSA_4096 is for verifiers that cannot handle ECDSA (DESIGN-0031 OQ 4a). Changing it REPLACES the key, and every existing signature then needs the old public key to verify."
  type        = string
  default     = "ECC_NIST_P256"

  validation {
    condition     = contains(["ECC_NIST_P256", "RSA_4096"], var.key_spec)
    error_message = "key_spec must be ECC_NIST_P256 or RSA_4096."
  }

  nullable = false
}

#--------------------------------------------------------------
# Key policy principals (DESIGN-0031 OQ 3a)
#
# Each list carries iam/role's five-rule set, one rule per block, so a
# rejection run can be verified against the rule it names.
#--------------------------------------------------------------

variable "admin_principal_arns" {
  description = "Principals that administer the key (everything except kms:Sign). Must include the role that applies this module: the key policy delegates nothing to account IAM, so a deploy role missing from this list is locked out on the next apply (enforced by a precondition). Admins deliberately cannot sign."
  type        = list(string)

  validation {
    condition     = length(var.admin_principal_arns) > 0
    error_message = "admin_principal_arns must name at least one principal."
  }

  validation {
    condition     = alltrue([for a in var.admin_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/.+$", a))])
    error_message = "Every admin_principal_arns entry must be an exact IAM role or user ARN: arn:aws:iam::<12-digit-account>:role/<name> (or :user/<name>). Account roots are rejected: the key policy deliberately delegates nothing to account IAM."
  }

  validation {
    condition     = alltrue([for a in var.admin_principal_arns : !can(regex("[*?]", a))])
    error_message = "admin_principal_arns must not contain wildcard characters (* or ?): the key policy names principals exactly."
  }

  validation {
    condition     = alltrue([for a in var.admin_principal_arns : a == trimspace(a)])
    error_message = "admin_principal_arns entries must carry no leading or trailing whitespace: a padded ARN matches no principal."
  }

  validation {
    condition     = length(var.admin_principal_arns) == length(distinct([for a in var.admin_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]))
    error_message = "admin_principal_arns must not name the same principal twice, compared as normalized <account>/<name> (lowercased, path-stripped)."
  }

  nullable = false
}

variable "signer_principal_arns" {
  description = "Principals allowed kms:Sign (plus GetPublicKey and DescribeKey). Only these can vouch with the key; account-wide IAM grants cannot add signers. A cross-account signer also needs the identity grant in signer_policy_json."
  type        = list(string)

  validation {
    condition     = length(var.signer_principal_arns) > 0
    error_message = "signer_principal_arns must name at least one principal."
  }

  validation {
    condition     = alltrue([for a in var.signer_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/.+$", a))])
    error_message = "Every signer_principal_arns entry must be an exact IAM role or user ARN: arn:aws:iam::<12-digit-account>:role/<name> (or :user/<name>). Account roots are rejected: the key policy deliberately delegates nothing to account IAM."
  }

  validation {
    condition     = alltrue([for a in var.signer_principal_arns : !can(regex("[*?]", a))])
    error_message = "signer_principal_arns must not contain wildcard characters (* or ?): the key policy names principals exactly."
  }

  validation {
    condition     = alltrue([for a in var.signer_principal_arns : a == trimspace(a)])
    error_message = "signer_principal_arns entries must carry no leading or trailing whitespace: a padded ARN matches no principal."
  }

  validation {
    condition     = length(var.signer_principal_arns) == length(distinct([for a in var.signer_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]))
    error_message = "signer_principal_arns must not name the same principal twice, compared as normalized <account>/<name> (lowercased, path-stripped)."
  }

  # Cross-variable (>= 1.9): administering a key must not mean being
  # able to vouch with it.
  validation {
    condition = length(setintersection(
      toset([for a in var.signer_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]),
      toset([for a in var.admin_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]),
    )) == 0
    error_message = "signer_principal_arns and admin_principal_arns must be disjoint: an admin who can also sign can vouch for any image."
  }

  nullable = false
}

variable "verifier_principal_arns" {
  description = "Optional principals allowed kms:Verify (plus GetPublicKey and DescribeKey), possibly in other accounts. Most verifiers should use the public_key_pem output instead and need no KMS access at all."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.verifier_principal_arns : can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/.+$", a))])
    error_message = "Every verifier_principal_arns entry must be an exact IAM role or user ARN: arn:aws:iam::<12-digit-account>:role/<name> (or :user/<name>). Account roots are rejected: the key policy deliberately delegates nothing to account IAM."
  }

  validation {
    condition     = alltrue([for a in var.verifier_principal_arns : !can(regex("[*?]", a))])
    error_message = "verifier_principal_arns must not contain wildcard characters (* or ?): the key policy names principals exactly."
  }

  validation {
    condition     = alltrue([for a in var.verifier_principal_arns : a == trimspace(a)])
    error_message = "verifier_principal_arns entries must carry no leading or trailing whitespace: a padded ARN matches no principal."
  }

  validation {
    condition     = length(var.verifier_principal_arns) == length(distinct([for a in var.verifier_principal_arns : lower(format("%s/%s", element(split(":", a), 4), element(reverse(split("/", a)), 0)))]))
    error_message = "verifier_principal_arns must not name the same principal twice, compared as normalized <account>/<name> (lowercased, path-stripped)."
  }

  nullable = false
}
