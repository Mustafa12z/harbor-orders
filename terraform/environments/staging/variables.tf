variable "project_id" {
  type        = string
  description = "GCP project ID"
}

variable "region" {
  type        = string
  description = "GCP region (Artifact Registry, subnet)"
  default     = "europe-west2"
}

variable "zone" {
  type        = string
  description = "GCP zone for zonal Autopilot cluster"
  default     = "europe-west2-a"
}

variable "cluster_name" {
  type    = string
  default = "staging"
}

# Distinct from dev's namespace on purpose. Workload Identity members are
# project-wide (PROJECT.svc.id.goog[NAMESPACE/KSA]), so sharing the namespace
# across clusters in one project would let dev impersonate this environment's GSAs.
variable "k8s_namespace" {
  type    = string
  default = "orders-staging"
}

variable "master_authorized_cidrs" {
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = [
    {
      cidr_block   = "0.0.0.0/0"
      display_name = "staging-open-replace-with-your-ip"
    }
  ]
  description = "Restrict control-plane access to your public IP/32 when possible"
}

variable "postgres_password" {
  type        = string
  sensitive   = true
  description = "Postgres password stored in Secret Manager (also used to seed the cluster Secret via make secrets)"
  default     = ""
}

variable "jwt_secret" {
  type        = string
  sensitive   = true
  description = "JWT signing secret for api-gateway"
  default     = ""
}

variable "domain_name" {
  type        = string
  description = "Public hostname for the GCE Ingress (Route 53 A record + ManagedCertificate). Empty skips DNS/IP wiring."
  default     = ""
}

variable "route53_zone_id" {
  type        = string
  description = "Route 53 hosted zone ID for domain_name (preferred)."
  default     = ""
}

variable "route53_zone_name" {
  type        = string
  description = "Route 53 hosted zone name (e.g. mustafamirreh.com). Used when route53_zone_id is empty."
  default     = ""

  validation {
    condition     = var.domain_name == "" || var.route53_zone_id != "" || var.route53_zone_name != ""
    error_message = "route53_zone_id or route53_zone_name is required when domain_name is set."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for the provider (Route 53 is global; used as API endpoint)."
  default     = "eu-west-2"
}

variable "alert_email" {
  type        = string
  description = "Email for Cloud Monitoring alerts. Empty skips notification channel and alert policies."
  default     = ""
}

variable "grafana_otlp_endpoint" {
  type        = string
  description = "Grafana Cloud OTLP endpoint. Empty skips Grafana secret."
  default     = ""
  sensitive   = true
}

variable "grafana_instance_id" {
  type        = string
  description = "Grafana Cloud instance / stack user ID used as basic-auth username for OTLP"
  default     = ""
}

variable "grafana_api_token" {
  type        = string
  description = "Grafana Cloud access policy token (basic-auth password for OTLP)"
  default     = ""
  sensitive   = true
}

variable "deletion_protection" {
  type        = bool
  description = "Block accidental cluster deletion. Enabled for prod."
  default     = false
}

variable "name_suffix" {
  type        = string
  description = "Appended to project-scoped resource names (GSAs, Pub/Sub topics, secrets, VPC) so environments can share one GCP project."
  default     = "-staging"
}

variable "manage_project_singletons" {
  type        = bool
  description = "Whether this root manages project-wide IAM for the shared Artifact Registry (GKE node SA reader). The repository itself is created out of band via gcloud/console. Normally false when sharing a project with dev."
  default     = false
}

variable "artifact_registry_repository_id" {
  type        = string
  description = "Shared image repository. Intentionally identical across environments so a digest built once can be promoted without copying images."
  default     = "gke-orders"
}


variable "subnet_cidr" {
  type        = string
  description = "Primary node subnet range"
  default     = "10.11.0.0/20"
}

variable "pods_cidr" {
  type        = string
  description = "Secondary range for pods"
  default     = "10.24.0.0/14"
}

variable "services_cidr" {
  type        = string
  description = "Secondary range for services"
  default     = "10.33.0.0/20"
}

variable "master_ipv4_cidr_block" {
  type        = string
  description = "Private control-plane range; must not overlap other clusters in the project"
  default     = "172.16.0.16/28"
}


variable "eso_k8s_service_account" {
  type        = string
  description = "Kubernetes ServiceAccount in k8s_namespace that External Secrets impersonates to read Secret Manager"
  default     = "secret-reader"
}
