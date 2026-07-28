data "google_project" "current" {
  project_id = var.project_id
}

resource "google_pubsub_topic" "dlq" {
  # checkov:skip=CKV_GCP_83: Google-managed encryption is intentional; CMEK/CSEK not required for this project
  project = var.project_id
  name    = var.dlq_topic_name
}

resource "google_pubsub_topic" "events" {
  # checkov:skip=CKV_GCP_83: Google-managed encryption is intentional; CMEK/CSEK not required for this project
  project = var.project_id
  name    = var.topic_name
}

resource "google_pubsub_subscription" "worker" {
  project = var.project_id
  name    = var.subscription_name
  topic   = google_pubsub_topic.events.name

  ack_deadline_seconds = 30

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dlq.id
    max_delivery_attempts = var.max_delivery_attempts
  }

  expiration_policy {
    ttl = "" # never expire
  }
}

# Pub/Sub service agent needs permission to publish to DLQ
resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dlq.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_subscription_iam_member" "dlq_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.worker.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
