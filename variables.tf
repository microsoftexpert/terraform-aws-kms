###############################################################################
# Identity
###############################################################################

variable "name" {
 description = <<EOT
Friendly name for the CMK, used to build the primary alias (alias/<name>) and to
label the key. REQUIRED. Do NOT include the "alias/" prefix — the module adds it.
Alias names are unique per account per Region; changing this replaces the alias
(FORCE-NEW on the alias, not on the key). The reserved "alias/aws/" namespace is
AWS-managed and rejected by validation.
EOT
 type = string

 validation {
 condition = !startswith(var.name, "alias/")
 error_message = "name must NOT include the 'alias/' prefix; the module prepends it automatically."
 }

 validation {
 condition = !startswith(var.name, "aws/")
 error_message = "name must not begin with 'aws/'; the alias/aws/* namespace is reserved for AWS-managed keys."
 }
}

###############################################################################
# Key configuration
###############################################################################

variable "description" {
 description = "Human-readable description of the key's purpose, shown in the KMS console."
 type = string
 default = "Customer-managed KMS key managed by Terraform (tf_mod_aws_kms)."
}

variable "key_usage" {
 description = <<EOT
Intended cryptographic use of the key. FORCE-NEW — changing this recreates the
key. One of:
 - ENCRYPT_DECRYPT (default; symmetric encryption, the common case)
 - SIGN_VERIFY (asymmetric signing — requires an RSA/ECC key spec)
 - GENERATE_VERIFY_MAC (HMAC — requires an HMAC key spec)
EOT
 type = string
 default = "ENCRYPT_DECRYPT"

 validation {
 condition = contains(["ENCRYPT_DECRYPT", "SIGN_VERIFY", "GENERATE_VERIFY_MAC"], var.key_usage)
 error_message = "key_usage must be one of ENCRYPT_DECRYPT, SIGN_VERIFY, or GENERATE_VERIFY_MAC."
 }
}

variable "customer_master_key_spec" {
 description = <<EOT
Key material type and supported algorithms. FORCE-NEW — changing this recreates
the key. Defaults to SYMMETRIC_DEFAULT (a 256-bit symmetric key), the secure,
low-surprise default for at-rest encryption. Use an RSA_*/ECC_* spec only with
key_usage = SIGN_VERIFY, and an HMAC_* spec only with GENERATE_VERIFY_MAC.
EOT
 type = string
 default = "SYMMETRIC_DEFAULT"

 validation {
 condition = contains([
 "SYMMETRIC_DEFAULT",
 "RSA_2048", "RSA_3072", "RSA_4096",
 "ECC_NIST_P256", "ECC_NIST_P384", "ECC_NIST_P521", "ECC_SECG_P256K1",
 "HMAC_224", "HMAC_256", "HMAC_384", "HMAC_512",
 "SM2",
 ], var.customer_master_key_spec)
 error_message = "customer_master_key_spec must be a valid KMS key spec (e.g. SYMMETRIC_DEFAULT, RSA_2048, ECC_NIST_P256, HMAC_256, SM2)."
 }
}

variable "enable_key_rotation" {
 description = <<EOT
Whether AWS-managed automatic rotation of the key material is enabled. Defaults
to true (secure baseline — rotation limits the blast radius of any single key
version). Only supported for SYMMETRIC_DEFAULT keys; set false for asymmetric/HMAC
keys (which cannot rotate) or with a documented exception.
EOT
 type = bool
 default = true
}

variable "rotation_period_in_days" {
 description = <<EOT
Custom number of days between automatic rotations. Null (default) uses the AWS
default of 365 days. Only meaningful when enable_key_rotation = true; must be
between 90 and 2560 inclusive.
EOT
 type = number
 default = null

 validation {
 condition = var.rotation_period_in_days == null || try(var.rotation_period_in_days >= 90 && var.rotation_period_in_days <= 2560, false)
 error_message = "rotation_period_in_days must be between 90 and 2560, or null to use the AWS default (365)."
 }
}

variable "deletion_window_in_days" {
 description = <<EOT
Waiting period (in days) before a scheduled key deletion completes. Deletion is
asynchronous — destroying the key schedules it, and data encrypted under the key
is UNRECOVERABLE once deletion completes. Defaults to 30 (the safe maximum
recovery window); may be lowered to a minimum of 7.
EOT
 type = number
 default = 30

 validation {
 condition = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
 error_message = "deletion_window_in_days must be between 7 and 30 inclusive."
 }
}

variable "is_enabled" {
 description = "Whether the key is enabled for cryptographic operations. Defaults to true. Set false to disable the key without deleting it."
 type = bool
 default = true
}

