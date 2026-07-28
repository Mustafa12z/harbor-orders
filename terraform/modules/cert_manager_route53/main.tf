# IAM user + access key for cert-manager DNS-01 against a single Route53 zone.
# Keys are written to GSM so ESO can sync them into the cert-manager namespace.

data "aws_caller_identity" "current" {}

locals {
  tags = merge(
    {
      Project     = "harbor-orders"
      Environment = var.environment
      ManagedBy   = "terraform"
      Component   = "cert-manager"
    },
    var.extra_tags,
  )
}

resource "aws_iam_user" "cert_manager" {
  name = var.iam_user_name
  path = "/harbor-orders/"
  tags = local.tags
}

resource "aws_iam_user_policy" "route53" {
  name = "route53-dns01"
  user = aws_iam_user.cert_manager.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:GetChange"]
        Resource = ["arn:aws:route53:::change/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
        ]
        Resource = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]
      },
      {
        Effect = "Allow"
        Action = [
          "route53:ListHostedZones",
          "route53:ListHostedZonesByName",
        ]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_access_key" "cert_manager" {
  user = aws_iam_user.cert_manager.name
}

resource "google_secret_manager_secret" "route53" {
  project   = var.project_id
  secret_id = var.gsm_secret_id

  replication {
    auto {}
  }

  labels = {
    environment = var.environment
    component   = "cert-manager"
  }
}

resource "google_secret_manager_secret_version" "route53" {
  secret = google_secret_manager_secret.route53.id
  secret_data = jsonencode({
    access_key_id     = aws_iam_access_key.cert_manager.id
    secret_access_key = aws_iam_access_key.cert_manager.secret
    region            = var.aws_region
  })
}

resource "google_secret_manager_secret_iam_member" "accessors" {
  for_each = var.accessor_members

  project   = var.project_id
  secret_id = google_secret_manager_secret.route53.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value
}
