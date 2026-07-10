# multipass-lab — orchestrate OpenTofu/Multipass clusters by folder name.
#
#   just up centralized_logging      # tofu apply -> 3 VMs (waits for cloud-init)
#   just check centralized_logging   # hermetic: fmt + validate + tofu test (no VMs)
#   just verify centralized_logging  # live: pytest + testinfra over SSH
#   just destroy centralized_logging # tofu destroy
#   just down                        # graceful `multipass stop --all` (all VMs, preserved)
#
# NOTE: `multipass exec`/`shell` do not route to the VMs in this environment
# ("No route to host"), but the host reaches the VMs directly over SSH. So all
# automation here talks to the VMs via SSH using the injected key and the IPs
# from the cluster's `hosts` output.

cluster_root := "clusters"
ssh_key := env_var_or_default("CLUSTER_SSH_KEY", env_var("HOME") + "/.ssh/id_ed25519")
ssh_opts := "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

_default:
    @just --list

# show a curated overview of the common cluster workflow, then list every recipe
help:
    @echo "multipass-lab — orchestrate OpenTofu/Multipass clusters by folder name."
    @echo "CLUSTER is a folder under {{cluster_root}}/ (e.g. centralized_logging, centralized_monitoring)."
    @echo ""
    @echo "Typical loop:"
    @echo "  just check  CLUSTER        hermetic: fmt + validate + tofu test (no VMs)"
    @echo "  just up     CLUSTER        tofu apply -> launch all VMs (waits for cloud-init)"
    @echo "  just up-all                tofu apply -> launch every cluster (glob-discovered)"
    @echo "  just up-connected          bring the whole fleet up wired for cross-cluster telemetry"
    @echo "                             (centralized_logging + centralized_monitoring + centralized_dns first)"
    @echo "  just verify CLUSTER        live: pytest + testinfra over SSH"
    @echo "  just verify-all            run the live testinfra suite for every cluster"
    @echo "  just verify-connected      live e2e for the cross-cluster wiring (after up-connected)"
    @echo "  just verify-api CLUSTER    hit a cluster's HTTP APIs (Grafana/Prometheus/OpenObserve/NetBox/...) + assert"
    @echo "  just init-all              tofu init every cluster (glob-discovered)"
    @echo "  just open   CLUSTER [--full]  open dashboards (core; --full adds /metrics endpoints)"
    @echo "  just open-all [--full]     open dashboards for every cluster (glob-discovered)"
    @echo "  just ssh    CLUSTER ROLE   shell onto the <name>-<role> VM"
    @echo "  just status                multipass list"
    @echo "  just destroy CLUSTER       tofu destroy + prune orphaned VMs (one cluster, gone)"
    @echo "  just destroy-all           tofu destroy + prune every cluster (glob-discovered)"
    @echo "  just recreate CLUSTER      destroy (incl. orphan cleanup) then up"
    @echo "  just prune CLUSTER         delete VMs tofu no longer tracks (fix a failed up)"
    @echo "  just down                  graceful multipass stop --all (all VMs, preserved)"
    @echo ""
    @echo "All recipes:"
    @just --list

# tofu init:  just init (centralized_logging|centralized_monitoring)
init CLUSTER:
    tofu -chdir={{cluster_root}}/{{CLUSTER}} init

# tofu plan:  just plan (centralized_logging|centralized_monitoring)
plan CLUSTER: (init CLUSTER)
    tofu -chdir={{cluster_root}}/{{CLUSTER}} plan

# apply -> launch all VMs, wait for cloud-init:  just up (centralized_logging|centralized_monitoring)
# PATH-prepended wrapper raises multipass launch's 5min default init timeout (see its header
# comment) — a loaded fleet host can blow that mid-cloud-init, orphaning the VM tofu never records.
up CLUSTER: (init CLUSTER)
    @if [ "{{CLUSTER}}" = "centralized_k0s" ]; then command -v k0sctl >/dev/null || { echo "install k0sctl: brew install k0sproject/tap/k0sctl"; exit 1; }; fi
    PATH="{{justfile_directory()}}/{{cluster_root}}/_shared/scripts/multipass-timeout-wrapper:$PATH" \
      tofu -chdir={{cluster_root}}/{{CLUSTER}} apply -auto-approve
    @tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts \
      | jq -r '.[].ipv4' \
      | while read ip; do \
          echo "waiting for cloud-init: $ip"; \
          until ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" \
            'cloud-init status --wait >/dev/null 2>&1 || true' 2>/dev/null; do sleep 5; done; \
        done

# tofu destroy + prune any orphaned VMs (one cluster, gone):  just destroy (centralized_logging|centralized_monitoring)
destroy CLUSTER:
    tofu -chdir={{cluster_root}}/{{CLUSTER}} destroy -auto-approve
    @just prune {{CLUSTER}}

# tofu init every cluster (glob-discovered):  just init-all
init-all:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for dir in {{cluster_root}}/*/; do
      cluster="$(basename "$dir")"
      [ -f "$dir/main.tf" ] || continue   # skip non-cluster dirs like _shared/
      echo "=== init: $cluster ==="
      just init "$cluster" || rc=1
    done
    exit "$rc"

# tofu apply -> launch every cluster's VMs (glob-discovered):  just up-all
up-all:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for dir in {{cluster_root}}/*/; do
      cluster="$(basename "$dir")"
      [ -f "$dir/main.tf" ] || continue   # skip non-cluster dirs like _shared/
      echo "=== up: $cluster ==="
      # Bulk bring-up enables the heavier opt-in features (they change cloud-init, so they must be
      # set at first apply). `.auto.tfvars` outranks terraform.tfvars (TF_VAR_ would be lower).
      case "$cluster" in
        centralized_logging) echo '{"enable_coroot": true}'    > "$dir/.flags.auto.tfvars.json" ;;
        centralized_netbox)  echo '{"enable_discovery": true}' > "$dir/.flags.auto.tfvars.json" ;;
      esac
      just up "$cluster" || rc=1
    done
    exit "$rc"

# tofu destroy + prune every cluster (glob-discovered):  just destroy-all
destroy-all:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for dir in {{cluster_root}}/*/; do
      cluster="$(basename "$dir")"
      [ -f "$dir/main.tf" ] || continue   # skip non-cluster dirs like _shared/
      echo "=== destroy: $cluster ==="
      just destroy "$cluster" || rc=1
    done
    # Purge stale cross-cluster wiring + bulk-flag tfvars: the whole fleet is gone, so every IP they
    # reference is dead. Leaving them behind poisons the NEXT plain `just up` — OpenTofu auto-loads
    # `*.auto.tfvars(.json)`, so a dead `dns_server` repoints the resolver at a down hub and `apt`
    # hangs (see the CLAUDE.md gotcha). `up-connected`/`refresh-cross-cluster` regenerate them from
    # live IPs when needed, so this loses nothing.  (Single-cluster `destroy` deliberately does NOT
    # do this — `recreate` relies on the file surviving; use `just unwire` for a targeted removal.)
    echo "=== destroy-all: purging stale cross-cluster wiring files ==="
    rm -f {{cluster_root}}/*/.cross-cluster.auto.tfvars.json {{cluster_root}}/*/.flags.auto.tfvars.json
    exit "$rc"

# Drop cross-cluster wiring WITHOUT a teardown: remove the auto-loaded .cross-cluster.auto.tfvars.json
# so the next plain `just up <cluster>` renders UNWIRED (resolver stays on DHCP, no syslog-ng/otel
# shipper). Use after single-cluster `just destroy`s when you want a pristine plain `up` — the file
# survives `destroy` on purpose (for `recreate`), but a dead hub IP in it will hang `apt` at boot.
# Name a cluster to unwire just one, or omit to unwire the whole fleet.  just unwire centralized_pki
unwire *CLUSTER:
    #!/usr/bin/env bash
    set -uo pipefail
    if [ -n "{{CLUSTER}}" ]; then
      rm -f {{cluster_root}}/{{CLUSTER}}/.cross-cluster.auto.tfvars.json
      echo "unwired {{CLUSTER}} (removed .cross-cluster.auto.tfvars.json if it was present)"
    else
      rm -f {{cluster_root}}/*/.cross-cluster.auto.tfvars.json
      echo "unwired all clusters (removed every .cross-cluster.auto.tfvars.json)"
    fi

