resource "google_monitoring_notification_channel" "email" {
  count = var.alert_email != "" ? 1 : 0

  project      = var.project_id
  display_name = "${var.name_prefix}-${var.environment}-email"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

resource "google_logging_metric" "orders_errors" {
  project = var.project_id
  name    = "${var.name_prefix}_${var.environment}_k8s_errors"
  filter  = <<-EOT
    resource.type="k8s_container"
    resource.labels.namespace_name="${var.k8s_namespace}"
    severity>=ERROR
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
    labels {
      key         = "container_name"
      value_type  = "STRING"
      description = "Container that emitted the error"
    }
  }

  label_extractors = {
    container_name = "EXTRACT(resource.labels.container_name)"
  }
}

resource "google_monitoring_uptime_check_config" "https" {
  count = var.uptime_host != "" ? 1 : 0

  project      = var.project_id
  display_name = "${var.name_prefix}-${var.environment}-https"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = var.uptime_path
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = var.uptime_host
    }
  }
}

resource "google_monitoring_alert_policy" "uptime" {
  count = var.uptime_host != "" && var.alert_email != "" ? 1 : 0

  project      = var.project_id
  display_name = "${var.name_prefix}-${var.environment}-uptime-failed"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Uptime check failing for ${var.uptime_host}"

    condition_threshold {
      filter          = <<-EOT
        resource.type = "uptime_url"
        metric.type = "monitoring.googleapis.com/uptime_check/check_passed"
        metric.label.check_id = "${google_monitoring_uptime_check_config.https[0].uptime_check_id}"
      EOT
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 1

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]

  documentation {
    content   = "Uptime check to https://${var.uptime_host}${var.uptime_path} is failing. Check Ingress, ManagedCertificate, and pods in namespace ${var.k8s_namespace}."
    mime_type = "text/markdown"
  }

  user_labels = {
    environment = var.environment
    system      = var.name_prefix
  }
}

# Log-based metrics can take several minutes to appear in Monitoring before
# alert policies that reference them can be created.
resource "time_sleep" "wait_for_log_metric" {
  count = var.alert_email != "" ? 1 : 0

  depends_on      = [google_logging_metric.orders_errors]
  create_duration = "180s"
}

resource "google_monitoring_alert_policy" "k8s_errors" {
  count = var.alert_email != "" ? 1 : 0

  depends_on = [time_sleep.wait_for_log_metric]

  project      = var.project_id
  display_name = "${var.name_prefix}-${var.environment}-k8s-errors"
  combiner     = "OR"
  enabled      = true

  conditions {
    display_name = "Elevated ERROR logs in ${var.k8s_namespace}"

    condition_threshold {
      filter          = <<-EOT
        resource.type = "k8s_container"
        metric.type = "logging.googleapis.com/user/${google_logging_metric.orders_errors.name}"
      EOT
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 20

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email[0].id]

  documentation {
    content   = "ERROR-or-higher log volume is elevated in namespace ${var.k8s_namespace}. Check Cloud Logging and Grafana traces."
    mime_type = "text/markdown"
  }

  user_labels = {
    environment = var.environment
    system      = var.name_prefix
  }
}
