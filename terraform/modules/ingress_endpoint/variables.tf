variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "address_name" {
  type        = string
  description = "Name of the global static IP (referenced by GCE Ingress annotation)"
  default     = "gke-orders-ingress"
}

variable "domain_name" {
  type        = string
  description = "FQDN for the app (e.g. dev.order.mustafamirreh.com)"
}

variable "route53_zone_id" {
  type        = string
  description = "Route 53 hosted zone ID (e.g. Z07782661B5WKHOHAEPWD). Preferred over zone name."
  default     = ""
}

variable "route53_zone_name" {
  type        = string
  description = "Route 53 hosted zone name (e.g. mustafamirreh.com). Used when route53_zone_id is empty."
  default     = ""

  validation {
    condition     = var.route53_zone_id != "" || var.route53_zone_name != ""
    error_message = "Set route53_zone_id or route53_zone_name."
  }
}
