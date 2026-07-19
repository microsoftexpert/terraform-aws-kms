terraform {
 required_version = ">= 1.12.0"

 required_providers {
 aws = {
 source = "hashicorp/aws"
 version = ">= 6.0, < 7.0"

 # configuration_aliases declares a SECOND provider for the optional
 # multi-Region replica key. aws_kms_replica_key must be created in a
 # different Region than the primary, which is only expressible by binding
 # the resource to an aliased provider (aws.replica).
 #
 # The caller ALWAYS passes both providers:
 # providers = {
 # aws = aws # primary Region (where the key lives)
 # aws.replica = aws.us_west_2 # DR Region for the replica
 # }
 #
 # Single-Region callers (the common case) point both at the same provider:
 # providers = {
 # aws = aws
 # aws.replica = aws # unused unless var.replica is set
 # }
 configuration_aliases = [aws, aws.replica]
 }
 }
}