# Bring the whole fleet up ALREADY WIRED for cross-cluster telemetry (specs/cross-cluster.md):
# every VM resolves through centralized_dns's AdGuard Home, consumer clusters ship logs to
# centralized_logging + push host logs to centralized_monitoring's OpenObserve, and Prometheus
# scrapes every VM.  just up-connected
#
# Ordering: centralized_dns comes up FIRST (pure :53 sink, depends on nobody) so every later VM
# learns the DNS hub IP and points its resolver at AdGuard at first boot. Then logging (pure sink)
# and monitoring (OTLP/OpenObserve sink) come up so consumers learn both hub IPs and wire all
# signals in a single boot (stable IPs, no recreate). The DNS hub booted before the telemetry hubs,
# so its OWN log-shipping + the consumer scrape targets are HOT-PUSHED afterwards — the monitoring
# and DNS VMs are never recreated, so the IPs consumers push OTLP to / resolve against never churn.
up-connected:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    dns=centralized_dns
    logging=centralized_logging
    monitoring=centralized_monitoring

    # Internal-CA trust anchor: the pinned root written by `scripts/init_ca.py generate`. It is a
    # STATIC file (no dependency on centralized_pki being up), so every cluster — including the
    # hubs that boot first — can trust it at first boot. Empty when no persisted root is configured
    # (then trust distribution is a no-op; use `just trust-ca <cluster>` after fetching /roots.pem).
    # See specs/internal-ca.md.
    ca_crt="{{cluster_root}}/centralized_pki/.ca/root_ca.crt"
    ca_pem=""
    if [ -f "$ca_crt" ]; then ca_pem="$(cat "$ca_crt")"; echo "internal CA: distributing $ca_crt fleet-wide"; \
      else echo "internal CA: no pinned root ($ca_crt absent) — skipping fleet trust (run scripts/init_ca.py)"; fi

    # Internal-CA TLS (Phase 2, opt-in): with INTERNAL_TLS set AND centralized_pki's CA up, front the
    # monitoring stack with a step-ca leaf issued at the monitoring VM's first boot. tls_json (empty
    # {} when off) is merged into the monitoring hub's tfvars; step 6 wires the AdGuard rewrites so
    # the hostnames resolve. See specs/internal-ca.md §Phase 2.
    tls_json='{}'
    if [ -n "${INTERNAL_TLS:-}" ]; then
      tls_ca_ip="$(tofu -chdir={{cluster_root}}/centralized_pki output -raw ca_ipv4 2>/dev/null || true)"
      if [ -n "$tls_ca_ip" ]; then
        echo "internal TLS: fronting monitoring via step-ca @ $tls_ca_ip"
        tls_json="$(jq -n --arg ip "$tls_ca_ip" --arg dom "${INTERNAL_TLS_DOMAIN:-lab.theblacktonystark.com}" \
          --arg pw "${STEPCA_CA_PASSWORD:-changeit-dev-pki-only}" \
          '{use_internal_tls: true, ca_ip: $ip, domain: $dom, stepca_ca_password: $pw}')"
      else
        echo "internal TLS: INTERNAL_TLS set but centralized_pki CA not up (no ca_ipv4) — skipping TLS"
      fi
    fi

    # Internal NTP (opt-in): with INTERNAL_NTP set, the DNS box runs chrony as the fleet NTP server
    # (dns_ntp_json enables it at the box's first boot) and every other VM points systemd-timesyncd
    # at that box by IP (ntp_json, set once dns_ip is known — by IP so time sync never races DNS at
    # boot). Both empty {} when off, so a plain run is unchanged. See specs/shared-ntp.md.
    dns_ntp_json='{}'
    ntp_json='{}'
    if [ -n "${INTERNAL_NTP:-}" ]; then
      dns_ntp_json='{"enable_ntp_server": true}'
      echo "internal NTP: DNS box will serve time via chrony; fleet disciplines against it"
    fi

    # 0. DNS hub FIRST — pure :53 sink. No telemetry targets yet (the hubs don't exist), but it DOES
    #    get the CA trust anchor at first boot (static, so no ordering dependency on the PKI hub).
    echo "=== up-connected: dns hub ($dns) ==="
    jq -n --arg ca "$ca_pem" --argjson ntp "$dns_ntp_json" '{internal_ca_cert: $ca} + $ntp' \
      > {{cluster_root}}/$dns/.cross-cluster.auto.tfvars.json
    just up "$dns" || { echo "FAILED hub: $dns"; rc=1; }
    # dns_endpoint = the floating VIP in HA mode (enable_ha=true), else the single server VM's IP —
    # this is what the FLEET should resolve against either way. See specs/ha-dns.md.
    dns_ip="$(tofu -chdir={{cluster_root}}/$dns output -raw dns_endpoint)"
    echo "    AdGuard Home resolver: $dns_ip:53"
    # Now that the DNS/NTP hub IP is known, point the fleet's timesyncd at it (INTERNAL_NTP only).
    if [ -n "${INTERNAL_NTP:-}" ]; then
      ntp_json="$(jq -n --arg ip "$dns_ip" '{ntp_server: $ip}')"
      echo "    chrony NTP server: $dns_ip:123"
    fi
    # health-gate: do NOT wire anyone until AdGuard actually answers, else a dependent VM switches
    # its resolver at boot and cannot resolve archive.ubuntu.com. `dig` ships with macOS.
    echo "    waiting for AdGuard Home to answer DNS on $dns_ip:53 ..."
    for i in $(seq 1 60); do
      if dig +time=2 +tries=1 @"$dns_ip" example.com >/dev/null 2>&1; then break; fi
      sleep 5
    done

    # 1. logging hub — pure sink; now resolves via DNS + trusts the internal CA. enable_coroot brings
    #    up the eBPF observability stack on the k0s node (bulk bring-up always includes it).
    echo "=== up-connected: logging hub ($logging) ==="
    jq -n --arg dns "$dns_ip" --arg ca "$ca_pem" --argjson ntp "$ntp_json" '{dns_server: $dns, internal_ca_cert: $ca, enable_coroot: true} + $ntp' \
      > {{cluster_root}}/$logging/.cross-cluster.auto.tfvars.json
    just up "$logging" || { echo "FAILED hub: $logging"; rc=1; }
    log_ip="$(tofu -chdir={{cluster_root}}/$logging output -raw central_ipv4)"
    echo "    syslog-ng collector: $log_ip:514"

    # 2. monitoring hub — resolves via DNS + trusts the internal CA + self-ships its OWN OS logs.
    echo "=== up-connected: monitoring hub ($monitoring) ==="
    # TLS (tls_json) must be set HERE — the VM is created by this `just up`, and use_internal_tls
    # gates the leaf-issuance cloud-init; the step-5 re-apply is content-only and won't recreate it.
    jq -n --arg dns "$dns_ip" --arg log "$log_ip:514" --arg ca "$ca_pem" --argjson tls "$tls_json" --argjson ntp "$ntp_json" \
      '{dns_server: $dns, log_shipping_target: $log, internal_ca_cert: $ca} + $tls + $ntp' \
      > {{cluster_root}}/$monitoring/.cross-cluster.auto.tfvars.json
    just up "$monitoring" || { echo "FAILED hub: $monitoring"; rc=1; }
    mon_ip="$(tofu -chdir={{cluster_root}}/$monitoring output -raw server_ipv4)"
    echo "    OpenObserve/OTLP sink: $mon_ip:5080"

    # 3. consumers — everything except the three hubs and non-cluster dirs. Single boot with all
    #    hub IPs known: DNS resolver + syslog shipping + OTLP push + node_exporter, all at first boot.
    targets='[]'
    ndtargets='[]'   # Netdata (:19999) targets: {name, ip} per fleet VM (specs/shared-netdata.md)
    for dir in {{cluster_root}}/*/; do
      c="$(basename "$dir")"
      [ -f "$dir/main.tf" ] || continue
      case "$c" in "$dns"|"$logging"|"$monitoring") continue ;; esac
      echo "=== up-connected: consumer $c ==="
      # netbox joins the fleet with discovery on (Diode + orb-agent), per the bulk bring-up spec.
      extra='{}'
      [ "$c" = "centralized_netbox" ] && extra='{"enable_discovery": true}'
      jq -n --arg dns "$dns_ip" --arg log "$log_ip:514" --arg oo "$mon_ip:5080" --arg ca "$ca_pem" --argjson extra "$extra" --argjson ntp "$ntp_json" \
        '{dns_server: $dns, log_shipping_target: $log, openobserve_endpoint: $oo, internal_ca_cert: $ca} + $extra + $ntp' \
        > "$dir/.cross-cluster.auto.tfvars.json"
      just up "$c" || { echo "FAILED consumer: $c"; rc=1; }
      # accumulate this consumer's VM IPs as Prometheus scrape targets (node_exporter :9100)
      targets="$(tofu -chdir={{cluster_root}}/$c output -json hosts 2>/dev/null \
        | jq --argjson acc "$targets" \
            '$acc + [to_entries[] | {job: .value.name, ip: .value.ipv4, port: 9100}]')"
      # ...and as Netdata (:19999) targets, folded into job="netdata" (specs/shared-netdata.md)
      ndtargets="$(tofu -chdir={{cluster_root}}/$c output -json hosts 2>/dev/null \
        | jq --argjson acc "$ndtargets" \
            '$acc + [to_entries[] | {name: .value.name, ip: .value.ipv4}]')"
    done
    # add the DNS hub's OWN exporters (node :9100, adguard :9618, unbound :9167) — one VM in single
    # mode, BOTH primary+secondary in HA mode (see specs/ha-dns.md), so Prometheus scrapes both.
    dns_hosts_json="$(tofu -chdir={{cluster_root}}/$dns output -json hosts 2>/dev/null || echo '{}')"
    targets="$(echo "$targets" | jq --argjson hosts "$dns_hosts_json" \
      '. + ($hosts | to_entries | map(.key as $r | .value.ipv4 as $ip |
            [{job:("centralized-dns-"+$r),ip:$ip,port:9100},
             {job:("centralized-dns-"+$r+"-adguard"),ip:$ip,port:9618},
             {job:("centralized-dns-"+$r+"-unbound"),ip:$ip,port:9167}]) | flatten)')"
    # Netdata targets for the hubs the monitoring job doesn't already carry statically: the DNS
    # VM(s) + all of the logging hub's VMs (the monitoring hub's own server+k0s are static in
    # the netdata job). See specs/shared-netdata.md.
    ndtargets="$(echo "$ndtargets" | jq --argjson hosts "$dns_hosts_json" \
      '. + ($hosts | to_entries | map({name: ("centralized-dns-" + .key), ip: .value.ipv4}))')"
    ndtargets="$(tofu -chdir={{cluster_root}}/$logging output -json hosts 2>/dev/null \
      | jq --argjson acc "$ndtargets" '$acc + [to_entries[] | {name: .value.name, ip: .value.ipv4}]' 2>/dev/null || echo "$ndtargets")"

    # 4. DNS-hub self-telemetry HOT-PUSH (mirrors _hot-push-cross-cluster; no recreate):
    #    the DNS VM booted before the hubs, so wire its log shipping now. A targeted re-apply
    #    (content-only change — never recreates the VM) materializes the rendered drop-ins for scp.
    echo "=== up-connected: wiring DNS hub self-telemetry ==="
    jq -n --arg dns "$dns_ip" --arg log "$log_ip:514" --arg oo "$mon_ip:5080" --arg ca "$ca_pem" --argjson ntp "$dns_ntp_json" \
      '{log_shipping_target: $log, openobserve_endpoint: $oo, internal_ca_cert: $ca} + $ntp' \
      > {{cluster_root}}/$dns/.cross-cluster.auto.tfvars.json
    tofu -chdir={{cluster_root}}/$dns apply -auto-approve   # re-renders .rendered/ drop-ins only
    just _hot-push-cross-cluster "$dns"

    # 5. hot-push the discovered scrape targets into the RUNNING monitoring server (no recreate).
    #    Keep log_shipping_target + dns_server so the re-apply preserves the hub's wiring in state.
    echo "=== up-connected: wiring Prometheus scrape targets ==="
    # Preserve tls_json here too so the content-only re-apply keeps use_internal_tls in state/render
    # (it does NOT recreate the VM — the leaf was already issued at the step-2 boot).
    echo "$targets" | jq -c --arg dns "$dns_ip" --arg log "$log_ip:514" --arg ca "$ca_pem" --argjson tls "$tls_json" --argjson ntp "$ntp_json" --argjson nd "$ndtargets" \
      '{dns_server: $dns, log_shipping_target: $log, internal_ca_cert: $ca, extra_scrape_targets: ., netdata_scrape_targets: $nd} + $tls + $ntp' \
      > {{cluster_root}}/$monitoring/.cross-cluster.auto.tfvars.json
    tofu -chdir={{cluster_root}}/$monitoring apply -auto-approve   # re-renders .rendered/prometheus.yml only
    scp {{ssh_opts}} -i {{ssh_key}} \
      {{cluster_root}}/$monitoring/.rendered/prometheus.yml \
      {{cluster_root}}/$monitoring/cloud-init/prometheus/alert.rules.yml \
      ubuntu@"$mon_ip":/tmp/
    ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$mon_ip" \
      'sudo cp /tmp/prometheus.yml /opt/stack/prometheus/prometheus.yml && sudo cp /tmp/alert.rules.yml /opt/stack/prometheus/alert.rules.yml && sudo docker compose -f /opt/stack/compose.yaml restart prometheus'
    echo "up-connected: $(echo "$targets" | jq 'length') cross-cluster scrape targets + $(echo "$ndtargets" | jq 'length') Netdata targets wired; fleet resolving via $dns_ip."

    # 5b. Fleet-edge Traefik (see specs/dynamic-traefik.md): hot-push every cluster's
    #     reverse_proxy_routes into centralized_pki's Traefik (directory file provider, no
    #     restart). Best-effort — pki not being up yet is not fatal to the rest of up-connected.
    echo "=== up-connected: syncing fleet-edge Traefik routes (traefik-sync) ==="
    just traefik-sync || echo "    (traefik-sync skipped/failed — is centralized_pki up?)"

    # 6. DEAD LAST — register every up cluster's service hostnames as AdGuard rewrites, so
    #    grafana.<domain>/netbox.<domain>/auth.<domain>/... resolve fleet-wide. Only meaningful
    #    once the whole fleet is up (each cluster's dns_records needs its VM IPs). Hosts the fleet
    #    Traefik fronts are overridden to pki's edge IP (set-dns-all folds in traefik_cli.py
    #    dns-rewrites) so e.g. https://netbox.<domain> reaches Traefik, not netbox's raw IP.
    echo "=== up-connected: registering fleet DNS records (set-dns-all) ==="
    just set-dns-all || { echo "FAILED: set-dns-all"; rc=1; }

    if [ "$rc" -ne 0 ]; then
      echo "up-connected FAILED — one or more steps did not complete (see the FAILED lines above)." >&2
    else
      echo "up-connected complete — fleet up, wired, and DNS-registered."
    fi
    exit "$rc"

# up-connected with internal-CA TLS + internal NTP both wired (INTERNAL_NTP=1 INTERNAL_TLS=1).
# Needs centralized_pki's persisted root (ca-material.auto.tfvars) for TLS to activate.  just up-connected-full
up-connected-full:
    INTERNAL_NTP=1 INTERNAL_TLS=1 just up-connected

# cold-boot validation: destroy-all (purges stale cross-cluster wiring) -> up-connected-full ->
# verify-connected + verify-dns + tls-check-monitoring. Proves the committed cloud-init hardening
# works at first boot with no hot-patching.  just cold-boot-validate
cold-boot-validate:
    #!/usr/bin/env bash
    set -euo pipefail
    just destroy-all
    just up-connected-full
    just verify-connected
    just verify-dns
    just tls-check-monitoring

# register ONE cluster's service hostnames (its `dns_records` output) into centralized_dns's
# AdGuard Home as idempotent DNS rewrites, so <service>.<domain> resolves fleet-wide.
# Requires that cluster AND the dns hub to be up.  just set-dns centralized_pki
set-dns CLUSTER:
    #!/usr/bin/env bash
    set -uo pipefail
    records="$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json dns_records 2>/dev/null || true)"
    if [ -z "$records" ] || [ "$records" = "{}" ]; then
      echo "no dns_records for {{CLUSTER}} (not up, or no records) — nothing to register"
      exit 0
    fi
    echo "$records" | jq .
    echo "$records" | uv run {{cluster_root}}/centralized_dns/scripts/adguard_cli.py \
      --cluster centralized_dns rewrite-sync --file -

# register EVERY up cluster's `dns_records` into AdGuard in one idempotent sync. Clusters that
# aren't up contribute nothing (their `tofu output` errors -> {}). A host claimed by the fleet-edge
# Traefik (its cluster's `reverse_proxy_routes`) is OVERRIDDEN to resolve to pki's edge IP instead
# of its own — see specs/dynamic-traefik.md. Run after the fleet is up (up-connected does this
# automatically as its last step).  just set-dns-all
set-dns-all:
    #!/usr/bin/env bash
    set -uo pipefail
    docs=()
    for dir in {{cluster_root}}/*/; do
      [ -f "$dir/main.tf" ] || continue   # skip non-cluster dirs like _shared/
      records="$(tofu -chdir="$dir" output -json dns_records 2>/dev/null || echo '{}')"
      [ -n "$records" ] || records='{}'
      docs+=("$records")
    done
    merged="$(printf '%s\n' "${docs[@]}" | jq -s 'reduce .[] as $x ({}; . * $x)')"
    # Fleet-edge override: hosts the pki Traefik fronts win over their cluster's own direct IP.
    # {} (not an error) when centralized_pki isn't up yet — merge is then a no-op.
    fleet="$(uv run {{cluster_root}}/centralized_pki/scripts/traefik_cli.py --json dns-rewrites 2>/dev/null || echo '{}')"
    merged="$(echo "$merged" | jq --argjson fleet "$fleet" '. * $fleet')"
    echo "$merged" | jq .
    if [ "$merged" = "{}" ] || [ -z "$merged" ]; then
      echo "no dns_records found across clusters — nothing to register (is the fleet up?)"
      exit 0
    fi
    echo "$merged" | uv run {{cluster_root}}/centralized_dns/scripts/adguard_cli.py \
      --cluster centralized_dns rewrite-sync --file -

