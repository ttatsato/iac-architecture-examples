variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "Region for the VPC, subnet, and static IP."
  type        = string
  default     = "asia-northeast1"
}

variable "zone" {
  description = "Zone for the GCE VM."
  type        = string
  default     = "asia-northeast1-a"
}

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
  default     = "cf-proxy"
}

variable "machine_type" {
  description = "GCE machine type. e2-micro is enough for ~50 light proxy users."
  type        = string
  default     = "e2-micro"
}

variable "subnet_cidr" {
  description = "CIDR for the proxy subnet. Routed to WARP via Cloudflare Tunnel Private Network."
  type        = string
  default     = "10.10.0.0/24"
}

variable "vendor_primary_domains" {
  description = <<-EOT
    Primary domains of the target service (e.g. the eKYC vendor's management UI).
    These are the domains the business actually needs to reach — what auditors
    care about.
    Use exact domain ("admin.vendor.com") for exact match, or leading dot
    (".vendor.com") to also allow subdomains.
  EOT
  type        = list(string)
}

variable "vendor_asset_domains" {
  description = <<-EOT
    CDN / font / analytics / error-tracking domains the vendor's SPA loads.
    Without these the management UI may fail to render.
    Discover them via browser DevTools → Network → "Domain" column.
    Kept separate from vendor_primary_domains so audit reviewers can see
    which entries are core dependencies vs. derivative asset hosts.
  EOT
  type        = list(string)
  default     = []
}

variable "cloudflare_tunnel_token" {
  description = "Tunnel token issued in the Cloudflare Zero Trust dashboard. Stored in Secret Manager, not in plain VM metadata."
  type        = string
  sensitive   = true
}

variable "audit_log_retention_days" {
  description = "Retention period for the dedicated audit log bucket. eKYC and similar regulated workflows commonly require 365+ days."
  type        = number
  default     = 400
}

variable "enable_iap_ssh" {
  description = <<-EOT
    Open SSH (TCP/22) to GCP IAP's range (35.235.240.0/20) for debugging.
    Off by default: the production path is cloudflared dialing out, so the VM
    has no public ingress. Turn on temporarily to inspect startup-script and
    container logs via `gcloud compute ssh --tunnel-through-iap`.
  EOT
  type        = bool
  default     = false
}
