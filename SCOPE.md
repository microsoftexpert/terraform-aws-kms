# tf-mod-aws-kms — SCOPE

Composite module for a secure-by-default AWS KMS customer-managed key (CMK). It owns
the key, its human-friendly alias, the key policy, optional grants, and an optional
multi-Region replica so a single module call produces a rotation-enabled, auditable
encryption key aligned with the Casey's (NPI / GLBA / FCA) baseline. This is the
**encryption foundation** consumed by S3, RDS/Aurora, EBS, EFS, Secrets Manager,
DynamoDB, CloudTrail, and more.

- **Module type:** Composite
- **Primary resource (keystone):** `aws_kms_key.this`

## In-scope resources

The module manages **all** of the following (allow-list):

- `aws_kms_key` — keystone (the CMK)
- `aws_kms_alias` — friendly `alias/<name>` pointer
- `aws_kms_key_policy` — the resource policy on the key
- `aws_kms_grant` — optional programmatic grants (`map(object(...))`, `for_each`)
- `aws_kms_replica_key` — optional multi-Region replica of a multi-Region primary

## Out-of-scope resources (consumed by reference)

Referenced by `arn`, never created here:

- IAM principals (roles/users) named as key administrators, users, or grantees — by `arn`
- AWS service principals authorized in the key policy (e.g. `s3.amazonaws.com`)
- Consuming resources (buckets, databases, secrets) that point at this key by `arn`/`key_id`

## Consumes

| Input | Type | Source module |
|---|---|---|
| `key_administrators` | `list(string)` (IAM ARNs) | `tf-mod-aws-iam-role` / `tf-mod-aws-iam-user` |
| `key_users` | `list(string)` (IAM ARNs) | `tf-mod-aws-iam-role` |
| `grants[*].grantee_principal` | `string` (IAM ARN) | `tf-mod-aws-iam-role` |

> **Foundation module** — KMS consumes nothing from other infrastructure modules.
> It emits `arn` / `key_id` / alias ARN that the rest of the suite encrypts against.

## Required IAM permissions

Least-privilege actions the Terraform identity needs (scope to the key ARN where possible):

| Action | Required for |
|---|---|
| `kms:CreateKey`, `kms:DescribeKey` | Key lifecycle / read-back |
| `kms:ScheduleKeyDeletion`, `kms:CancelKeyDeletion` | Destroy (deletion is scheduled, not immediate) |
| `kms:EnableKeyRotation`, `kms:DisableKeyRotation`, `kms:GetKeyRotationStatus` | Automatic rotation control |
| `kms:PutKeyPolicy`, `kms:GetKeyPolicy` | Key policy management |
| `kms:CreateAlias`, `kms:DeleteAlias`, `kms:UpdateAlias`, `kms:ListAliases` | Alias lifecycle |
| `kms:CreateGrant`, `kms:RetireGrant`, `kms:RevokeGrant`, `kms:ListGrants` | Optional grants |
| `kms:ReplicateKey`, `kms:UpdatePrimaryRegion` | Multi-Region replica (`aws_kms_replica_key`) |
| `kms:TagResource`, `kms:UntagResource`, `kms:ListResourceTags` | Tagging |

No `iam:PassRole` required. Grantee/administrator principals are referenced by ARN in
the policy/grant, not assumed by the Terraform identity.

## AWS Prerequisites

- **No service-linked role** is required for KMS.
- **Account-level:** none — KMS is enabled in every account/Region by default.
- **Multi-Region replica:** the primary key must be created with `multi_region = true`
  before a `aws_kms_replica_key` can replicate it; the replica is created in a different
  Region via a provider alias (`providers = { aws = aws.<other_region> }`).
- **Key-policy lockout warning:** the key policy must always grant the account root (or a
  break-glass principal) `kms:*`, or the key can become unmanageable. The module bakes a
  root-account statement into the default policy.
- **Quotas:** soft limit of 100,000 customer-managed keys per account per Region (raisable);
  50,000 grants per CMK.

## Emits

| Output | Description | Consumed by |
|---|---|---|
| `id` | Key id (UUID) | KMS API references |
| `key_id` | Same UUID, explicit name | `kms_key_id` inputs (RDS, EBS, DynamoDB) |
| `arn` | Key ARN (`arn:aws:kms:<region>:<acct>:key/<uuid>`) — cross-resource reference type | S3 SSE-KMS, RDS, EFS, Secrets Manager, CloudTrail |
| `alias_name` | `alias/<name>` | console / CLI references |
| `alias_arn` | Alias ARN (`arn:aws:kms:<region>:<acct>:alias/<name>`) | services that accept alias ARNs |
| `replica_arn` | Replica key ARN (when multi-Region) | DR-region consumers |
| `tags_all` | All tags incl. provider `default_tags` | governance/audit |

## Provider gotchas

- **`tags` vs `tags_all`.** `var.tags` flows to every taggable resource (`aws_kms_key`,
  `aws_kms_replica_key`); `tags_all` is the computed merge of resource tags over provider
  `default_tags` (resource tags win on key conflict). `default_tags` is the **caller's**
  provider-block concern, never set in the module.
- **`arn` is the cross-resource reference type** — most encryption inputs accept either the
  key ARN or the alias ARN; prefer the ARN over the bare UUID for clarity.
- **Deletion is asynchronous.** `aws_kms_key` destroy schedules deletion after a waiting
  window (`deletion_window_in_days`, 7–30, default 30 for safety). Data encrypted under a
  deleted key is unrecoverable — document the cost/safety tradeoff.
- **`customer_master_key_spec`, `key_usage`, and `multi_region` are FORCE-NEW.** Changing
  any recreates the key.
- **Alias names are unique per account per Region** and must be prefixed `alias/` (the
  module adds the prefix). `alias/aws/*` is reserved for AWS-managed keys.
- **Key-policy eventual consistency** — a freshly created principal referenced in the policy
  may not yet be resolvable; KMS validates principals at `PutKeyPolicy` time.
- **Policy is managed off the key.** The policy lives on `aws_kms_key_policy.this`, not the
  key's inline `policy` argument. Setting both causes perpetual drift (provider NOTE); the key
  is created with KMS's transient default policy, then immediately overwritten.
- **`configuration_aliases` requires both providers on every call.** Because the module
  declares `configuration_aliases = [aws, aws.replica]`, the caller MUST pass
  `providers = { aws = ..., aws.replica = ... }` even when no replica is used (point both at
  the same provider). Omitting `aws.replica` is a plan-time error.

## Secure-by-default decisions

| Posture | Default | Opt-out |
|---|---|---|
| Automatic key rotation | `enable_key_rotation = true` | `enable_key_rotation = false` (discouraged) |
| Deletion safety | `deletion_window_in_days = 30` | lower to 7 (minimum) |
| Key policy | root-account `kms:*` statement always present (no lockout) | n/a — non-negotiable safety floor |
| Key spec | `SYMMETRIC_DEFAULT`, `key_usage = ENCRYPT_DECRYPT` | `customer_master_key_spec` for asymmetric/HMAC |
| Multi-Region | single-Region (`multi_region = false`) | `multi_region = true` + replica |

## Design decisions

- One composite owns the key plus its alias, policy, grants, and replica so callers get a
  complete, rotation-enabled, lockout-safe CMK from a single call rather than wiring four
  resources by hand.
- Grants and the replica are **optional** (`map(object(...))` defaulting `{}` / nullable
  object) and rendered via `dynamic` blocks / conditional resources — absent unless configured.
- KMS is deliberately a **foundation** module: it consumes nothing and is consumed widely.
  Building it first lets every downstream stateful module wire `kms_key_arn` to a real CMK.