# live: assert every registered record resolves through AdGuard to the expected IP (dig against
# the dns hub). Nonzero exit on any mismatch.  just verify-dns
verify-dns:
    #!/usr/bin/env bash
    set -uo pipefail
    dns_ip="$(tofu -chdir={{cluster_root}}/centralized_dns output -raw dns_endpoint 2>/dev/null || true)"
    if [ -z "$dns_ip" ]; then
      echo "centralized_dns is not up (no dns_endpoint) — cannot verify" >&2
      exit 1
    fi
    docs=()
    for dir in {{cluster_root}}/*/; do
      [ -f "$dir/main.tf" ] || continue
      records="$(tofu -chdir="$dir" output -json dns_records 2>/dev/null || echo '{}')"
      [ -n "$records" ] || records='{}'
      docs+=("$records")
    done
    merged="$(printf '%s\n' "${docs[@]}" | jq -s 'reduce .[] as $x ({}; . * $x)')"
    # Same fleet-edge override as set-dns-all, so expectations match what was actually registered.
    fleet="$(uv run {{cluster_root}}/centralized_pki/scripts/traefik_cli.py --json dns-rewrites 2>/dev/null || echo '{}')"
    merged="$(echo "$merged" | jq --argjson fleet "$fleet" '. * $fleet')"
    rc=0
    while IFS=$'\t' read -r host ip; do
      [ -n "$host" ] || continue
      got="$(dig +short +time=2 +tries=1 @"$dns_ip" "$host" 2>/dev/null | head -1)"
      if [ "$got" = "$ip" ]; then
        echo "ok:   $host -> $got"
      else
        echo "FAIL: $host -> expected $ip, got '${got:-<none>}'"
        rc=1
      fi
    done < <(echo "$merged" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')
    [ "$rc" -eq 0 ] && echo "verify-dns: all records resolve via $dns_ip" || echo "verify-dns: MISMATCHES above" >&2
    exit "$rc"

# generic hot-push: pushes whichever of {resolved.conf, ship.conf, otel.yaml} exist under
# CLUSTER's .rendered/ onto EVERY currently-running VM of that cluster (per `hosts` output),
# keyed by role name (<role>-resolved.conf / <role>-ship.conf / <role>-otel.yaml). Content-only;
# never touches tofu state, never recreates a VM. Skips silently if CLUSTER isn't up.
_hot-push-cross-cluster CLUSTER:
    #!/usr/bin/env bash
    set -uo pipefail
    dir="{{cluster_root}}/{{CLUSTER}}"
    hosts_json="$(tofu -chdir="$dir" output -json hosts 2>/dev/null)" || { echo "    ({{CLUSTER}} not up — skip hot-push)"; exit 0; }
    [ -n "$hosts_json" ] && [ "$hosts_json" != "null" ] || exit 0
    while IFS=$'\t' read -r role ip; do
      [ -n "$role" ] && [ -n "$ip" ] || continue

      if [ -f "$dir/.rendered/${role}-resolved.conf" ]; then
        echo "    [{{CLUSTER}}/$role] dns resolver -> $ip"
        scp {{ssh_opts}} -i {{ssh_key}} "$dir/.rendered/${role}-resolved.conf" ubuntu@"$ip":/tmp/99-centralized-dns.conf
        ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" \
          'sudo cp /tmp/99-centralized-dns.conf /etc/systemd/resolved.conf.d/99-centralized-dns.conf && sudo systemctl restart systemd-resolved'
      fi

      if [ -f "$dir/.rendered/${role}-ship.conf" ]; then
        echo "    [{{CLUSTER}}/$role] syslog-ng shipper -> $ip"
        scp {{ssh_opts}} -i {{ssh_key}} "$dir/.rendered/${role}-ship.conf" ubuntu@"$ip":/tmp/10-ship.conf
        ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" '
          set -e
          sudo DEBIAN_FRONTEND=noninteractive apt-get install -y syslog-ng >/dev/null
          sudo mkdir -p /var/lib/syslog-ng /etc/syslog-ng/conf.d
          sudo cp /tmp/10-ship.conf /etc/syslog-ng/conf.d/10-ship.conf
          grep -q "conf.d/\*.conf" /etc/syslog-ng/syslog-ng.conf || echo "@include \"/etc/syslog-ng/conf.d/*.conf\"" | sudo tee -a /etc/syslog-ng/syslog-ng.conf >/dev/null
          sudo systemctl enable syslog-ng >/dev/null 2>&1 || true
          sudo systemctl restart syslog-ng'
      fi

      if [ -f "$dir/.rendered/${role}-otel.yaml" ]; then
        echo "    [{{CLUSTER}}/$role] otelcol-contrib -> $ip"
        scp {{ssh_opts}} -i {{ssh_key}} "$dir/.rendered/${role}-otel.yaml" ubuntu@"$ip":/tmp/otel-config.yaml
        ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" '
          set -e
          sudo mkdir -p /var/lib/otelcol-contrib/storage
          if ! command -v otelcol-contrib >/dev/null 2>&1; then
            V=0.109.0; A="$(dpkg --print-architecture)"
            curl -sSLf "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${V}/otelcol-contrib_${V}_linux_${A}.deb" -o /tmp/otelcol.deb
            sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold -i /tmp/otelcol.deb || sudo DEBIAN_FRONTEND=noninteractive apt-get install -f -y
          fi
          sudo cp /tmp/otel-config.yaml /etc/otelcol-contrib/config.yaml
          sudo chown -R otelcol-contrib:otelcol-contrib /var/lib/otelcol-contrib/storage
          sudo usermod -aG adm otelcol-contrib
          sudo systemctl enable otelcol-contrib >/dev/null 2>&1 || true
          sudo systemctl restart otelcol-contrib'
      fi
    done < <(echo "$hosts_json" | jq -r 'to_entries[] | "\(.key)\t\(.value.ipv4)"')

# re-discover the 3 hub IPs, rewrite every ALREADY-WIRED cluster's .cross-cluster.auto.tfvars.json,
# content-only `tofu apply`, then hot-push. Run after recreating a hub (see `recreate`), or any
# time you suspect wiring has drifted.  just refresh-cross-cluster
refresh-cross-cluster:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    dns=centralized_dns; logging=centralized_logging; monitoring=centralized_monitoring

    dns_ip="$(tofu -chdir={{cluster_root}}/$dns output -raw dns_endpoint 2>/dev/null || true)"
    dns_hosts_json="$(tofu -chdir={{cluster_root}}/$dns output -json hosts 2>/dev/null || echo '{}')"
    log_ip="$(tofu -chdir={{cluster_root}}/$logging output -raw central_ipv4 2>/dev/null || true)"
    mon_ip="$(tofu -chdir={{cluster_root}}/$monitoring output -raw server_ipv4 2>/dev/null || true)"
    log_target=""; [ -n "$log_ip" ] && log_target="$log_ip:514"
    oo_target="";  [ -n "$mon_ip" ] && oo_target="$mon_ip:5080"
    echo "=== refresh-cross-cluster: dns=$dns_ip logging=$log_ip monitoring=$mon_ip ==="

    # Preserve internal-NTP wiring across the rewrite: honor INTERNAL_NTP, or auto-detect it from the
    # DNS box's existing tfvars (enable_ntp_server:true) so a plain refresh doesn't silently unwire it.
    dns_ntp_json='{}'; ntp_json='{}'
    if [ -n "${INTERNAL_NTP:-}" ] || grep -sq '"enable_ntp_server": *true' {{cluster_root}}/$dns/.cross-cluster.auto.tfvars.json; then
      dns_ntp_json='{"enable_ntp_server": true}'
      [ -n "$dns_ip" ] && ntp_json="$(jq -n --arg ip "$dns_ip" '{ntp_server: $ip}')"
      echo "    internal NTP: preserving chrony hub + fleet ntp_server=$dns_ip"
    fi

    # recompute extra_scrape_targets (+ Netdata targets) from every currently-up, already-wired cluster
    targets='[]'
    ndtargets='[]'
    for dir in {{cluster_root}}/*/; do
      c="$(basename "$dir")"
      [ -f "$dir/main.tf" ] || continue
      case "$c" in "$dns"|"$logging"|"$monitoring") continue ;; esac
      [ -f "$dir/.cross-cluster.auto.tfvars.json" ] || continue
      new_targets="$(tofu -chdir="$dir" output -json hosts 2>/dev/null \
        | jq --argjson acc "$targets" '$acc + [to_entries[] | {job: .value.name, ip: .value.ipv4, port: 9100}]' \
        2>/dev/null)" && targets="$new_targets"
      new_nd="$(tofu -chdir="$dir" output -json hosts 2>/dev/null \
        | jq --argjson acc "$ndtargets" '$acc + [to_entries[] | {name: .value.name, ip: .value.ipv4}]' \
        2>/dev/null)" && ndtargets="$new_nd"
    done
    # Scrape targets for every centralized_dns VM (one "server" single mode; "primary"+"secondary"
    # HA mode — see specs/ha-dns.md) so Prometheus scrapes BOTH nodes' exporters in HA mode, not
    # just whichever holds the VIP.
    if [ "$dns_hosts_json" != '{}' ] && [ -n "$dns_hosts_json" ]; then
      targets="$(echo "$targets" | jq --argjson hosts "$dns_hosts_json" \
        '. + ($hosts | to_entries | map(.key as $r | .value.ipv4 as $ip |
              [{job:("centralized-dns-"+$r),ip:$ip,port:9100},
               {job:("centralized-dns-"+$r+"-adguard"),ip:$ip,port:9618},
               {job:("centralized-dns-"+$r+"-unbound"),ip:$ip,port:9167}]) | flatten)')"
      ndtargets="$(echo "$ndtargets" | jq --argjson hosts "$dns_hosts_json" \
        '. + ($hosts | to_entries | map({name: ("centralized-dns-" + .key), ip: .value.ipv4}))')"
    fi
    # logging hub's VMs run Netdata too (monitoring's own server+k0s stay static in the job).
    new_nd="$(tofu -chdir={{cluster_root}}/$logging output -json hosts 2>/dev/null \
      | jq --argjson acc "$ndtargets" '$acc + [to_entries[] | {name: .value.name, ip: .value.ipv4}]' \
      2>/dev/null)" && ndtargets="$new_nd"

    if [ -f {{cluster_root}}/$dns/.cross-cluster.auto.tfvars.json ]; then
      echo "=== refresh: $dns (self-telemetry) ==="
      jq -n --arg log "$log_target" --arg oo "$oo_target" --argjson ntp "$dns_ntp_json" \
        '{log_shipping_target: $log, openobserve_endpoint: $oo} + $ntp' \
        > {{cluster_root}}/$dns/.cross-cluster.auto.tfvars.json
      tofu -chdir={{cluster_root}}/$dns apply -auto-approve || { echo "FAILED apply: $dns"; rc=1; }
      just _hot-push-cross-cluster "$dns" || rc=1
    fi

    if [ -f {{cluster_root}}/$logging/.cross-cluster.auto.tfvars.json ]; then
      echo "=== refresh: $logging ==="
      jq -n --arg dns "$dns_ip" --argjson ntp "$ntp_json" '{dns_server: $dns, enable_coroot: true} + $ntp' \
        > {{cluster_root}}/$logging/.cross-cluster.auto.tfvars.json
      tofu -chdir={{cluster_root}}/$logging apply -auto-approve || { echo "FAILED apply: $logging"; rc=1; }
      just _hot-push-cross-cluster "$logging" || rc=1
    fi

    if [ -f {{cluster_root}}/$monitoring/.cross-cluster.auto.tfvars.json ]; then
      echo "=== refresh: $monitoring ==="
      echo "$targets" | jq -c --arg dns "$dns_ip" --arg log "$log_target" --argjson ntp "$ntp_json" --argjson nd "$ndtargets" \
        '{dns_server: $dns, log_shipping_target: $log, extra_scrape_targets: ., netdata_scrape_targets: $nd} + $ntp' \
        > {{cluster_root}}/$monitoring/.cross-cluster.auto.tfvars.json
      tofu -chdir={{cluster_root}}/$monitoring apply -auto-approve || { echo "FAILED apply: $monitoring"; rc=1; }
      just _hot-push-cross-cluster "$monitoring" || rc=1
      mon_ip_now="$(tofu -chdir={{cluster_root}}/$monitoring output -raw server_ipv4 2>/dev/null || true)"
      if [ -n "$mon_ip_now" ]; then
        scp {{ssh_opts}} -i {{ssh_key}} {{cluster_root}}/$monitoring/.rendered/prometheus.yml {{cluster_root}}/$monitoring/cloud-init/prometheus/alert.rules.yml ubuntu@"$mon_ip_now":/tmp/
        ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$mon_ip_now" \
          'sudo cp /tmp/prometheus.yml /opt/stack/prometheus/prometheus.yml && sudo cp /tmp/alert.rules.yml /opt/stack/prometheus/alert.rules.yml && sudo docker compose -f /opt/stack/compose.yaml restart prometheus'
      fi
    fi

    for dir in {{cluster_root}}/*/; do
      c="$(basename "$dir")"
      [ -f "$dir/main.tf" ] || continue
      case "$c" in "$dns"|"$logging"|"$monitoring") continue ;; esac
      if [ ! -f "$dir/.cross-cluster.auto.tfvars.json" ]; then
        echo "=== skip $c (never opted into cross-cluster wiring) ==="; continue
      fi
      echo "=== refresh: $c ==="
      extra='{}'
      [ "$c" = "centralized_netbox" ] && extra='{"enable_discovery": true}'
      jq -n --arg dns "$dns_ip" --arg log "$log_target" --arg oo "$oo_target" --argjson extra "$extra" --argjson ntp "$ntp_json" \
        '{dns_server: $dns, log_shipping_target: $log, openobserve_endpoint: $oo} + $extra + $ntp' \
        > "$dir/.cross-cluster.auto.tfvars.json"
      tofu -chdir="$dir" apply -auto-approve || { echo "FAILED apply: $c"; rc=1; continue; }
      just _hot-push-cross-cluster "$c" || rc=1
    done

    echo "=== refresh-cross-cluster: re-syncing fleet-edge Traefik routes ==="
    just traefik-sync || echo "    (traefik-sync skipped/failed — is centralized_pki up?)"

    echo "=== refresh-cross-cluster: re-registering fleet DNS records ==="
    just set-dns-all || { echo "FAILED: set-dns-all"; rc=1; }
    exit "$rc"

# delete + purge Multipass VMs for this cluster that OpenTofu no longer tracks.
# A failed `up` (e.g. a launch timeout) leaves a VM behind that `tofu destroy` can't
# see, which then collides with the next `up` ("instance already exists"). Safe to run
# anytime: it never touches a VM that is still in tofu state.  just prune centralized_logging
prune CLUSTER:
    #!/usr/bin/env bash
    set -euo pipefail
    prefix="$(echo {{CLUSTER}} | tr '_' '-')"
    tracked="$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts 2>/dev/null | jq -r '.[].name' 2>/dev/null || true)"
    found=0
    for inst in $(multipass list --format csv | tail -n +2 | cut -d, -f1 | grep "^${prefix}-" || true); do
      if echo "$tracked" | grep -qx "$inst"; then continue; fi   # OpenTofu manages it — leave it
      echo "deleting orphaned VM: $inst"
      multipass delete "$inst"
      found=1
    done
    if [ "$found" -eq 1 ]; then multipass purge; else echo "no orphaned VMs for {{CLUSTER}}"; fi

# destroy (incl. orphan cleanup) then bring the cluster back up. If CLUSTER is one of the 3
# cross-cluster hubs, its IP just churned — automatically refresh every dependent cluster's
# wiring afterward. Plain consumer recreates are unaffected (their own recreate never stales
# anyone else's config).  just recreate centralized_logging
recreate CLUSTER: (destroy CLUSTER) (up CLUSTER)
    #!/usr/bin/env bash
    set -uo pipefail
    case "{{CLUSTER}}" in
      centralized_dns|centralized_logging|centralized_monitoring)
        echo "=== {{CLUSTER}} is a cross-cluster hub — refreshing dependent wiring ==="
        just refresh-cross-cluster
        ;;
      *) ;;
    esac

# hermetic: fmt + validate + tofu test (no VMs):  just check (centralized_logging|centralized_monitoring)
check CLUSTER: (init CLUSTER)
    tofu -chdir={{cluster_root}}/{{CLUSTER}} fmt -check -recursive
    tofu -chdir={{cluster_root}}/{{CLUSTER}} validate
    tofu -chdir={{cluster_root}}/{{CLUSTER}} test -test-directory=tests/tofu

# live: pytest + testinfra over SSH:  just verify (centralized_logging|centralized_monitoring)
verify CLUSTER:
    cd {{cluster_root}}/{{CLUSTER}}/tests/testinfra && uv run pytest -v

# run the live testinfra suite for every cluster that has one:  just verify-all
verify-all:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for dir in {{cluster_root}}/*/tests/testinfra; do
      [ -d "$dir" ] || continue
      cluster="$(basename "$(dirname "$(dirname "$dir")")")"
      echo "=== verify: $cluster ==="
      just verify "$cluster" || rc=1
    done
    exit "$rc"

