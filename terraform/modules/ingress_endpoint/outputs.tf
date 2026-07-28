output "ingress_ip" {
  value = google_compute_global_address.ingress.address
}

output "ingress_ip_name" {
  value = google_compute_global_address.ingress.name
}

output "domain_name" {
  value = trimsuffix(var.domain_name, ".")
}

output "dns_record_name" {
  value = aws_route53_record.app.fqdn
}

output "route53_zone_id" {
  value = local.route53_zone_id
}
