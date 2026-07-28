# Global static IP for GCE Ingress + ManagedCertificate.
resource "google_compute_global_address" "ingress" {
  project      = var.project_id
  name         = var.address_name
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

data "aws_route53_zone" "by_id" {
  count   = var.route53_zone_id != "" ? 1 : 0
  zone_id = var.route53_zone_id
}

data "aws_route53_zone" "by_name" {
  count        = var.route53_zone_id == "" ? 1 : 0
  name         = var.route53_zone_name
  private_zone = false
}

locals {
  route53_zone_id = var.route53_zone_id != "" ? data.aws_route53_zone.by_id[0].zone_id : data.aws_route53_zone.by_name[0].zone_id
}

resource "aws_route53_record" "app" {
  # checkov:skip=CKV2_AWS_23: A record targets a GCP global static IP for GCE Ingress, not an AWS alias resource
  zone_id = local.route53_zone_id
  name    = trimsuffix(var.domain_name, ".")
  type    = "A"
  ttl     = 300
  records = [google_compute_global_address.ingress.address]
}
