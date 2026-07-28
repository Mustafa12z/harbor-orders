output "email" {
  value = google_service_account.gsa.email
}

output "name" {
  value = google_service_account.gsa.name
}

output "k8s_annotation" {
  value = {
    "iam.gke.io/gcp-service-account" = google_service_account.gsa.email
  }
}
