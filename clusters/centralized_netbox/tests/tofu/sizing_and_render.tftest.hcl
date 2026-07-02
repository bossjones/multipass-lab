# Layer 0/1 hermetic test — runs with `tofu test -test-directory=tests/tofu`.
# mock_provider means no Multipass is touched; command = plan asserts on rendered values.

mock_provider "multipass" {}

variables {
  # Provide an inline key so the test never depends on a real ~/.ssh file.
  ssh_pubkey = "ssh-ed25519 AAAATESTKEY centralized-netbox-tests"
}

run "sizing_image_and_names" {
  command = plan

  # --- sizing -------------------------------------------------------------
  assert {
    condition     = multipass_instance.server.cpus == 2
    error_message = "server cpus should be 2"
  }
  assert {
    condition     = multipass_instance.server.memory == "4G"
    error_message = "server memory should be 4G (netbox-docker is heavy)"
  }
  assert {
    condition     = multipass_instance.server.disk == "20G"
    error_message = "server disk should be 20G"
  }
  assert {
    condition     = multipass_instance.client.cpus == 1
    error_message = "client cpus should be 1"
  }
  assert {
    condition     = multipass_instance.client.memory == "1G"
    error_message = "client memory should be 1G (tiny test VM)"
  }

  # --- image + names ------------------------------------------------------
  assert {
    condition     = multipass_instance.server.image == "24.04"
    error_message = "image should be 24.04"
  }
  assert {
    condition     = multipass_instance.server.name == "centralized-netbox-server"
    error_message = "server name should carry the name_prefix"
  }
  assert {
    condition     = multipass_instance.client.name == "centralized-netbox-client"
    error_message = "client name should carry the name_prefix"
  }
}

run "server_cloud_init_deploys_netbox" {
  command = plan

  # netbox-docker is cloned + brought up, with the override published on :8000 -> container :8080.
  assert {
    condition     = strcontains(local_file.server_ci.content, "github.com/netbox-community/netbox-docker.git")
    error_message = "server cloud-init must clone netbox-docker"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "docker compose pull")
    error_message = "server cloud-init must bring the netbox-docker stack up with docker compose"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "docker-compose.override.yml")
    error_message = "server cloud-init must stage the netbox-docker override file"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "8000:8080")
    error_message = "override must publish NetBox on host :8000 -> container :8080"
  }

  # The admin user + pinned v1 API token are created via manage.py (deterministic, no reliance on
  # the image honoring env vars) so registration/verification authenticate against a known token.
  assert {
    condition     = strcontains(local_file.server_ci.content, "manage.py shell")
    error_message = "bootstrap must provision the admin user + token via manage.py"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "0123456789abcdef0123456789abcdef01234567")
    error_message = "bootstrap must carry the pinned lab API token"
  }

  # Bootstrap creates the virtualization cluster-type + cluster the client registers into.
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/virtualization/cluster-types/")
    error_message = "bootstrap must create a virtualization cluster-type"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/virtualization/clusters/")
    error_message = "bootstrap must create the virtualization cluster"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"slug\":\"multipass\"")
    error_message = "cluster-type slug must be derived from the type name (Multipass -> multipass)"
  }
}

run "client_cloud_init_self_registers" {
  command = plan

  # The register script authenticates with the pinned token and hits the VM/interface/IP endpoints.
  assert {
    condition     = strcontains(local_file.client_ci.content, "Authorization: Token")
    error_message = "client register script must authenticate with a NetBox API token"
  }
  assert {
    condition     = strcontains(local_file.client_ci.content, "0123456789abcdef0123456789abcdef01234567")
    error_message = "client register script must carry the pinned lab API token"
  }
  assert {
    condition     = strcontains(local_file.client_ci.content, "/api/virtualization/virtual-machines/")
    error_message = "client must register a virtual-machine object"
  }
  assert {
    condition     = strcontains(local_file.client_ci.content, "/api/virtualization/interfaces/")
    error_message = "client must register an eth0 interface"
  }
  assert {
    condition     = strcontains(local_file.client_ci.content, "/api/ipam/ip-addresses/")
    error_message = "client must register its primary IP address"
  }
  assert {
    condition     = strcontains(local_file.client_ci.content, "primary_ip4")
    error_message = "client must set the VM's primary_ip4"
  }
  assert {
    condition     = strcontains(local_file.client_ci.content, "netbox-register.service")
    error_message = "client must run registration via a systemd oneshot unit"
  }
  assert {
    condition     = strcontains(local_file.client_ci.content, "/var/lib/netbox-register/done")
    error_message = "client must drop a success marker for the testinfra suite"
  }
}

run "time_sync_on_both_vms" {
  command = plan

  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.client_ci.content,
    ] : strcontains(c, "timezone: Etc/UTC")])
    error_message = "every VM cloud-init must pin timezone: Etc/UTC"
  }
  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.client_ci.content,
    ] : strcontains(c, "ntp_client: systemd-timesyncd")])
    error_message = "every VM cloud-init must set the NTP client to systemd-timesyncd"
  }
  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.client_ci.content,
    ] : strcontains(c, "timedatectl set-timezone Etc/UTC")])
    error_message = "every VM cloud-init runcmd must enforce timezone Etc/UTC"
  }

  # The injected token/config must keep the cloud-init valid YAML.
  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.client_ci.content,
    ] : can(yamldecode(c))])
    error_message = "rendered cloud-init must be valid YAML"
  }
}

run "web_urls_core_and_all" {
  command = plan

  assert {
    condition     = length(output.web_urls.core) == 1
    error_message = "web_urls.core must list the single NetBox UI URL"
  }
  assert {
    condition     = length(output.web_urls.all) > length(output.web_urls.core)
    error_message = "web_urls.all must add the REST API root on top of core"
  }
  assert {
    condition     = output.registered_vm_name == "centralized-netbox-client"
    error_message = "registered_vm_name must be the client VM name"
  }
}
