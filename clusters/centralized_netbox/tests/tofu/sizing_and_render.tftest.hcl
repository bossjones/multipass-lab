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

# --- discovery: OFF (default) leaves the cluster untouched --------------------

run "discovery_off_no_wiring" {
  command = plan

  # No agent VM, no Diode/plugin strings, default server sizing + NetBox 4.1 pin.
  assert {
    condition     = length(multipass_instance.agent) == 0
    error_message = "no agent VM when enable_discovery is false"
  }
  assert {
    condition     = output.discovery_enabled == false
    error_message = "discovery_enabled must be false by default"
  }
  assert {
    condition     = multipass_instance.server.cpus == 2
    error_message = "server stays at default 2 vCPU when discovery is off"
  }
  assert {
    condition     = !strcontains(local_file.server_ci.content, "netbox_diode_plugin")
    error_message = "server cloud-init must NOT wire the Diode plugin when discovery is off"
  }
  assert {
    condition     = !strcontains(local_file.server_ci.content, "diode-ingester")
    error_message = "server cloud-init must NOT deploy the Diode stack when discovery is off"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "netbox-community/netbox-docker.git")
    error_message = "off-path still deploys netbox-docker unchanged"
  }
}

# --- discovery: ON wires the plugin + Diode + agent --------------------------

run "discovery_on_wires_everything" {
  command = plan

  variables {
    enable_discovery = true
  }

  # Server bumped to the heavier discovery footprint.
  assert {
    condition     = multipass_instance.server.cpus == 6
    error_message = "server must auto-bump to 6 vCPU when discovery is on"
  }
  assert {
    condition     = multipass_instance.server.memory == "10G"
    error_message = "server must auto-bump to 10G when discovery is on"
  }
  assert {
    condition     = multipass_instance.server.disk == "50G"
    error_message = "server must auto-bump to 50G when discovery is on"
  }

  # The agent VM exists and carries the cluster name.
  assert {
    condition     = length(multipass_instance.agent) == 1
    error_message = "exactly one agent VM when enable_discovery is true"
  }
  assert {
    condition     = multipass_instance.agent[0].name == "centralized-netbox-agent"
    error_message = "agent VM must carry the name_prefix"
  }

  # NetBox side: the plugin is installed + configured and the custom image is built.
  assert {
    condition     = strcontains(local_file.server_ci.content, "netbox_diode_plugin")
    error_message = "server must install + configure the diode-netbox-plugin"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "PLUGINS")
    error_message = "server must set PLUGINS/PLUGINS_CONFIG"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "Dockerfile-Plugins")
    error_message = "netbox-stack must generate a plugin Dockerfile"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "uv pip install")
    error_message = "plugin install must use uv (the netbox-docker image is uv-managed, no venv/bin/pip)"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "DOCKER_BUILDKIT=0 docker build")
    error_message = "plugin image must build with the legacy builder (docker.io ships no buildx)"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "migrate netbox_diode_plugin")
    error_message = "netbox-stack must run the plugin migrations"
  }

  # Diode server stack: services + pinned OAuth2 clients.
  assert {
    condition     = strcontains(local_file.server_ci.content, "diode-ingester")
    error_message = "Diode compose must include the ingester"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "diode-reconciler")
    error_message = "Diode compose must include the reconciler"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"client_id\": \"diode-ingest\"")
    error_message = "Diode credentials must include the diode-ingest client"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"client_id\": \"diode-to-netbox\"")
    error_message = "Diode credentials must include the diode-to-netbox client"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "\"client_id\": \"netbox-to-diode\"")
    error_message = "Diode credentials must include the netbox-to-diode client"
  }

  # Agent: orb-agent config targets Diode over gRPC and scans via network_discovery.
  assert {
    condition     = strcontains(local_file.agent_ci[0].content, "network_discovery")
    error_message = "agent must run the network_discovery backend"
  }
  assert {
    condition     = strcontains(local_file.agent_ci[0].content, ":8080/diode")
    error_message = "agent must target the Diode gRPC ingress on :8080/diode"
  }
  assert {
    condition     = strcontains(local_file.agent_ci[0].content, "diode-ingest")
    error_message = "agent must authenticate as the diode-ingest OAuth2 client"
  }
  assert {
    condition     = strcontains(local_file.agent_ci[0].content, "netboxlabs/orb-agent")
    error_message = "agent must run the orb-agent image"
  }
  assert {
    condition     = strcontains(local_file.agent_ci[0].content, "/var/lib/orb-agent/discovery-done")
    error_message = "agent must drop a readiness marker for testinfra"
  }

  # Rendered cloud-init must stay valid YAML with all the spliced Diode config.
  assert {
    condition     = can(yamldecode(local_file.server_ci.content))
    error_message = "discovery-on server cloud-init must be valid YAML"
  }
  assert {
    condition     = can(yamldecode(local_file.agent_ci[0].content))
    error_message = "agent cloud-init must be valid YAML"
  }

  # Outputs reflect discovery.
  assert {
    condition     = output.discovery_enabled == true
    error_message = "discovery_enabled must be true"
  }
  assert {
    condition     = output.diode_ingest_client_id == "diode-ingest"
    error_message = "diode_ingest_client_id output must be diode-ingest"
  }
  # web_urls.all = 2 (UI/API) + 6 exporter /metrics (node/process/systemd × server+client, all
  # default-on) + 1 Diode ingress URL (discovery on) = 9.
  assert {
    condition     = length(output.web_urls.all) == 9
    error_message = "web_urls.all must be the 2 UI/API URLs + 6 exporter /metrics + the Diode ingress URL when discovery is on"
  }
}

