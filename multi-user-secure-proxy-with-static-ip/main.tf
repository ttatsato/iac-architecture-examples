// =====================================================================
// Inputs
// =====================================================================

variable "vendor_host" {
  type        = string
  description = "eKYC ベンダー管理画面のホスト名 (例: admin.ekyc-vendor.com)"
}

variable "gateway_host" {
  type        = string
  description = "オペレータが Chrome で開く自社ゲートウェイのホスト名 (例: ekyc-gw.our-org.com)。Google-managed SSL cert もこのホストで発行する。"
}

variable "iap_members" {
  type        = list(string)
  description = "IAP 経由のアクセスを許可する Workspace ID。形式は user:foo@bar.com / group:ops@bar.com"
}

variable "iap_tunnel_members" {
  type        = list(string)
  description = "IAP TCP tunnel (SSH) を使える運用者の Workspace ID。空なら誰も SSH 不可。形式は iap_members と同じ。"
  default     = []
}

variable "iap_oauth_client_id" {
  type        = string
  description = "IAP backend service にひも付ける OAuth client ID。GCP Console > Security > IAP の OAuth consent screen 設定後に作成して指定する。"
  sensitive   = true
}

variable "iap_oauth_client_secret" {
  type        = string
  description = "IAP backend service にひも付ける OAuth client secret。"
  sensitive   = true
}

// =====================================================================
// Locals
// =====================================================================

locals {
  nginx_conf = templatefile("${path.module}/nginx.conf.tmpl", {
    vendor_host  = var.vendor_host
    gateway_host = var.gateway_host
  })
}

// =====================================================================
// API enablement
// =====================================================================

resource "google_project_service" "compute_api" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iap_api" {
  service            = "iap.googleapis.com"
  disable_on_destroy = false
}

// =====================================================================
// Egress: Cloud NAT で固定 IP egress
//   - VM は外部 IP を持たない (defense-in-depth)
//   - 全 egress は Cloud NAT を通り、ベンダー allowlist 登録対象の static IP で出る
// =====================================================================

resource "google_compute_address" "proxy_ip" {
  name       = "proxy-egress-ip"
  region     = "asia-northeast1"
  depends_on = [google_project_service.compute_api]
}

resource "google_compute_router" "egress_router" {
  name    = "egress-router"
  region  = "asia-northeast1"
  network = "default"
}

resource "google_compute_router_nat" "egress_nat" {
  name                               = "egress-nat"
  router                             = google_compute_router.egress_router.name
  region                             = "asia-northeast1"
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.proxy_ip.self_link]
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

// =====================================================================
// Reverse proxy VM (nginx in Docker)
// =====================================================================

resource "google_compute_instance" "proxy" {
  name         = "proxy-server"
  machine_type = "e2-micro"
  zone         = "asia-northeast1-a"
  tags         = ["reverse-proxy-backend"]
  depends_on   = [google_project_service.compute_api]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    network    = "default"
    subnetwork = "default"
    // 外部 IP は持たない。Egress は Cloud NAT 経由で proxy_ip から出る。
    // Ingress は LB ヘルスチェック範囲 → 8080、IAP TCP tunnel 範囲 → 22 のみ FW 許可。
  }

  metadata_startup_script = templatefile("${path.module}/startup.sh.tmpl", {
    image      = "nginx:alpine"
    nginx_conf = local.nginx_conf
  })
}

// VM を backend service に組み込むための instance group
resource "google_compute_instance_group" "proxy_ig" {
  name      = "reverse-proxy-ig"
  zone      = "asia-northeast1-a"
  instances = [google_compute_instance.proxy.self_link]

  named_port {
    name = "http"
    port = 8080
  }
}

// =====================================================================
// Firewall: GCP LB ヘルスチェック / プロキシレンジ → VM:8080 のみ許可
// =====================================================================

resource "google_compute_firewall" "lb_to_backend" {
  name        = "allow-lb-to-backend-8080"
  network     = "default"
  description = "Google L7 LB のヘルスチェック・プロキシレンジから backend VM への 8080 のみ許可。それ以外の ingress は default deny。"

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = [
    "130.211.0.0/22", // GCP LB / health check
    "35.191.0.0/16",  // GCP LB / health check
  ]

  target_tags = ["reverse-proxy-backend"]
  depends_on  = [google_project_service.compute_api]
}

// IAP TCP tunnel 経由の SSH のみ許可。VM は外部 IP を持たないので
// `gcloud compute ssh --tunnel-through-iap` でしか到達できない。
resource "google_compute_firewall" "iap_ssh" {
  name        = "allow-iap-tunnel-ssh"
  network     = "default"
  description = "IAP TCP tunnel 範囲から VM:22 のみ許可。運用者の SSH 専用経路。"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"] // IAP TCP forwarding range
  target_tags   = ["reverse-proxy-backend"]
  depends_on    = [google_project_service.iap_api]
}

// =====================================================================
// L7 HTTPS Load Balancer
// =====================================================================

resource "google_compute_global_address" "lb_ip" {
  name = "reverse-proxy-lb-ip"
}

resource "google_compute_health_check" "proxy_hc" {
  name = "reverse-proxy-hc"

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }

  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_backend_service" "proxy_backend" {
  name                  = "reverse-proxy-backend"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 60
  health_checks         = [google_compute_health_check.proxy_hc.id]

  backend {
    group = google_compute_instance_group.proxy_ig.id
  }

  iap {
    enabled              = true
    oauth2_client_id     = var.iap_oauth_client_id
    oauth2_client_secret = var.iap_oauth_client_secret
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  depends_on = [google_project_service.iap_api]
}

resource "google_compute_url_map" "proxy_urlmap" {
  name            = "reverse-proxy-urlmap"
  default_service = google_compute_backend_service.proxy_backend.id
}

resource "google_compute_managed_ssl_certificate" "proxy_cert" {
  name = "reverse-proxy-cert"
  managed {
    domains = [var.gateway_host]
  }
}

resource "google_compute_target_https_proxy" "proxy_https" {
  name             = "reverse-proxy-https"
  url_map          = google_compute_url_map.proxy_urlmap.id
  ssl_certificates = [google_compute_managed_ssl_certificate.proxy_cert.id]
}

resource "google_compute_global_forwarding_rule" "proxy_fr" {
  name                  = "reverse-proxy-fr"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.lb_ip.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.proxy_https.id
}

// =====================================================================
// IAP IAM: 許可ユーザ/グループに roles/iap.httpsResourceAccessor 付与
// =====================================================================

resource "google_iap_web_backend_service_iam_member" "members" {
  for_each            = toset(var.iap_members)
  web_backend_service = google_compute_backend_service.proxy_backend.name
  role                = "roles/iap.httpsResourceAccessor"
  member              = each.value
}

// IAP TCP tunnel (SSH) の利用者
resource "google_iap_tunnel_instance_iam_member" "ssh_members" {
  for_each = toset(var.iap_tunnel_members)
  zone     = google_compute_instance.proxy.zone
  instance = google_compute_instance.proxy.name
  role     = "roles/iap.tunnelResourceAccessor"
  member   = each.value
}

// =====================================================================
// Outputs
// =====================================================================

output "lb_ip_address" {
  description = "ゲートウェイの公開 IP。DNS A レコードで var.gateway_host をこの IP に向ける。"
  value       = google_compute_global_address.lb_ip.address
}

output "egress_static_ip" {
  description = "VM から外向き通信が出ていく static IP。ベンダーの allowlist にこれを登録する。"
  value       = google_compute_address.proxy_ip.address
}
