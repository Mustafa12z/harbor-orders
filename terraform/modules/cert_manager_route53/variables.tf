variable "project_id" {
  type        = string
  description = "GCP project that hosts the GSM secret."
}

variable "environment" {
  type        = string
  description = "Environment label (dev, staging, prod)."
}

variable "iam_user_name" {
  type        = string
  description = "AWS IAM user name for cert-manager Route53 DNS-01."
}

variable "route53_zone_id" {
  type        = string
  description = "Hosted zone ID cert-manager may mutate for ACME challenges."
}

variable "gsm_secret_id" {
  type        = string
  description = "Secret Manager secret id for the Route53 access key JSON."
}

variable "aws_region" {
  type        = string
  description = "AWS region hint stored alongside the keys (Route53 is global)."
  default     = "eu-west-2"
}

variable "accessor_members" {
  type        = map(string)
  description = "IAM members granted secretAccessor on the GSM secret, keyed by a stable label."
  default     = {}
}

variable "extra_tags" {
  type        = map(string)
  description = "Additional AWS resource tags."
  default     = {}
}
