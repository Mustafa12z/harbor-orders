output "topic_name" {
  value = google_pubsub_topic.events.name
}

output "topic_id" {
  value = google_pubsub_topic.events.id
}

output "subscription_name" {
  value = google_pubsub_subscription.worker.name
}

output "subscription_id" {
  value = google_pubsub_subscription.worker.id
}

output "dlq_topic_name" {
  value = google_pubsub_topic.dlq.name
}