run "exporters_render_on_both_vms" {
  command = plan

  # The generic install-exporter.sh helper is bootstrapped on both VMs (this cluster had none).
  assert {
    condition     = strcontains(local_file.server_ci.content, "install-exporter.sh") && strcontains(local_file.client_ci.content, "install-exporter.sh")
    error_message = "the exporter installer helper must render on both VMs"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "node_exporter-1.8.2") && strcontains(local_file.client_ci.content, "node_exporter-1.8.2")
    error_message = "node_exporter must install on both VMs by default"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "process-exporter-0.8.7") && strcontains(local_file.server_ci.content, "-threads=false -gather-smaps=false -remove-empty-groups")
    error_message = "server must install process-exporter v0.8.7 with the low-cardinality perf flags"
  }
  assert {
    condition     = strcontains(local_file.server_ci.content, "--web.listen-address=:9558") && strcontains(local_file.server_ci.content, "--systemd.collector.unit-include=")
    error_message = "server must install systemd_exporter (:9558) with a curated unit-include"
  }
  # web_urls.all folds the 6 enabled /metrics endpoints on top of the 2 UI/API URLs.
  assert {
    condition     = length(output.web_urls.all) == 8
    error_message = "web_urls.all must add the 6 exporter /metrics endpoints to the 2 UI/API URLs"
  }
  assert {
    condition     = contains(output.enabled_exporters, "enable_node_exporter") && contains(output.enabled_exporters, "enable_process_exporter") && contains(output.enabled_exporters, "enable_systemd_exporter")
    error_message = "enabled_exporters must list the default-on exporter set"
  }
}

run "exporters_off_omit_install" {
  command = plan

  variables {
    enable_node_exporter    = false
    enable_process_exporter = false
    enable_systemd_exporter = false
  }

  assert {
    condition     = !strcontains(local_file.server_ci.content, "install-exporter.sh node_exporter") && !strcontains(local_file.server_ci.content, "systemd_exporter") && !strcontains(local_file.server_ci.content, "process-exporter")
    error_message = "disabling all exporter flags must omit their install blocks on the server"
  }
}

# --- Docker operator tooling (wharf/oxker/dive) — default ON on docker VMs ------------

run "docker_tools_render_by_default" {
  command = plan

  # The server always runs docker, so it carries the installer by default. The client has no
  # docker and must never carry it.
  assert {
    condition     = strcontains(local_file.server_ci.content, "install-docker-tools.sh")
    error_message = "server VM must install the docker operator TUIs by default"
  }
  assert {
    condition     = !strcontains(local_file.client_ci.content, "install-docker-tools.sh")
    error_message = "the client VM has no docker, so the docker-tools installer must be absent there"
  }
  assert {
    condition = alltrue([for m in [
      "idesyatov/wharf", "mrjackwills/oxker", "wagoodman/dive",
      "WHARF_VERSION=\"0.9.1\"", "OXKER_VERSION=\"0.13.2\"", "DIVE_VERSION=\"0.13.1\"",
    ] : strcontains(local_file.server_ci.content, m)])
    error_message = "server cloud-init must reference the pinned wharf/oxker/dive releases"
  }
  assert {
    condition     = output.docker_tools_enabled == true
    error_message = "docker_tools_enabled output must report true by default"
  }
  assert {
    condition     = can(yamldecode(local_file.server_ci.content))
    error_message = "server cloud-init must stay valid YAML after adding the docker-tools installer"
  }
}

run "docker_tools_render_on_discovery_agent" {
  command = plan

  variables {
    enable_discovery = true
  }

  # The discovery agent VM (only created with discovery on) also runs docker, so it gets the tools.
  assert {
    condition     = strcontains(local_file.agent_ci[0].content, "install-docker-tools.sh")
    error_message = "the discovery agent VM must install the docker operator TUIs by default"
  }
  assert {
    condition     = can(yamldecode(local_file.agent_ci[0].content))
    error_message = "agent cloud-init must stay valid YAML after adding the docker-tools installer"
  }
}

run "docker_tools_absent_when_disabled" {
  command = plan

  variables {
    enable_docker_tools = false
  }

  assert {
    condition     = !strcontains(local_file.server_ci.content, "install-docker-tools.sh")
    error_message = "disabled enable_docker_tools must omit the installer from the server VM"
  }
}
