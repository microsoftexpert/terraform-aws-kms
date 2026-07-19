###############################################################################
# Account / partition context (used to build the lockout-safe default policy)
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
 account_root_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"

 # Standard "key administrator" action set (manage the key, never use it).
 key_admin_actions = [
 "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*", "kms:Put*",
 "kms:Update*", "kms:Revoke*", "kms:Disable*", "kms:Get*", "kms:Delete*",
 "kms:TagResource", "kms:UntagResource", "kms:ScheduleKeyDeletion",
 "kms:CancelKeyDeletion", "kms:ReplicateKey", "kms:UpdatePrimaryRegion",
 ]

 # Standard "key user" action set (use the key for crypto, never administer it).
 key_user_actions = [
 "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
 "kms:GenerateDataKey*", "kms:DescribeKey",
 ]

 # The effective policy: caller-supplied verbatim, else the computed secure
 # default (data.aws_iam_policy_document.default below). The default's
 # account-root kms:* statement is the non-negotiable safety floor that prevents
 # the key from ever locking out.
 key_policy = coalesce(var.policy, data.aws_iam_policy_document.default.json)

 # Normalize aliases to the required "alias/" prefix and key them by full name.
 additional_aliases = {
 for a in var.additional_aliases:
 (startswith(a, "alias/") ? a: "alias/${a}") => (startswith(a, "alias/") ? a: "alias/${a}")
 }
}

###############################################################################
# Default key policy (used only when var.policy is null)
#
# Built with aws_iam_policy_document so the secure default is assembled from
# heterogeneous, optional statements without HCL type-unification headaches.
###############################################################################

data "aws_iam_policy_document" "default" {
 # Non-negotiable safety floor: the account root keeps full control so the key
 # can never be locked out of management.
 statement {
 sid = "EnableRootAccountPermissions"
 effect = "Allow"
 actions = ["kms:*"]
 resources = ["*"]

 principals {
 type = "AWS"
 identifiers = [local.account_root_arn]
 }
 }

 # Key administrators — manage the key, never use it.
 dynamic "statement" {
 for_each = length(var.key_administrators) > 0 ? [1]: []
 content {
 sid = "AllowKeyAdministration"
 effect = "Allow"
 actions = local.key_admin_actions
 resources = ["*"]

 principals {
 type = "AWS"
 identifiers = var.key_administrators
 }
 }
 }

 # Key users — cryptographic operations.
 dynamic "statement" {
 for_each = length(var.key_users) > 0 ? [1]: []
 content {
 sid = "AllowKeyUsage"
 effect = "Allow"
 actions = local.key_user_actions
 resources = ["*"]

 principals {
 type = "AWS"
 identifiers = var.key_users
 }
 }
 }

 # Key users — grants for AWS service integrations (scoped via condition).
 dynamic "statement" {
 for_each = length(var.key_users) > 0 ? [1]: []
 content {
 sid = "AllowGrantsForAWSResources"
 effect = "Allow"
 actions = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
 resources = ["*"]

 principals {
 type = "AWS"
 identifiers = var.key_users
 }

 condition {
 test = "Bool"
 variable = "kms:GrantIsForAWSResource"
 values = ["true"]
 }
 }
 }

 # AWS service principals — cryptographic operations for service integrations.
 dynamic "statement" {
 for_each = length(var.key_service_principals) > 0 ? [1]: []
 content {
 sid = "AllowServicePrincipalUsage"
 effect = "Allow"
 actions = local.key_user_actions
 resources = ["*"]

 principals {
 type = "Service"
 identifiers = var.key_service_principals
 }
 }
 }
}

###############################################################################
# KMS key (keystone)
#
# The key policy is managed by the dedicated aws_kms_key_policy.this resource
# below, NOT via the key's inline `policy` argument — configuring both causes
# drift (provider NOTE). The key is created with KMS's transient default policy,
# then immediately overwritten by aws_kms_key_policy.this.
###############################################################################

resource "aws_kms_key" "this" {
 description = var.description

 key_usage = var.key_usage
 customer_master_key_spec = var.customer_master_key_spec

 enable_key_rotation = var.enable_key_rotation
 rotation_period_in_days = var.rotation_period_in_days

 deletion_window_in_days = var.deletion_window_in_days
 is_enabled = var.is_enabled
 multi_region = var.multi_region
 bypass_policy_lockout_safety_check = var.bypass_policy_lockout_safety_check

 tags = var.tags
}

###############################################################################
# Key policy (lockout-safe resource policy)
###############################################################################

resource "aws_kms_key_policy" "this" {
 key_id = aws_kms_key.this.key_id
 policy = local.key_policy

 bypass_policy_lockout_safety_check = var.bypass_policy_lockout_safety_check
}

###############################################################################
# Primary alias (alias/<name>)
###############################################################################

resource "aws_kms_alias" "this" {
 name = "alias/${var.name}"
 target_key_id = aws_kms_key.this.key_id
}

###############################################################################
# Additional aliases (optional) — all point at the same key
###############################################################################

resource "aws_kms_alias" "additional" {
 for_each = local.additional_aliases

 name = each.value
 target_key_id = aws_kms_key.this.key_id
}

###############################################################################
# Grants (optional, child collection)
###############################################################################

resource "aws_kms_grant" "this" {
 for_each = var.grants

 name = coalesce(try(each.value.name, null), each.key)
 key_id = aws_kms_key.this.key_id
 grantee_principal = each.value.grantee_principal
 operations = each.value.operations

 retiring_principal = try(each.value.retiring_principal, null)
 grant_creation_tokens = try(each.value.grant_creation_tokens, null)
 retire_on_delete = try(each.value.retire_on_delete, false)

 dynamic "constraints" {
 for_each = try(each.value.constraints, null) != null ? [each.value.constraints]: []
 content {
 encryption_context_equals = try(constraints.value.encryption_context_equals, null)
 encryption_context_subset = try(constraints.value.encryption_context_subset, null)
 }
 }
}

###############################################################################
# Multi-Region replica (optional) — created in the aws.replica Region
#
# Guarded via for_each (no count): the "this" key materializes only when the
# caller supplies a replica object. var.multi_region must be true (enforced by a
# variable validation). The replica reuses the primary's computed policy unless
# overridden.
###############################################################################

resource "aws_kms_replica_key" "this" {
 for_each = var.replica != null ? { this = var.replica }: {}
 provider = aws.replica

 primary_key_arn = aws_kms_key.this.arn
 description = coalesce(try(each.value.description, null), var.description)
 deletion_window_in_days = coalesce(try(each.value.deletion_window_in_days, null), var.deletion_window_in_days)
 enabled = try(each.value.enabled, true)
 policy = coalesce(try(each.value.policy, null), local.key_policy)

 bypass_policy_lockout_safety_check = var.bypass_policy_lockout_safety_check

 tags = merge(var.tags, try(each.value.tags, {}))
}
