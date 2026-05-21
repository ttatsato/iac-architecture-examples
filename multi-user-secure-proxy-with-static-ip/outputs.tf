output "static_egress_ip" {
  description = "Public egress IP of the proxy. Register this with the partner's allowlist."
  value       = google_compute_address.static_ip.address
}

output "vm_internal_ip" {
  description = "Internal IP of the proxy VM. WARP users reach Squid here at port 3128 via the Tunnel Private Network."
  value       = google_compute_instance.vm.network_interface[0].network_ip
}

output "vpc_cidr" {
  description = "CIDR to register as a Tunnel Private Network route in the Cloudflare dashboard."
  value       = var.subnet_cidr
}

output "tunnel_token_secret_id" {
  description = "Secret Manager secret holding the Cloudflare Tunnel token."
  value       = google_secret_manager_secret.tunnel_token.secret_id
}

output "audit_log_bucket" {
  description = "Cloud Logging bucket retaining proxy VM logs for audit. Use Logs Explorer with this bucket as scope."
  value       = google_logging_project_bucket_config.audit.bucket_id
}
