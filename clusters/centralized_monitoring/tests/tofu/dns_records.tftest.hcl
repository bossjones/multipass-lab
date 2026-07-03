# Layer 0/1 hermetic test — the `dns_records` output consumed by `just set-dns`.
# mock_provider means no Multipass is touched; command = plan. The record KEYS are derived
# from var.domain (known at plan), so we assert on keys without needing real VM IPs.

mock_provider "multipass" {}

variables {
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-monitoring-tests"
}

run "dns_records_expose_service_hostnames" {
  command = plan

  assert {
    condition     = contains(keys(output.dns_records), "grafana.lab.theblacktonystark.com")
    error_message = "dns_records must include grafana.<domain>"
  }
  assert {
    condition     = contains(keys(output.dns_records), "prometheus.lab.theblacktonystark.com")
    error_message = "dns_records must include prometheus.<domain>"
  }
  assert {
    condition     = contains(keys(output.dns_records), "openobserve.lab.theblacktonystark.com")
    error_message = "dns_records must include openobserve.<domain>"
  }
}

run "dns_records_honor_domain_override" {
  command = plan

  variables {
    domain = "example.test"
  }

  assert {
    condition     = contains(keys(output.dns_records), "grafana.example.test")
    error_message = "dns_records keys must be built from var.domain"
  }
}
