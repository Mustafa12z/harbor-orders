resource "google_container_cluster" "autopilot" {
  # checkov:skip=CKV_GCP_12: Autopilot uses Dataplane V2 (NetworkPolicy built-in); network_policy block is unsupported with enable_autopilot
  # checkov:skip=CKV_GCP_61: enable_intranode_visibility conflicts with enable_autopilot; subnet VPC flow logs cover the network side
  # checkov:skip=CKV_GCP_65: Google Groups for GKE RBAC is optional; not used in this personal project
  # checkov:skip=CKV_GCP_66: Binary Authorization intentionally not used (complexity vs value for this project)
  # checkov:skip=CKV_GCP_69: Autopilot enables the metadata server with Workload Identity; node_config is not set on Autopilot clusters
  provider = google-beta

  project  = var.project_id
  name     = var.name
  location = var.location

  enable_autopilot = true

  # Explicit Dataplane V2 (Autopilot default); NetworkPolicy is enforced by the dataplane.
  datapath_provider = "ADVANCED_DATAPATH"

  resource_labels = var.resource_labels

  network    = var.network
  subnetwork = var.subnetwork

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  release_channel {
    channel = var.release_channel
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.master_authorized_cidrs
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  deletion_protection = var.deletion_protection

  # Autopilot manages node pools; vertical pod autoscaling is enabled by default.
}
