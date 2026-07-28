variable "project_id" {
  type = string
}

variable "account_id" {
  type        = string
  description = "GCP service account ID (without domain)"
}

variable "display_name" {
  type = string
}

variable "gke_namespace" {
  type    = string
  default = "orders"
}

variable "k8s_service_account" {
  type = string
}

variable "roles" {
  type        = list(string)
  description = "Project-level IAM roles for the GSA"
  default     = []
}
