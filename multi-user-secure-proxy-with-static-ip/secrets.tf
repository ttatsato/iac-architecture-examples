resource "google_secret_manager_secret" "tunnel_token" {
  secret_id = "${var.name_prefix}-tunnel-token"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "tunnel_token" {
  secret      = google_secret_manager_secret.tunnel_token.id
  secret_data = var.cloudflare_tunnel_token
}

resource "google_secret_manager_secret_iam_member" "vm_access" {
  secret_id = google_secret_manager_secret.tunnel_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm.email}"
}
