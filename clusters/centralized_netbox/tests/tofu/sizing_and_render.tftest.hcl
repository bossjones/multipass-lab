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

  # Bootstrap also creates a default DCIM site so devices can be added (NetBox requires a site
  # before any device). See specs/centralized_netbox.md.
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/sites/")
    error_message = "bootstrap must create a default DCIM site"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"slug\":\"multipass-lab\"")
    error_message = "bootstrap must create the default site with its slug"
  }
}

run "server_seeds_base_data_model" {
  command = plan

  # Organization hierarchy: region + site group + location + tenant, attached to the site.
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/regions/")
    error_message = "seed must create a DCIM region"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/site-groups/")
    error_message = "seed must create a DCIM site group"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/locations/")
    error_message = "seed must create a DCIM location"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/tenancy/tenants/")
    error_message = "seed must create a tenant"
  }

  # DCIM library: manufacturers + platform + device roles + device types.
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/manufacturers/")
    error_message = "seed must create a manufacturer"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/platforms/")
    error_message = "seed must create a platform"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/device-roles/")
    error_message = "seed must create device roles"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/device-types/")
    error_message = "seed must create a device type"
  }

  # Rack chain: rack role + rack type (new in NetBox 4.1) + rack.
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/rack-roles/")
    error_message = "seed must create a rack role"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/rack-types/")
    error_message = "seed must create a rack type (4.1 feature)"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/racks/")
    error_message = "seed must create a rack"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "multipass-rack-1")
    error_message = "seed must create the named rack"
  }

  # The headline: a real DCIM Device for the Multipass host so /dcim/devices/ is populated.
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/dcim/devices/")
    error_message = "seed must create a DCIM device (the Multipass host)"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "multipass-host")
    error_message = "seed must create the host device by name"
  }

  # IPAM: RIR (RFC1918) + aggregate + prefix + vlan, with the prefix derived from the live subnet.
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/ipam/rirs/")
    error_message = "seed must create an RIR"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/ipam/aggregates/")
    error_message = "seed must create an aggregate"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/ipam/prefixes/")
    error_message = "seed must create a prefix"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/ipam/vlans/")
    error_message = "seed must create a vlan"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "$${SERVER_IP%.*}.0/24")
    error_message = "seed must derive the prefix from the server's runtime IP"
  }

  # Tenancy contact assigned to the site.
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/tenancy/contacts/")
    error_message = "seed must create a contact"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "/api/tenancy/contact-assignments/")
    error_message = "seed must assign the contact to the site"
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

  # The client links its VM to the seeded host Device (resolves it by name, includes "device").
  assert {
    condition     = strcontains(local_file.client_ci.content, "/api/dcim/devices/?name=$HOST_DEVICE")
    error_message = "client must look up the host device to link its VM to it"
  }
  assert {
    condition     = strcontains(local_file.client_ci.content, "HOST_DEVICE=\"multipass-host\"")
    error_message = "client must carry the host device name"
  }
  assert {
    condition     = strcontains(local_file.client_ci.content, "\\\"device\\\":$HOST_ID")
    error_message = "client must include the device link in its VM payload"
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

# --- Netdata (real-time agent on both VMs, dashboard-only — no local Prometheus) -------

run "netdata_renders_by_default" {
  command = plan

  # Installs on BOTH VMs, telemetry opted out, and surfaced in enabled_features.
  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.client_ci.content,
    ] : strcontains(c, "netdata-kickstart.sh")])
    error_message = "netdata kickstart install block must render on both VMs by default"
  }
  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.client_ci.content,
    ] : strcontains(c, ".opt-out-from-anonymous-statistics")])
    error_message = "netdata install must drop the anonymous-statistics opt-out file on both VMs"
  }
  assert {
    condition     = output.enabled_features.netdata == true
    error_message = "enabled_features.netdata must be true by default"
  }
  # The gated install block must keep the cloud-init valid YAML.
  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.client_ci.content,
    ] : can(yamldecode(c))])
    error_message = "rendered cloud-init must stay valid YAML with netdata enabled"
  }
}

run "netdata_off_omits_install" {
  command = plan

  variables {
    enable_netdata = false
  }

  assert {
    condition = alltrue([for c in [
      local_file.server_ci.content, local_file.client_ci.content,
    ] : !strcontains(c, "netdata-kickstart.sh")])
    error_message = "disabling netdata must omit the kickstart install block from both VMs"
  }
  assert {
    condition     = output.enabled_features.netdata == false
    error_message = "enabled_features.netdata must be false when disabled"
  }
}
