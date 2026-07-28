output "notification_channel_id" {
  value = try(google_monitoring_notification_channel.email[0].id, "")
}

output "uptime_check_id" {
  value = try(google_monitoring_uptime_check_config.https[0].uptime_check_id, "")
}

output "error_log_metric_name" {
  value = google_logging_metric.orders_errors.name
}
