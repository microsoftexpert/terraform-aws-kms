###############################################################################
# Primary outputs (id + arn)
###############################################################################

output "id" {
 description = "The globally unique identifier (UUID) of the KMS key. Same value as key_id."
 value = aws_kms_key.this.key_id
}

output "key_id" {
 description = "The KMS key id (UUID). Consumed by kms_key_id inputs on RDS, EBS, DynamoDB, etc."
 value = aws_kms_key.this.key_id
}

output "arn" {
 description = <<EOT
The ARN of the KMS key (cross-resource reference type:
arn:aws:kms:<region>:<account>:key/<uuid>). This is the canonical value to wire
into S3 SSE-KMS, RDS/Aurora, EFS, Secrets Manager, CloudTrail, and other
encryption inputs — prefer it over the bare UUID.
EOT
 value = aws_kms_key.this.arn
}

###############################################################################
# Aliases
###############################################################################

output "alias_name" {
 description = "The primary alias name (alias/<name>)."
 value = aws_kms_alias.this.name
}

output "alias_arn" {
 description = "The ARN of the primary alias (arn:aws:kms:<region>:<account>:alias/<name>). Accepted by services that take an alias ARN."
 value = aws_kms_alias.this.arn
}

output "additional_alias_arns" {
 description = "Map of additional alias name => alias ARN for any extra aliases created."
 value = { for k, a in aws_kms_alias.additional: k => a.arn }
}

###############################################################################
# Key policy
###############################################################################

output "key_policy" {
 description = "The effective key policy JSON attached to the key (caller-supplied or the module's computed secure default)."
 value = aws_kms_key_policy.this.policy
}

###############################################################################
# Grants
###############################################################################

output "grant_ids" {
 description = "Map of grant key (from var.grants) => grant id for each created grant."
 value = { for k, g in aws_kms_grant.this: k => g.grant_id }
}

output "grant_tokens" {
 description = "Map of grant key => grant token for each created grant. Sensitive — grant tokens are bearer credentials usable until the grant is eventually consistent."
 value = { for k, g in aws_kms_grant.this: k => g.grant_token }
 sensitive = true
}

###############################################################################
# Multi-Region replica
###############################################################################

output "replica_arn" {
 description = "ARN of the multi-Region replica key when created; null otherwise. Consumed by DR-Region resources that encrypt against this key."
 value = try(aws_kms_replica_key.this["this"].arn, null)
}

output "replica_key_id" {
 description = "Key id of the multi-Region replica when created; null otherwise. Shares the primary's UUID (multi-Region keys have the same key id)."
 value = try(aws_kms_replica_key.this["this"].key_id, null)
}

###############################################################################
# Tags
###############################################################################

output "tags_all" {
 description = "All tags on the key, including those inherited from provider default_tags (resource tags win on key conflict)."
 value = aws_kms_key.this.tags_all
}