# live e2e for the cross-cluster wiring (after `just up-connected`):  just verify-connected
# 1) a centralized_pki VM's log line reaches the logging hub; 2) Prometheus scrapes the pki VMs;
# 3) a consumer VM resolves through the centralized_dns AdGuard hub + Prometheus scrapes it.
verify-connected:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    dns_ip="$(tofu -chdir={{cluster_root}}/centralized_dns output -raw dns_endpoint)"
    log_ip="$(tofu -chdir={{cluster_root}}/centralized_logging output -raw central_ipv4)"
    pki_ip="$(tofu -chdir={{cluster_root}}/centralized_pki output -json hosts | jq -r '.services.ipv4')"
    token="xcheck-$(tofu -chdir={{cluster_root}}/centralized_pki output -raw services_ipv4 | tr -d '.')"

    echo "=== verify-connected: log shipping (pki -> logging hub) ==="
    ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$pki_ip" "logger -t xcheck $token" || rc=1
    ok=1
    for i in $(seq 1 12); do
      if ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$log_ip" "sudo grep -rqs $token /var/log/remote/"; then ok=0; break; fi
      sleep 5
    done
    if [ "$ok" -eq 0 ]; then echo "PASS: pki log line reached the logging hub"; else echo "FAIL: token not found on the hub"; rc=1; fi

    echo "=== verify-connected: metrics scrape (Prometheus -> pki VMs) ==="
    just prometheus-query centralized_monitoring 'up{job=~"centralized-pki.*"}' || rc=1

    echo "=== verify-connected: DNS resolver wiring (pki VM -> centralized_dns) ==="
    if ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$pki_ip" "resolvectl status 2>/dev/null | grep -q $dns_ip || grep -q $dns_ip /etc/systemd/resolved.conf.d/99-centralized-dns.conf 2>/dev/null"; then
      echo "PASS: pki VM resolver points at the AdGuard hub ($dns_ip)"
    else
      echo "FAIL: pki VM resolver is not pointed at $dns_ip"; rc=1
    fi
    echo "=== verify-connected: metrics scrape (Prometheus -> dns hub) ==="
    just prometheus-query centralized_monitoring 'up{job=~"centralized-dns.*"}' || rc=1

    echo "=== verify-connected: time sync (pki VM clock synchronized) ==="
    if ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$pki_ip" "timedatectl show -p NTP --value | grep -qx yes && timedatectl show -p NTPSynchronized --value | grep -qx yes"; then
      echo "PASS: pki VM clock is synchronized (NTP=yes)"
    else
      echo "FAIL: pki VM clock not synchronized"; rc=1
    fi
    # When the fleet was wired with INTERNAL_NTP, assert the consumer disciplines against the DNS hub.
    if [ -n "${INTERNAL_NTP:-}" ]; then
      echo "=== verify-connected: internal NTP source (pki VM -> centralized_dns chrony) ==="
      if ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$pki_ip" "grep -qs $dns_ip /etc/systemd/timesyncd.conf.d/99-centralized-ntp.conf"; then
        echo "PASS: pki VM timesyncd points at the internal NTP hub ($dns_ip)"
      else
        echo "FAIL: pki VM is not pointed at the internal NTP hub $dns_ip"; rc=1
      fi
    fi
    exit "$rc"

