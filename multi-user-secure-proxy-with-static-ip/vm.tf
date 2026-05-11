resource "google_compute_instance" "vm" {
  name         = "${var.name_prefix}-vm"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      # Container-Optimized OS: small, hardened, ships Docker.
      image = "projects/cos-cloud/global/images/family/cos-stable"
      size  = 10
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id

    access_config {
      nat_ip = google_compute_address.static_ip.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin = "TRUE"

    startup-script = templatefile("${path.module}/templates/startup.sh.tftpl", {
      project_id             = var.project_id
      tunnel_token_secret_id = google_secret_manager_secret.tunnel_token.secret_id
      squid_conf = templatefile("${path.module}/templates/squid.conf.tftpl", {
        vendor_primary_domains = var.vendor_primary_domains
        vendor_asset_domains   = var.vendor_asset_domains
      })
    })
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # Make sure secret access is granted before the VM boots and tries to fetch the token.
  depends_on = [
    google_secret_manager_secret_iam_member.vm_access,
    google_secret_manager_secret_version.tunnel_token,
  ]
}
