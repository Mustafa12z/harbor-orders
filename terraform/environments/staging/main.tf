terraform {
  required_version = ">= 1.5.0"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# Route 53 DNS for the public hostname (domain stays registered / hosted on AWS).
# skip_* lets GCP-only applies/imports proceed when the AWS SSO token is expired;
# real Route 53 ops still need valid creds from `aws login` / make up.
provider "aws" {
  region                      = var.aws_region
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

locals {
  # name_suffix is empty for dev, so every dev resource name is unchanged.
  name_prefix = "gke-orders${var.name_suffix}"

  # The Artifact Registry repository is shared by all environments on purpose:
  # build-once-promote-by-digest requires the digest to be resolvable from the
  # same repository in every environment. The repo itself is created out of
  # band (gcloud / console); this URL is computed from project/region/id.
  artifact_registry_repository_id = var.artifact_registry_repository_id
  artifact_registry_url           = "${var.region}-docker.pkg.dev/${var.project_id}/${var.artifact_registry_repository_id}"
}

# --- Project-level singletons -------------------------------------------------
# Artifact Registry is created out of band (gcloud / console), not by Terraform.
# The URL is deterministic from project/region/repository_id. One environment
# root may still grant GKE node SA read access when manage_project_singletons
# is true; the others leave IAM alone.

resource "google_artifact_registry_repository_iam_member" "gke_reader" {
  count = var.manage_project_singletons ? 1 : 0

  project    = var.project_id
  location   = var.region
  repository = local.artifact_registry_repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${data.google_project.current.number}-compute@developer.gserviceaccount.com"
}

module "network" {
  source     = "../../modules/network"
  project_id = var.project_id
  region     = var.region
  name       = local.name_prefix

  subnet_cidr   = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr
}

module "gke" {
  source = "../../modules/gke_autopilot"

  project_id              = var.project_id
  name                    = var.cluster_name
  location                = var.region
  network                 = module.network.network_name
  subnetwork              = module.network.subnet_name
  pods_range_name         = module.network.pods_range_name
  services_range_name     = module.network.services_range_name
  release_channel         = "REGULAR"
  deletion_protection     = var.deletion_protection
  master_authorized_cidrs = var.master_authorized_cidrs
  master_ipv4_cidr_block  = var.master_ipv4_cidr_block

  depends_on = [module.network]
}

module "pubsub" {
  source     = "../../modules/pubsub"
  project_id = var.project_id

  topic_name        = "order-events${var.name_suffix}"
  subscription_name = "order-events-worker${var.name_suffix}"
  dlq_topic_name    = "order-events-dlq${var.name_suffix}"
}

# Workload Identity for services that publish/consume Pub/Sub
module "wi_worker" {
  source              = "../../modules/workload_identity"
  project_id          = var.project_id
  account_id          = "orders-worker${var.name_suffix}"
  display_name        = "orders worker (pubsub)"
  gke_namespace       = var.k8s_namespace
  k8s_service_account = "worker"
  roles = [
    "roles/pubsub.subscriber",
    "roles/pubsub.viewer",
  ]

  depends_on = [module.gke, module.pubsub]
}

module "wi_publisher" {
  source              = "../../modules/workload_identity"
  project_id          = var.project_id
  account_id          = "orders-publisher${var.name_suffix}"
  display_name        = "orders event publishers"
  gke_namespace       = var.k8s_namespace
  k8s_service_account = "event-publisher"
  roles = [
    "roles/pubsub.publisher",
  ]

  depends_on = [module.gke, module.pubsub]
}

# Identity the External Secrets Operator assumes when reading Secret Manager on
# behalf of this namespace. It gets no project-level roles; access is granted per
# secret by the secret_manager module below.
module "wi_eso" {
  source              = "../../modules/workload_identity"
  project_id          = var.project_id
  account_id          = "orders-eso${var.name_suffix}"
  display_name        = "external secrets reader (${var.cluster_name})"
  gke_namespace       = var.k8s_namespace
  k8s_service_account = var.eso_k8s_service_account
  roles               = []

  depends_on = [module.gke]
}

data "google_project" "current" {
  project_id = var.project_id
}

resource "random_password" "postgres" {
  count   = var.postgres_password == "" ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "jwt" {
  count   = var.jwt_secret == "" ? 1 : 0
  length  = 32
  special = false
}

locals {
  postgres_password = var.postgres_password != "" ? var.postgres_password : random_password.postgres[0].result
  jwt_secret        = var.jwt_secret != "" ? var.jwt_secret : random_password.jwt[0].result

  # Granted secretAccessor on each application secret individually.
  eso_accessor_members = {
    eso = "serviceAccount:${module.wi_eso.email}"
  }
}

module "secret_postgres" {
  source           = "../../modules/secret_manager"
  project_id       = var.project_id
  secret_id        = "orders${var.name_suffix}-postgres-password"
  secret_data      = local.postgres_password
  accessor_members = local.eso_accessor_members
}

module "secret_jwt" {
  source           = "../../modules/secret_manager"
  project_id       = var.project_id
  secret_id        = "orders${var.name_suffix}-jwt-secret"
  secret_data      = local.jwt_secret
  accessor_members = local.eso_accessor_members
}

module "ingress_endpoint" {
  count  = var.domain_name != "" ? 1 : 0
  source = "../../modules/ingress_endpoint"

  project_id        = var.project_id
  address_name      = "${local.name_prefix}-ingress"
  domain_name       = var.domain_name
  route53_zone_id   = var.route53_zone_id
  route53_zone_name = var.route53_zone_name
}

locals {
  argocd_domain_name = var.argocd_domain_name != "" ? var.argocd_domain_name : (
    var.domain_name != "" ? "argocd.${var.domain_name}" : ""
  )
}

module "argocd_ingress_endpoint" {
  count  = local.argocd_domain_name != "" ? 1 : 0
  source = "../../modules/ingress_endpoint"

  project_id        = var.project_id
  address_name      = "${local.name_prefix}-argocd-ingress"
  domain_name       = local.argocd_domain_name
  route53_zone_id   = var.route53_zone_id
  route53_zone_name = var.route53_zone_name
}

resource "google_service_account_iam_member" "wi_eso_argocd" {
  service_account_id = module.wi_eso.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[argocd/${var.eso_k8s_service_account}]"
}

resource "google_secret_manager_secret" "argocd_repo_ssh" {
  project   = var.project_id
  secret_id = "orders${var.name_suffix}-argocd-repo-ssh-key"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "argocd_repo_ssh_eso" {
  for_each = local.eso_accessor_members

  project   = var.project_id
  secret_id = google_secret_manager_secret.argocd_repo_ssh.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}

resource "google_secret_manager_secret" "argocd_google_oauth" {
  project   = var.project_id
  secret_id = "orders${var.name_suffix}-argocd-google-oauth"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "argocd_google_oauth_eso" {
  for_each = local.eso_accessor_members

  project   = var.project_id
  secret_id = google_secret_manager_secret.argocd_google_oauth.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}

module "observability_gcp" {
  source = "../../modules/observability_gcp"

  project_id    = var.project_id
  name_prefix   = local.name_prefix
  environment   = var.cluster_name
  k8s_namespace = var.k8s_namespace
  alert_email   = var.alert_email
  uptime_host   = var.domain_name

  depends_on = [module.gke]
}

module "secret_grafana" {
  count  = var.grafana_otlp_endpoint != "" && var.grafana_api_token != "" ? 1 : 0
  source = "../../modules/secret_manager"

  project_id = var.project_id
  secret_id  = "orders${var.name_suffix}-grafana-cloud"
  secret_data = jsonencode({
    endpoint    = var.grafana_otlp_endpoint
    instance_id = var.grafana_instance_id
    api_token   = var.grafana_api_token
  })
  accessor_members = local.eso_accessor_members
}
