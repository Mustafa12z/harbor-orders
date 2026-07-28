variable "project_id" {
  type = string
}

variable "name" {
  type    = string
  default = "dev"
}

variable "location" {
  type        = string
  description = "Region for regional Autopilot (e.g. europe-west2) or zone for zonal (e.g. europe-west2-a)"
}

variable "network" {
  type = string
}

variable "subnetwork" {
  type = string
}

variable "pods_range_name" {
  type = string
}

variable "services_range_name" {
  type = string
}

variable "release_channel" {
  type    = string
  default = "REGULAR"
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "master_ipv4_cidr_block" {
  type        = string
  default     = "172.16.0.0/28"
  description = "Private control-plane range. Must be unique per cluster when clusters in the same project could ever be peered."
}

variable "master_authorized_cidrs" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [
    {
      cidr_block   = "0.0.0.0/0"
      display_name = "dev-open-replace-me"
    }
  ]
  description = "Restrict to your IP in terraform.tfvars for safer personal use"
}

variable "resource_labels" {
  type        = map(string)
  description = "Labels applied to the GKE cluster"
  default = {
    managed-by = "terraform"
  }
}
