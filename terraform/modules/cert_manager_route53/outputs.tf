output "iam_user_name" {
  value = aws_iam_user.cert_manager.name
}

output "gsm_secret_id" {
  value = google_secret_manager_secret.route53.secret_id
}

output "access_key_id" {
  value     = aws_iam_access_key.cert_manager.id
  sensitive = true
}
