output "network_name" {
  value = google_compute_network.vpc.name
}

output "network_id" {
  value = google_compute_network.vpc.id
}

output "subnet_name" {
  value = google_compute_subnetwork.subnet.name
}

output "subnet_id" {
  value = google_compute_subnetwork.subnet.id
}

output "pods_range_name" {
  value = "pods"
}

output "services_range_name" {
  value = "services"
}

output "router_name" {
  value = google_compute_router.nat.name
}

output "nat_name" {
  value = google_compute_router_nat.nat.name
}
