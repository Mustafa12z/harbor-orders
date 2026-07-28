output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "zone" {
  value = var.zone
}

output "cluster_name" {
  value = module.gke.cluster_name
}

output "cluster_location" {
  value = module.gke.cluster_location
}

output "get_credentials" {
  value = "gcloud container clusters get-credentials ${module.gke.cluster_name} --region ${module.gke.cluster_location} --project ${var.project_id}"
}

output "artifact_registry_url" {
  value = local.artifact_registry_url
}

output "pubsub_topic" {
  value = module.pubsub.topic_name
}

output "pubsub_subscription" {
  value = module.pubsub.subscription_name
}

output "pubsub_dlq_topic" {
  value = module.pubsub.dlq_topic_name
}

output "worker_gsa_email" {
  value = module.wi_worker.email
}

output "publisher_gsa_email" {
  value = module.wi_publisher.email
}

output "eso_gsa_email" {
  value       = module.wi_eso.email
  description = "GSA the External Secrets Operator impersonates; annotate the secret-reader KSA with this"
}

output "k8s_namespace" {
  value = var.k8s_namespace
}

output "network_name" {
  value = module.network.network_name
}

output "postgres_password" {
  value     = local.postgres_password
  sensitive = true
}

output "jwt_secret" {
  value     = local.jwt_secret
  sensitive = true
}

output "secret_manager_postgres" {
  value = module.secret_postgres.secret_id
}

output "secret_manager_jwt" {
  value = module.secret_jwt.secret_id
}

output "domain_name" {
  value = var.domain_name
}

output "ingress_ip" {
  value = try(module.ingress_endpoint[0].ingress_ip, "")
}

output "ingress_ip_name" {
  value = try(module.ingress_endpoint[0].ingress_ip_name, "")
}

output "grafana_secret_id" {
  value = try(module.secret_grafana[0].secret_id, "")
}

output "otel_environment" {
  value = var.cluster_name
}

# CI WIF identities are created out-of-band (docs/ci-oidc-bootstrap.md),
# not managed by Terraform.


