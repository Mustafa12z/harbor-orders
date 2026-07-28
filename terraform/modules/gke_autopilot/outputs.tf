output "cluster_name" {
  value = google_container_cluster.autopilot.name
}

output "cluster_location" {
  value = google_container_cluster.autopilot.location
}

output "endpoint" {
  value     = google_container_cluster.autopilot.endpoint
  sensitive = true
}

output "ca_certificate" {
  value     = google_container_cluster.autopilot.master_auth[0].cluster_ca_certificate
  sensitive = true
}