# reconcile Heimdall tiles (generate -> sync --prune):  just heimdall-sync centralized_monitoring
heimdall-sync CLUSTER:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="{{cluster_root}}/{{CLUSTER}}"
    tmp="$(mktemp -t heimdall-tiles.XXXXXX.yaml)"
    trap 'rm -f "$tmp"' EXIT
    uv run "$dir/scripts/heimdall_cli.py" generate --chdir "$dir" -o "$tmp"
    uv run "$dir/scripts/heimdall_cli.py" sync --chdir "$dir" --config "$tmp" --prune

# list Heimdall tiles:  just heimdall-list centralized_monitoring
heimdall-list CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/heimdall_cli.py list --chdir {{cluster_root}}/{{CLUSTER}}

# add a single tile:  just heimdall-add centralized_monitoring "Grafana" "http://<ip>:3000"
heimdall-add CLUSTER TITLE URL:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/heimdall_cli.py add --chdir {{cluster_root}}/{{CLUSTER}} --title {{quote(TITLE)}} --url {{quote(URL)}}

# remove a single tile (soft delete):  just heimdall-rm centralized_monitoring "Grafana"
heimdall-rm CLUSTER TITLE:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/heimdall_cli.py remove --chdir {{cluster_root}}/{{CLUSTER}} --title {{quote(TITLE)}}

