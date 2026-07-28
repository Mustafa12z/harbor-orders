resource "google_secret_manager_secret" "secret" {
  project   = var.project_id
  secret_id = var.secret_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "version" {
  secret      = google_secret_manager_secret.secret.id
  secret_data = var.secret_data
}

# Accessor grants are scoped to this individual secret rather than the project,
# so the External Secrets Operator identity for one environment cannot read
# another environment's secrets even though they share a project.
resource "google_secret_manager_secret_iam_member" "accessors" {
  for_each = var.accessor_members

  project   = var.project_id
  secret_id = google_secret_manager_secret.secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
