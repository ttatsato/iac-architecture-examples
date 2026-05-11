# Ensure the Cloud Logging service identity exists before binding IAM. Projects
# often do not have service-{number}@gcp-sa-logging... until this API + identity
# step runs; binding a non-existent SA returns "does not exist".
resource "google_project_service" "logging_api" {
  project            = var.project_id
  service            = "logging.googleapis.com"
  disable_on_destroy = false
}

# Provisions the Logging service agent email used as the sink writer when
# unique_writer_identity is false (same-project log bucket exports).
resource "google_project_service_identity" "logging" {
  provider = google-beta

  project = var.project_id
  service = "logging.googleapis.com"

  depends_on = [google_project_service.logging_api]
}

# Used to derive the Logging service agent email
# (service-${number}@gcp-sa-logging.iam.gserviceaccount.com), because the
# `google_project_service_identity` resource in google-beta 5.x does not
# expose `email` / `member` reliably.
data "google_project" "this" {
  project_id = var.project_id
}

# Dedicated log bucket so proxy audit logs can be retained beyond the
# project's _Default bucket retention (30 days), which is rarely enough
# for regulated workflows like eKYC.
resource "google_logging_project_bucket_config" "audit" {
  project        = var.project_id
  location       = "global"
  retention_days = var.audit_log_retention_days
  bucket_id      = "${var.name_prefix}-audit"

  depends_on = [google_project_service.logging_api]
}

# Sink: copy proxy VM logs (Squid stdout, system logs) into the audit bucket.
# Logs still also land in _Default — the sink is additive.
resource "google_logging_project_sink" "audit" {
  name        = "${var.name_prefix}-audit-sink"
  project     = var.project_id
  destination = "logging.googleapis.com/projects/${var.project_id}/locations/${google_logging_project_bucket_config.audit.location}/buckets/${google_logging_project_bucket_config.audit.bucket_id}"

  filter = <<-EOT
    resource.type="gce_instance"
    resource.labels.instance_id="${google_compute_instance.vm.instance_id}"
  EOT

  # Shared Logging service agent (provisioned above). Avoids per-sink
  # writer_identity, which the provider often omits for log-bucket sinks and
  # breaks google_project_iam_member plan-time validation.
  unique_writer_identity = false

  depends_on = [
    google_project_service_identity.logging,
    google_logging_project_bucket_config.audit,
  ]
}

resource "google_project_iam_member" "audit_sink_writer" {
  project = var.project_id
  role    = "roles/logging.bucketWriter"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-logging.iam.gserviceaccount.com"

  depends_on = [google_project_service_identity.logging]
}
