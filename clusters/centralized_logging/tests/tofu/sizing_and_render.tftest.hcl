# Layer 0/1 hermetic test — runs with `tofu test -test-directory=tests/tofu`.
# mock_provider means no Multipass is touched; command = plan asserts on rendered values.

mock_provider "multipass" {}

variables {
  # Provide an inline key so the test never depends on a real ~/.ssh file.
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-logging-tests"
}

run "sizing_image_names_and_central_render" {
  command = plan

  # --- sizing -------------------------------------------------------------
  assert {
    condition     = multipass_instance.central.cpus == 2
    error_message = "central cpus should be 2"
  }
  assert {
    condition     = multipass_instance.central.memory == "2G"
    error_message = "central memory should be 2G"
  }
  assert {
    condition     = multipass_instance.central.disk == "40G"
    error_message = "central disk should be 40G"
  }
  assert {
    condition     = multipass_instance.k0s.memory == "2G"
    error_message = "k0s memory should be 2G"
  }
  assert {
    condition     = multipass_instance.docker.memory == "4G"
    error_message = "docker memory should be 4G"
  }

  # --- image + names ------------------------------------------------------
  assert {
    condition     = multipass_instance.central.image == "24.04"
    error_message = "image should be 24.04"
  }
  assert {
    condition     = multipass_instance.central.name == "centralized-logging-central"
    error_message = "central name should carry the name_prefix"
  }
  assert {
    condition     = multipass_instance.k0s.name == "centralized-logging-k0s"
    error_message = "k0s name should carry the name_prefix"
  }
  assert {
    condition     = multipass_instance.docker.name == "centralized-logging-docker"
    error_message = "docker name should carry the name_prefix"
  }

  # --- central cloud-init carries the syslog-ng server config -------------
  assert {
    condition     = strcontains(local_file.central_ci.content, "/var/log/remote")
    error_message = "central cloud-init must contain the syslog-ng file sink path"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "transport(\"tcp\")")
    error_message = "central cloud-init must contain the syslog-ng TCP network source"
  }
  assert {
    condition     = strcontains(local_file.central_ci.content, "ssh-ed25519 AAAATESTKEY")
    error_message = "central cloud-init must inject the SSH public key"
  }
}
