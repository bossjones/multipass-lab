# Layer 0/1 hermetic test — the `dns_records` output consumed by `just set-dns`.
# mock_provider means no Multipass is touched; command = plan. The record KEYS are derived
# from var.domain (known at plan), so we assert on keys without needing real VM IPs.

mock_provider "multipass" {}

variables {
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-pki-tests"
}

run "dns_records_expose_service_hostnames" {
  command = plan

  assert {
    condition     = contains(keys(output.dns_records), "auth.lab.theblacktonystark.com")
    error_message = "dns_records must include auth.<domain>"
  }
  assert {
    condition     = contains(keys(output.dns_records), "warden.lab.theblacktonystark.com")
    error_message = "dns_records must include warden.<domain>"
  }
  assert {
    condition     = contains(keys(output.dns_records), "ca.lab.theblacktonystark.com")
    error_message = "dns_records must include ca.<domain>"
  }
  assert {
    condition     = contains(keys(output.dns_records), "traefik.lab.theblacktonystark.com")
    error_message = "dns_records must include traefik.<domain>"
  }
}

run "dns_records_honor_domain_override" {
  command = plan

  variables {
    domain = "example.test"
  }

  assert {
    condition     = contains(keys(output.dns_records), "auth.example.test")
    error_message = "dns_records keys must be built from var.domain"
  }
}