# --- service verification CLIs (see specs/cli-*.md) --------------------------
# Host-side API introspection + verification for Grafana/Prometheus/OpenObserve (monitoring)
# and NetBox. Each resolves the server from `tofu output` (VMs must be up) or accepts --server-url. The
# `*-check` recipes exit nonzero on failure (CI-friendly). --cluster precedes the
# subcommand because global options live on the CLI's callback.

# run every service CLI's `check` for a cluster (auto-discovered):  just verify-api centralized_monitoring
# Iterates the cluster's scripts/*_cli.py, skipping helpers (_*) and heimdall_cli (no `check`
# subcommand — it manages dashboard tiles). So centralized_monitoring runs grafana/prometheus/
# openobserve and centralized_netbox runs netbox — no per-cluster edit needed.
verify-api CLUSTER:
    #!/usr/bin/env bash
    set -uo pipefail
    shopt -s nullglob
    rc=0
    for cli in {{cluster_root}}/{{CLUSTER}}/scripts/*_cli.py; do
      name="$(basename "$cli" .py)"
      case "$name" in _*|heimdall_cli) continue ;; esac
      echo "=== $name check: {{CLUSTER}} ==="
      # OpenObserve additionally asserts ingestion is live (metrics via remote_write, logs via OTel).
      extra=""
      [ "$name" = openobserve_cli ] && extra="--require-metrics --require-logs"
      uv run "$cli" --cluster {{CLUSTER}} check $extra || rc=1
    done
    exit "$rc"

# Grafana health + datasources + dashboards, exit nonzero on failure:  just grafana-check centralized_monitoring
grafana-check CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/grafana_cli.py --cluster {{CLUSTER}} check

# list Grafana datasources:  just grafana-datasources centralized_monitoring
grafana-datasources CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/grafana_cli.py --cluster {{CLUSTER}} datasources

# list Grafana dashboards:  just grafana-dashboards centralized_monitoring
grafana-dashboards CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/grafana_cli.py --cluster {{CLUSTER}} dashboards

# Prometheus scrape health (fails on any down target), exit nonzero:  just prometheus-check centralized_monitoring
prometheus-check CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/prometheus_cli.py --cluster {{CLUSTER}} check

# instant PromQL:  just prometheus-query centralized_monitoring 'up'
prometheus-query CLUSTER PROMQL:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/prometheus_cli.py --cluster {{CLUSTER}} query {{quote(PROMQL)}}

# per-target scrape health:  just prometheus-targets centralized_monitoring
prometheus-targets CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/prometheus_cli.py --cluster {{CLUSTER}} targets

# OpenObserve health + auth + ingestion (metrics + logs), exit nonzero:  just openobserve-check centralized_monitoring
openobserve-check CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/openobserve_cli.py --cluster {{CLUSTER}} check --require-metrics --require-logs

# list OpenObserve ingest streams:  just openobserve-streams centralized_monitoring
openobserve-streams CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/openobserve_cli.py --cluster {{CLUSTER}} streams

# SQL search over a stream:  just openobserve-search centralized_monitoring 'SELECT * FROM default'
openobserve-search CLUSTER SQL:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/openobserve_cli.py --cluster {{CLUSTER}} search {{quote(SQL)}}

# --- PKI verification CLIs (see specs/cli-{stepca,authelia,vaultwarden,tls}.md) --------------
# Host-side API + TLS verification for step-ca/Authelia/Vaultwarden. Each resolves the server
# from `tofu output` (VMs must be up) or accepts --server-url. The `*-check` recipes exit nonzero
# on failure (CI-friendly). --cluster precedes the subcommand (global options live on the callback).

# run all PKI service checks + cert-chain checks for auth./warden.:  just verify-pki centralized_pki
verify-pki CLUSTER:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for svc in stepca authelia vaultwarden; do
      echo "=== $svc check: {{CLUSTER}} ==="
      uv run {{cluster_root}}/{{CLUSTER}}/scripts/${svc}_cli.py --cluster {{CLUSTER}} check || rc=1
    done
    domain=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -raw domain 2>/dev/null || true)
    svc_ip=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -raw services_ipv4 2>/dev/null || true)
    if [ -n "$domain" ] && [ -n "$svc_ip" ]; then
      for h in auth warden; do
        echo "=== tls check: $h.$domain ==="
        uv run {{cluster_root}}/{{CLUSTER}}/scripts/tls_cli.py --cluster {{CLUSTER}} check "$svc_ip" --sni "$h.$domain" || rc=1
      done
    fi
    exit "$rc"

# step-ca health + ACME provisioner + served root, exit nonzero on failure:  just stepca-check centralized_pki
stepca-check CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/stepca_cli.py --cluster {{CLUSTER}} check

# list step-ca provisioners:  just stepca-provisioners centralized_pki
stepca-provisioners CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/stepca_cli.py --cluster {{CLUSTER}} provisioners

# Authelia up + forward-auth enforcing, exit nonzero on failure:  just authelia-check centralized_pki
authelia-check CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/authelia_cli.py --cluster {{CLUSTER}} check

# Vaultwarden liveness, exit nonzero on failure:  just vaultwarden-check centralized_pki
vaultwarden-check CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/vaultwarden_cli.py --cluster {{CLUSTER}} check

# assert a Traefik-served host's cert (chains to step-ca root, or is LE staging):  just tls-check centralized_pki <services-ip> --sni warden.<domain>
tls-check CLUSTER HOST *ARGS:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/tls_cli.py --cluster {{CLUSTER}} check {{HOST}} {{ARGS}}

# --- Fleet-edge Traefik (see specs/dynamic-traefik.md) -------------------------
# centralized_pki's Traefik is the fleet-wide reverse-proxy edge. Every cluster with a
# `reverse_proxy_routes` output is discovered, aggregated, and hot-pushed into Traefik's watched
# dynamic dir (no VM recreate, no container restart — the file provider reloads on change).

# print the resolved fleet routes (no push):  just traefik-targets
traefik-targets:
    uv run {{cluster_root}}/centralized_pki/scripts/traefik_cli.py targets

# render fleet.yaml locally, no push (eyeball before syncing):  just traefik-render
traefik-render:
    uv run {{cluster_root}}/centralized_pki/scripts/traefik_cli.py render

# render + scp + install fleet.yaml onto the running pki services VM, no restart:  just traefik-sync
traefik-sync:
    uv run {{cluster_root}}/centralized_pki/scripts/traefik_cli.py sync

# probe every fleet route's backend through the edge, exit nonzero on failure:  just traefik-check
traefik-check:
    uv run {{cluster_root}}/centralized_pki/scripts/traefik_cli.py check

# print an /etc/hosts block for every fleet route (laptops not using AdGuard as resolver):  just traefik-hosts
traefik-hosts:
    uv run {{cluster_root}}/centralized_pki/scripts/traefik_cli.py hosts

# --- Internal-CA trust distribution (see specs/internal-ca.md) ----------------
# Fleet-wide trust of the internal root CA is normally baked in at first boot by `just up-connected`
# (the internal_ca_cert var). These recipes HOT-PUSH the root onto already-running VMs — repair a VM
# without a full recreate, or trust a cluster brought up with a plain `just up`. Source of the root:
# the pinned clusters/centralized_pki/.ca/root_ca.crt (scripts/init_ca.py); if that's absent, fetch
# step-ca's current root from the CA's /roots.pem TOFU endpoint.

# install/refresh the internal root CA on every running VM of a cluster (no recreate):  just trust-ca centralized_netbox
trust-ca CLUSTER:
    #!/usr/bin/env bash
    set -euo pipefail
    ca_crt="{{cluster_root}}/centralized_pki/.ca/root_ca.crt"
    tmp="$(mktemp -t internal-root-ca.XXXXXX.crt)"
    trap 'rm -f "$tmp"' EXIT
    if [ -f "$ca_crt" ]; then
      cp "$ca_crt" "$tmp"
      echo "trust-ca: using pinned root $ca_crt"
    else
      ca_ip="$(tofu -chdir={{cluster_root}}/centralized_pki output -raw ca_ipv4)"
      echo "trust-ca: no pinned root — fetching https://$ca_ip:9000/roots.pem (TOFU)"
      curl -fsSk "https://$ca_ip:9000/roots.pem" -o "$tmp"
    fi
    tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.[].ipv4' | while read ip; do
      echo "=== trust-ca: {{CLUSTER}} @ $ip ==="
      scp {{ssh_opts}} -i {{ssh_key}} "$tmp" ubuntu@"$ip":/tmp/internal-root-ca.crt
      ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" \
        'sudo cp /tmp/internal-root-ca.crt /usr/local/share/ca-certificates/internal-root-ca.crt && sudo update-ca-certificates'
    done

# install/refresh the internal root CA on every VM of every cluster (glob-discovered):  just trust-ca-all
trust-ca-all:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for dir in {{cluster_root}}/*/; do
      cluster="$(basename "$dir")"
      [ -f "$dir/main.tf" ] || continue   # skip non-cluster dirs like _shared/
      echo "=== trust-ca: $cluster ==="
      just trust-ca "$cluster" || rc=1
    done
    exit "$rc"

