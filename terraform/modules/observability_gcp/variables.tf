variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for monitoring resource names"
  default     = "gke-orders"
}

variable "environment" {
  type        = string
  description = "Environment label (dev/staging/prod)"
}

variable "k8s_namespace" {
  type        = string
  description = "Application namespace for log filters"
  default     = "orders"
}

variable "alert_email" {
  type        = string
  description = "Email for Cloud Monitoring notification channel. Empty skips alert policies."
  default     = ""
}

variable "uptime_host" {
  type        = string
  description = "Hostname for HTTPS uptime check (e.g. dev.order.mustafamirreh.com). Empty skips uptime check."
  default     = ""
}

variable "uptime_path" {
  type        = string
  description = "Path for uptime check"
  default     = "/healthz"
}