variable "multi_region" {
 description = <<EOT
Whether this is a multi-Region PRIMARY key (true) or a single-Region key (false).
FORCE-NEW — changing this recreates the key. Must be true before a replica (see
var.replica) can be created. Defaults to false (single-Region); enable only when a
DR/cross-Region replica is genuinely required.
EOT
 type = bool
 default = false
}

variable "bypass_policy_lockout_safety_check" {
 description = <<EOT
Whether to bypass the key-policy lockout safety check on the key and key policy.
Defaults to false (secure). Setting true increases the risk that the key becomes
unmanageable; do not enable indiscriminately. The module's default policy already
grants the account root kms:* so the safety check normally passes.
EOT
 type = bool
 default = false
}

###############################################################################
# Key policy
#
# Supply EITHER a full custom policy (var.policy) OR let the module assemble a
# secure default from key_administrators / key_users / key_service_principals.
# In both cases an account-root kms:* statement guarantees the key never locks
# out (non-negotiable safety floor) unless you opt out via bypass + custom policy.
###############################################################################

variable "policy" {
 description = <<EOT
Full key policy as a JSON-encoded string. When set, it is attached verbatim and
the key_administrators / key_users / key_service_principals inputs are IGNORED.
Leave null (default) to have the module build a secure default policy. Build with
jsonencode() or aws_iam_policy_document. Note: a custom policy that omits root
access can lock the key — keep an account-root or break-glass kms:* statement.
EOT
 type = string
 default = null

 validation {
 condition = var.policy == null || can(jsondecode(var.policy))
 error_message = "policy must be a valid JSON-encoded KMS key policy document, or null."
 }
}

variable "key_administrators" {
 description = <<EOT
IAM principal ARNs (roles/users) allowed to ADMINISTER the key — manage its
policy, rotation, tags, and lifecycle, but NOT use it for cryptographic
operations. Rendered into the default key policy only when var.policy is null.
Wire from tf_mod_aws_iam_role / tf_mod_aws_iam_user (arn output).
EOT
 type = list(string)
 default = []

 validation {
 condition = alltrue([for a in var.key_administrators: can(regex("^arn:aws[a-zA-Z-]*:iam::", a))])
 error_message = "Every key_administrators entry must be an IAM principal ARN (arn:aws:iam::...)."
 }
}

variable "key_users" {
 description = <<EOT
IAM principal ARNs (roles/users) allowed to USE the key for cryptographic
operations (Encrypt/Decrypt/GenerateDataKey/ReEncrypt/DescribeKey) and to create
grants for AWS service integrations. Rendered into the default key policy only
when var.policy is null. Wire from tf_mod_aws_iam_role (arn output).
EOT
 type = list(string)
 default = []

 validation {
 condition = alltrue([for a in var.key_users: can(regex("^arn:aws[a-zA-Z-]*:iam::", a))])
 error_message = "Every key_users entry must be an IAM principal ARN (arn:aws:iam::...)."
 }
}

variable "key_service_principals" {
 description = <<EOT
AWS service principals (e.g. "logs.amazonaws.com", "delivery.logs.amazonaws.com",
"s3.amazonaws.com") allowed to USE the key, for service integrations that encrypt
with a CMK (CloudWatch Logs, CloudTrail, S3, SNS, etc.). Rendered into the default
key policy only when var.policy is null. Granted the same usage actions as
key_users; scope further with a full custom var.policy if needed.
EOT
 type = list(string)
 default = []

 validation {
 condition = alltrue([for s in var.key_service_principals: can(regex("\\.amazonaws\\.com$", s))])
 error_message = "Every key_service_principals entry must be an AWS service principal ending in '.amazonaws.com'."
 }
}

###############################################################################
# Aliases
###############################################################################

variable "additional_aliases" {
 description = <<EOT
Extra alias names pointing at this key, in addition to the primary alias/<name>.
Each entry may be given with or without the "alias/" prefix (the module
normalizes it). Useful when several friendly names should resolve to one key.
The reserved "alias/aws/" namespace is rejected.
EOT
 type = set(string)
 default = []

 validation {
 condition = alltrue([for a in var.additional_aliases: !startswith(trimprefix(a, "alias/"), "aws/")])
 error_message = "additional_aliases must not target the reserved alias/aws/* namespace."
 }
}

###############################################################################
# Grants (child collection — for_each over a map)
###############################################################################

