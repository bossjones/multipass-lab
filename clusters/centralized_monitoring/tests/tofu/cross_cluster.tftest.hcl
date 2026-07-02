# Layer 0/1 hermetic test — cross-cluster scraping (specs/cross-cluster.md).
# Asserts that extra_scrape_targets render into prometheus.yml as static-config jobs.

mock_provider "multipass" {
  mock_resource "multipass_instance" {
    defaults = {
      ipv4 = "10.99.99.99"
    }
  }
}

variables {
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-monitoring-tests"
}

# --- default: no cross-cluster jobs -----------------------------------------
run "no_extra_targets_by_default" {
  command = plan

  assert {
    condition     = !strcontains(local_file.server_ci.content, "cross-cluster:")
    error_message = "with extra_scrape_targets empty, prometheus.yml must not gain cross-cluster jobs"
  }
}

# --- with targets: one job per entry, pointing at ip:port -------------------
run "extra_targets_render_jobs" {
  command = plan

  variables {
    extra_scrape_targets = [
      { job = "centralized-pki-ca", ip = "10.20.0.5" },
      { job = "centralized-pki-services", ip = "10.20.0.6", port = 9256 },
    ]
  }

  assert {
    condition     = strcontains(local_file.server_ci.content, "job_name: centralized-pki-ca")
    error_message = "prometheus.yml must contain a job for each cross-cluster target"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"10.20.0.5:9100\"")
    error_message = "cross-cluster target must default to port 9100"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"10.20.0.6:9256\"")
    error_message = "cross-cluster target must honor an explicit port"
  }
}