# install/refresh the internal root CA into the macOS host trust store (Chrome/Safari + Firefox):  just trust-ca-macos
# Mutates the login/System keychain + Firefox NSS DBs, so it prints what it will do and prompts.
trust-ca-macos *ARGS:
    uv run {{cluster_root}}/centralized_pki/scripts/macos_trust_cli.py {{ARGS}} install

# assert the monitoring stack's Traefik leaf chains to the internal root (via centralized_pki):  just tls-check-monitoring
tls-check-monitoring *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    mon_ip="$(tofu -chdir={{cluster_root}}/centralized_monitoring output -raw server_ipv4)"
    domain="$(tofu -chdir={{cluster_root}}/centralized_monitoring output -raw domain 2>/dev/null || echo lab.theblacktonystark.com)"
    uv run {{cluster_root}}/centralized_pki/scripts/tls_cli.py --cluster centralized_pki check "$mon_ip" --sni "grafana.$domain" {{ARGS}}

# NetBox health + auth + self-registration, exit nonzero on failure:  just netbox-check centralized_netbox
netbox-check CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/netbox_cli.py --cluster {{CLUSTER}} check

# NetBox versions + health (GET /api/status/):  just netbox-status centralized_netbox
netbox-status CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/netbox_cli.py --cluster {{CLUSTER}} status

# list registered virtual machines:  just netbox-vms centralized_netbox
netbox-vms CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/netbox_cli.py --cluster {{CLUSTER}} vms

# list virtualization clusters:  just netbox-clusters centralized_netbox
netbox-clusters CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/netbox_cli.py --cluster {{CLUSTER}} clusters

# Diode plugin status + discovered IPs (opt-in discovery):  just netbox-discovery centralized_netbox
netbox-discovery CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/netbox_cli.py --cluster {{CLUSTER}} discovery