variable "grants" {
 description = <<EOT
Optional programmatic grants on the key, keyed by a stable name. Each grant is one
aws_kms_grant. Grants are an alternative to policy statements for delegating a
narrow set of operations to a principal, optionally constrained by encryption
context. ALL grant fields are FORCE-NEW — changing one recreates the grant.

 - grantee_principal: IAM ARN given the operations (required).
 - operations: list of permitted KMS operations (required); valid
 values include Encrypt, Decrypt, GenerateDataKey,
 GenerateDataKeyWithoutPlaintext, ReEncryptFrom,
 ReEncryptTo, Sign, Verify, GetPublicKey, CreateGrant,
 RetireGrant, DescribeKey, GenerateDataKeyPair,
 GenerateDataKeyPairWithoutPlaintext.
 - retiring_principal: IAM ARN allowed to retire the grant (optional).
 - grant_creation_tokens: grant tokens to use when creating the grant (optional).
 - retire_on_delete: true retires (vs revokes) the grant on destroy; needs
 extra permissions. Defaults to false (revoke).
 - constraints: optional encryption-context constraint. Set exactly
 one of encryption_context_equals / _subset.
 - name: friendly grant name; defaults to the map key.

 grants = {
 app-decrypt = {
 grantee_principal = "arn:aws:iam::111122223333:role/app"
 operations = ["Decrypt", "DescribeKey"]
 constraints = { encryption_context_equals = { Department = "Finance" } }
 }
 }
EOT
 type = map(object({
 grantee_principal = string
 operations = list(string)
 retiring_principal = optional(string)
 grant_creation_tokens = optional(list(string))
 retire_on_delete = optional(bool, false)
 constraints = optional(object({
 encryption_context_equals = optional(map(string))
 encryption_context_subset = optional(map(string))
 }))
 name = optional(string)
 }))
 default = {}

 validation {
 condition = alltrue([
 for g in var.grants: alltrue([
 for op in g.operations: contains([
 "Decrypt", "Encrypt", "GenerateDataKey", "GenerateDataKeyWithoutPlaintext",
 "ReEncryptFrom", "ReEncryptTo", "Sign", "Verify", "GetPublicKey",
 "CreateGrant", "RetireGrant", "DescribeKey",
 "GenerateDataKeyPair", "GenerateDataKeyPairWithoutPlaintext",
 ], op)
 ])
 ])
 error_message = "Each grants[*].operations entry must be a valid KMS grant operation (e.g. Encrypt, Decrypt, GenerateDataKey, DescribeKey, CreateGrant)."
 }

 validation {
 condition = alltrue([
 for g in var.grants:
 g.constraints == null ? true: !(g.constraints.encryption_context_equals != null && g.constraints.encryption_context_subset != null)
 ])
 error_message = "Each grant constraint may set at most one of encryption_context_equals or encryption_context_subset; they conflict."
 }
}

###############################################################################
# Multi-Region replica (optional)
#
# Requires multi_region = true on the primary AND a configured aws.replica
# provider in the target Region (see providers.tf).
###############################################################################

variable "replica" {
 description = <<EOT
Optional multi-Region replica of this key, created in the Region of the
aws.replica provider alias. Leave null (default) for a single-Region key. When
set, var.multi_region MUST be true. The replica shares the primary's key id and
key material; its policy defaults to the same computed key policy as the primary.

 - description: replica description (defaults to the primary's).
 - deletion_window_in_days: 7–30; defaults to the primary's value.
 - enabled: whether the replica is enabled (default true).
 - policy: full custom replica key policy JSON (default: reuse
 the primary's computed policy).
 - tags: extra tags merged over module tags on the replica.
EOT
 type = object({
 description = optional(string)
 deletion_window_in_days = optional(number)
 enabled = optional(bool, true)
 policy = optional(string)
 tags = optional(map(string), {})
 })
 default = null

 validation {
 condition = var.replica == null || var.multi_region == true
 error_message = "replica requires multi_region = true on the primary key (a replica can only be made of a multi-Region primary)."
 }

 validation {
 condition = var.replica == null || try(var.replica.deletion_window_in_days, null) == null || try(var.replica.deletion_window_in_days >= 7 && var.replica.deletion_window_in_days <= 30, false)
 error_message = "replica.deletion_window_in_days must be between 7 and 30 inclusive, or null to inherit the primary's value."
 }

 validation {
 condition = var.replica == null || try(var.replica.policy, null) == null || can(jsondecode(var.replica.policy))
 error_message = "replica.policy must be a valid JSON-encoded KMS key policy document, or null."
 }
}

###############################################################################
# Universal tail
###############################################################################

variable "tags" {
 description = <<EOT
A map of tags to assign to all taggable resources created by this module (the key
and, when created, the multi-Region replica). These merge with provider-level
default_tags; resource tags win on key conflict. The computed tags_all output
reflects the merged set. Aliases, the key policy, and grants are not taggable.
EOT
 type = map(string)
 default = {}
}
