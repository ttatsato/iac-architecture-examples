resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "${var.name_prefix}-subnet"
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  # VPC Flow Logs: independent network-level evidence of who connected
  # to where and when. Auditors typically expect this for regulated
  # egress paths (eKYC, payments, etc.).
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_address" "static_ip" {
  name   = "${var.name_prefix}-egress-ip"
  region = var.region
}

# No ingress allow rules: cloudflared dials Cloudflare from the inside,
# so nothing needs to reach this VM from the internet.
# Default GCP rule denies all ingress.

# Egress hardening: deny everything except the ports the VM actually uses.
# Lower priority number = evaluated first.
resource "google_compute_firewall" "egress_allowed" {
  name      = "${var.name_prefix}-egress-allowed"
  network   = google_compute_network.vpc.name
  direction = "EGRESS"
  priority  = 1000

  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = [google_service_account.vm.email]

  # 80/443: Squid → target URL, Docker pulls, googleapis.com (Secret Manager)
  # 7844:   cloudflared → Cloudflare edge (HTTP/2 and QUIC)
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "7844"]
  }

  allow {
    protocol = "udp"
    ports    = ["53", "7844"]
  }
}

resource "google_compute_firewall" "egress_deny_rest" {
  name      = "${var.name_prefix}-egress-deny-rest"
  network   = google_compute_network.vpc.name
  direction = "EGRESS"
  priority  = 65000

  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = [google_service_account.vm.email]

  deny {
    protocol = "all"
  }
}