# trigger an on-demand orb-agent scan (opt-in; needs enable_discovery):  just netbox-discover centralized_netbox
netbox-discover CLUSTER:
    @ip=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.agent.ipv4 // ""'); \
     if [ -z "$ip" ]; then echo "no agent VM — set enable_discovery=true and 'just recreate {{CLUSTER}}'"; exit 1; fi; \
     ssh {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" 'sudo systemctl restart orb-agent.service'; \
     echo "orb-agent restarted on $ip — a scan will run; re-check with: just netbox-check {{CLUSTER}}"

# AdGuard Home running + forwarding to the local Unbound upstream, exit nonzero:  just adguard-check centralized_dns
adguard-check CLUSTER="centralized_dns":
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/adguard_cli.py --cluster {{CLUSTER}} check

# AdGuard Home status / stats / filters:  just adguard-status centralized_dns
adguard-status CLUSTER="centralized_dns":
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/adguard_cli.py --cluster {{CLUSTER}} status

# Unbound reachable via its exporter (:9167), exit nonzero:  just unbound-check centralized_dns
unbound-check CLUSTER="centralized_dns":
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/unbound_cli.py --cluster {{CLUSTER}} check

# key Unbound resolver stats (via unbound_exporter):  just unbound-stats centralized_dns
unbound-stats CLUSTER="centralized_dns":
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/unbound_cli.py --cluster {{CLUSTER}} stats

# both DNS service checks (AdGuard + Unbound), exit nonzero on any failure:  just dns-check
dns-check CLUSTER="centralized_dns":
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    just adguard-check {{CLUSTER}} || rc=1
    just unbound-check {{CLUSTER}} || rc=1
    exit "$rc"

# import the OpenObserve log dashboards (idempotent; see specs/openobserve-dashboards.md):  just openobserve-dashboards centralized_monitoring
# afterwards `... check --require-dashboards` asserts they resolve (not in verify-api since import is on-demand).
openobserve-dashboards CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/openobserve_cli.py --cluster {{CLUSTER}} dashboards import

# list installed OpenObserve dashboards:  just openobserve-dashboards-list centralized_monitoring
openobserve-dashboards-list CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/openobserve_cli.py --cluster {{CLUSTER}} dashboards list

# --- Locust load generators (host-run; resolve VM IPs from tofu; see specs/locustio.md) ---
# Drive live traffic into a cluster's dashboards. `*FLAGS` pass through to the CLI's callback
# (e.g. -u/-r/-t, --server-url). No flag = interactive web UI on http://localhost:8089.

# launch Locust web UI against a cluster:  just locust centralized_monitoring
locust CLUSTER *FLAGS:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/locust_cli.py --cluster {{CLUSTER}} {{FLAGS}} run

# headless run (pass -u/-r/-t via FLAGS):  just locust-headless centralized_monitoring -u 20 -r 5 -t 2m
locust-headless CLUSTER *FLAGS:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/locust_cli.py --cluster {{CLUSTER}} --headless {{FLAGS}} run

# short smoke run -> exit code (requests fired, zero failures):  just locust-check centralized_monitoring
locust-check CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/locust_cli.py --cluster {{CLUSTER}} check

# print the resolved endpoints Locust will drive (no load):  just locust-targets centralized_monitoring
locust-targets CLUSTER *FLAGS:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/locust_cli.py --cluster {{CLUSTER}} {{FLAGS}} targets

# multipass list
status:
    multipass list

# gracefully stop every multipass VM (preserves them; use `just up`/`multipass start` to resume)
stop:
    multipass stop --all

alias down := stop

# shell onto the <name>-<role> VM:  just ssh centralized_logging central   (roles: logging=central|k0s|docker, monitoring=server|k0s)
ssh CLUSTER ROLE:
    @ip=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.{{ROLE}}.ipv4'); \
     ssh {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip"

# triage provisioning problems: sweep journals & highlight the root cause (3 tries, exp backoff):  just system-debug centralized_pki [services]
# interactive wrapper — "issues found" (exit 2) is the normal case here, so it doesn't fail the recipe.
# For the meaningful exit code (CI / the /system-debug command) call `uv run tools/system_debug.py ... --json` directly.
system-debug CLUSTER ROLE="":
    @uv run tools/system_debug.py {{CLUSTER}} {{ROLE}} || true

# no flag -> core human dashboards;  --full (or --all) -> + every enabled /metrics endpoint.
# Override the browser with BROWSER_APP=...; falls back to the macOS default browser.
# open cluster dashboards in the browser:  just open (centralized_logging|centralized_monitoring) [--full|--all]
open CLUSTER *FLAGS:
    #!/usr/bin/env bash
    set -euo pipefail
    key=core
    for f in {{FLAGS}}; do case "$f" in --full|--all) key=all ;; esac; done
    urls=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json web_urls | jq -r ".${key}[]")
    if [ -z "$urls" ]; then
      echo "no URLs for {{CLUSTER}} — is it up?  try: just up {{CLUSTER}}" >&2
      exit 1
    fi
    while IFS= read -r u; do
      echo "open $u"
      open -a "${BROWSER_APP:-Google Chrome}" "$u" 2>/dev/null || open "$u"
      sleep 0.25
    done <<< "$urls"

# open dashboards for every cluster (glob-discovered; --full adds /metrics endpoints):  just open-all [--full]
open-all *FLAGS:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for dir in {{cluster_root}}/*/; do
      cluster="$(basename "$dir")"
      [ -f "$dir/main.tf" ] || continue   # skip non-cluster dirs like _shared/
      echo "=== open: $cluster ==="
      just open "$cluster" {{FLAGS}} || rc=1
    done
    exit "$rc"

# list collected log files (central VM):  just logs centralized_logging
logs CLUSTER:
    @ip=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.central.ipv4'); \
     ssh {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" 'sudo find /var/log/remote -type f'

# --- Coroot (opt-in eBPF observability on the k0s node; see specs/coroot.md) --------------
# These target the k0s VM. Requires the cluster up with enable_coroot=true.

# show the Coroot stack pod status (k0s VM):  just coroot-status centralized_logging
coroot-status CLUSTER:
    @ip=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.k0s.ipv4'); \
     ssh {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" 'sudo /usr/local/bin/k0s kubectl get pods -n coroot -o wide'

# (re)run the Coroot installer on the k0s VM — idempotent repair without a full recreate:  just coroot-deploy centralized_logging
coroot-deploy CLUSTER:
    @ip=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.k0s.ipv4'); \
     ssh {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" 'sudo /usr/local/sbin/coroot-install.sh'

# report the Netdata agent (:19999) status on every VM in the cluster:  just netdata-status centralized_logging
netdata-status CLUSTER:
    @tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r 'to_entries[] | "\(.key) \(.value.ipv4)"' | \
     while read role ip; do \
       state=$(ssh {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" 'systemctl is-active netdata 2>/dev/null' || echo unreachable); \
       printf '%-10s %-16s netdata=%s\n' "$role" "$ip" "$state"; \
     done

# Logs for the k0s controller and worker nodes
logs-k0s:
  @ip=$(tofu -chdir=clusters/centralized_k0s output -json hosts | jq -r '."controller-1".ipv4'); \
   ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@"$ip" sudo journalctl -f

# Logs for the k0s worker node
logs-k0s-worker:
  @ip=$(tofu -chdir=clusters/centralized_k0s output -json hosts | jq -r '."worker-1".ipv4'); \
   ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 ubuntu@"$ip" sudo journalctl -f

# generalized live journal tail for any cluster/role — background it (redirect to scratchpad/<cluster>-<role>.log)
# and grep against `uv run tools/print_signatures.py` to catch provisioning errors early, per specs/pki-and-dns.md
# and specs/ha-dns.md's "Live provisioning watch" (fixes logs-k0s/logs-k0s-worker's missing ConnectTimeout/BatchMode —
# those two stay as-is for now, kept independently available for quick k0s feedback loops):
#   just tail-log centralized_dns primary
tail-log CLUSTER ROLE:
  @ip=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.{{ROLE}}.ipv4'); \
   ssh -n {{ssh_opts}} -o BatchMode=yes -i {{ssh_key}} ubuntu@"$ip" 'sudo journalctl -f -o short-iso -p warning'

# --- centralized_dns HA (opt-in enable_ha; see specs/ha-dns.md) --------------------------------

# live: kill AdGuard Home on whichever HA node currently holds the VIP, assert the VIP moves to
# the other node within a few seconds and keeps answering DNS, then restart AdGuard and assert it
# preempts back to primary. Requires enable_ha=true and the cluster up.  just dns-failover-test centralized_dns
dns-failover-test CLUSTER:
    #!/usr/bin/env bash
    set -uo pipefail
    vip="$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -raw vip_address 2>/dev/null || true)"
    if [ -z "$vip" ]; then
      echo "{{CLUSTER}} has no vip_address — is enable_ha=true and the cluster up?" >&2
      exit 1
    fi
    primary_ip="$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.primary.ipv4')"
    secondary_ip="$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.secondary.ipv4')"

    if ! dig +time=2 +tries=1 +short @"$vip" example.com >/dev/null 2>&1; then
      echo "FAIL: VIP $vip is not answering DNS before the test even starts" >&2
      exit 1
    fi

    # find which node currently holds the VIP.
    holder=""
    for role_ip in "primary:$primary_ip" "secondary:$secondary_ip"; do
      role="${role_ip%%:*}"; ip="${role_ip#*:}"
      if ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" "ip addr show | grep -q $vip"; then
        holder="$role"; holder_ip="$ip"
        break
      fi
    done
    if [ -z "$holder" ]; then
      echo "FAIL: no node currently holds the VIP $vip" >&2
      exit 1
    fi
    echo "VIP $vip is currently held by: $holder ($holder_ip)"

    echo "=== stopping AdGuardHome on $holder to force failover ==="
    ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$holder_ip" 'sudo systemctl stop AdGuardHome'

    ok=1
    for i in $(seq 1 10); do
      if dig +time=1 +tries=1 +short @"$vip" example.com >/dev/null 2>&1; then ok=0; break; fi
      sleep 1
    done
    if [ "$ok" -eq 0 ]; then
      echo "PASS: VIP $vip still answers DNS within 10s of stopping AdGuard on $holder"
    else
      echo "FAIL: VIP $vip stopped answering after stopping AdGuard on $holder" >&2
    fi

    echo "=== restarting AdGuardHome on $holder ==="
    ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$holder_ip" 'sudo systemctl start AdGuardHome'
    sleep 3
    if [ "$holder" = "primary" ]; then
      echo "PASS: primary is back — preemption is a no-op since primary never lost the VIP holder role in this run"
    else
      preempted=1
      for i in $(seq 1 10); do
        if ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$primary_ip" "ip addr show | grep -q $vip"; then preempted=0; break; fi
        sleep 1
      done
      [ "$preempted" -eq 0 ] && echo "PASS: VIP preempted back to primary" || echo "FAIL: VIP did not preempt back to primary within 10s" >&2
    fi
    exit "$ok"

# live: tail AdGuardHome-Sync's recent journal on primary (thin wrapper over adguard_cli.py sync-status).
# Requires enable_ha=true and the cluster up.  just dns-sync-status centralized_dns
dns-sync-status CLUSTER:
    @uv run {{cluster_root}}/{{CLUSTER}}/scripts/adguard_cli.py --cluster {{CLUSTER}} sync-status