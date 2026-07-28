variable "project_id" {
  type = string
}

variable "secret_id" {
  type = string
}

variable "secret_data" {
  type      = string
  sensitive = true
}

# Keyed by a stable label rather than the member string: member values can be
# service account emails that are unknown until apply, which would make a
# set-based for_each unplannable.
variable "accessor_members" {
  type        = map(string)
  default     = {}
  description = "IAM members granted roles/secretmanager.secretAccessor on this secret only, keyed by a stable label"
}
