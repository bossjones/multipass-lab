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
    @echo "  just up-connected          bring the whole fleet up wired for cross-cluster telemetry"
    @echo "  just verify CLUSTER        live: pytest + testinfra over SSH"
    @echo "  just verify-connected      live e2e for the cross-cluster wiring (after up-connected)"
    @echo "  just init-all              tofu init every cluster (glob-discovered)"
    @echo "  just verify-all            run the live testinfra suite for every cluster"
    @echo "  just open   CLUSTER [--full]  open dashboards (core; --full adds /metrics endpoints)"
    @echo "  just open-all [--full]     open dashboards for every cluster (glob-discovered)"
    @echo "  just ssh    CLUSTER ROLE   shell onto the <name>-<role> VM"
    @echo "  just destroy CLUSTER       tofu destroy + prune orphaned VMs (one cluster, gone)"
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
up CLUSTER: (init CLUSTER)
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
    exit "$rc"

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

    # 0. DNS hub FIRST — pure :53 sink. No telemetry targets yet (the hubs don't exist), but it DOES
    #    get the CA trust anchor at first boot (static, so no ordering dependency on the PKI hub).
    echo "=== up-connected: dns hub ($dns) ==="
    jq -n --arg ca "$ca_pem" '{internal_ca_cert: $ca}' \
      > {{cluster_root}}/$dns/.cross-cluster.auto.tfvars.json
    just up "$dns"
    dns_ip="$(tofu -chdir={{cluster_root}}/$dns output -raw server_ipv4)"
    echo "    AdGuard Home resolver: $dns_ip:53"
    # health-gate: do NOT wire anyone until AdGuard actually answers, else a dependent VM switches
    # its resolver at boot and cannot resolve archive.ubuntu.com. `dig` ships with macOS.
    echo "    waiting for AdGuard Home to answer DNS on $dns_ip:53 ..."
    for i in $(seq 1 60); do
      if dig +time=2 +tries=1 @"$dns_ip" example.com >/dev/null 2>&1; then break; fi
      sleep 5
    done

    # 1. logging hub — pure sink; now resolves via DNS + trusts the internal CA.
    echo "=== up-connected: logging hub ($logging) ==="
    jq -n --arg dns "$dns_ip" --arg ca "$ca_pem" '{dns_server: $dns, internal_ca_cert: $ca}' \
      > {{cluster_root}}/$logging/.cross-cluster.auto.tfvars.json
    just up "$logging"
    log_ip="$(tofu -chdir={{cluster_root}}/$logging output -raw central_ipv4)"
    echo "    syslog-ng collector: $log_ip:514"

    # 2. monitoring hub — resolves via DNS + trusts the internal CA + self-ships its OWN OS logs.
    echo "=== up-connected: monitoring hub ($monitoring) ==="
    # TLS (tls_json) must be set HERE — the VM is created by this `just up`, and use_internal_tls
    # gates the leaf-issuance cloud-init; the step-5 re-apply is content-only and won't recreate it.
    jq -n --arg dns "$dns_ip" --arg log "$log_ip:514" --arg ca "$ca_pem" --argjson tls "$tls_json" \
      '{dns_server: $dns, log_shipping_target: $log, internal_ca_cert: $ca} + $tls' \
      > {{cluster_root}}/$monitoring/.cross-cluster.auto.tfvars.json
    just up "$monitoring"
    mon_ip="$(tofu -chdir={{cluster_root}}/$monitoring output -raw server_ipv4)"
    echo "    OpenObserve/OTLP sink: $mon_ip:5080"

    # 3. consumers — everything except the three hubs and non-cluster dirs. Single boot with all
    #    hub IPs known: DNS resolver + syslog shipping + OTLP push + node_exporter, all at first boot.
    targets='[]'
    for dir in {{cluster_root}}/*/; do
      c="$(basename "$dir")"
      [ -f "$dir/main.tf" ] || continue
      case "$c" in "$dns"|"$logging"|"$monitoring") continue ;; esac
      echo "=== up-connected: consumer $c ==="
      jq -n --arg dns "$dns_ip" --arg log "$log_ip:514" --arg oo "$mon_ip:5080" --arg ca "$ca_pem" \
        '{dns_server: $dns, log_shipping_target: $log, openobserve_endpoint: $oo, internal_ca_cert: $ca}' \
        > "$dir/.cross-cluster.auto.tfvars.json"
      just up "$c"
      # accumulate this consumer's VM IPs as Prometheus scrape targets (node_exporter :9100)
      targets="$(tofu -chdir={{cluster_root}}/$c output -json hosts 2>/dev/null \
        | jq --argjson acc "$targets" \
            '$acc + [to_entries[] | {job: .value.name, ip: .value.ipv4, port: 9100}]')"
    done
    # add the DNS hub's OWN exporters (node :9100, adguard :9618, unbound :9167).
    targets="$(echo "$targets" | jq --arg ip "$dns_ip" \
      '. + [{job:"centralized-dns-server",ip:$ip,port:9100},
            {job:"centralized-dns-adguard",ip:$ip,port:9618},
            {job:"centralized-dns-unbound",ip:$ip,port:9167}]')"

    # 4. DNS-hub self-telemetry HOT-PUSH (mirrors the Prometheus scrape hot-push; no recreate):
    #    the DNS VM booted before the hubs, so wire its log shipping now. A targeted re-apply
    #    (content-only change — never recreates the VM) materializes the rendered drop-ins for scp.
    echo "=== up-connected: wiring DNS hub self-telemetry ==="
    jq -n --arg dns "$dns_ip" --arg log "$log_ip:514" --arg oo "$mon_ip:5080" --arg ca "$ca_pem" \
      '{log_shipping_target: $log, openobserve_endpoint: $oo, internal_ca_cert: $ca}' \
      > {{cluster_root}}/$dns/.cross-cluster.auto.tfvars.json
    tofu -chdir={{cluster_root}}/$dns apply -auto-approve   # re-renders .rendered/ drop-ins only
    scp {{ssh_opts}} -i {{ssh_key}} \
      {{cluster_root}}/$dns/.rendered/10-ship.conf ubuntu@"$dns_ip":/tmp/10-ship.conf
    scp {{ssh_opts}} -i {{ssh_key}} \
      {{cluster_root}}/$dns/.rendered/otel-config.yaml ubuntu@"$dns_ip":/tmp/otel-config.yaml
    ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$dns_ip" \
      'set -e; \
       sudo DEBIAN_FRONTEND=noninteractive apt-get install -y syslog-ng >/dev/null; \
       sudo mkdir -p /var/lib/syslog-ng /etc/syslog-ng/conf.d /var/lib/otelcol-contrib/storage; \
       sudo cp /tmp/10-ship.conf /etc/syslog-ng/conf.d/10-ship.conf; \
       grep -q "conf.d/\*.conf" /etc/syslog-ng/syslog-ng.conf || echo "@include \"/etc/syslog-ng/conf.d/*.conf\"" | sudo tee -a /etc/syslog-ng/syslog-ng.conf >/dev/null; \
       sudo systemctl enable syslog-ng >/dev/null 2>&1 || true; sudo systemctl restart syslog-ng; \
       if ! command -v otelcol-contrib >/dev/null 2>&1; then \
         V=0.109.0; A="$(dpkg --print-architecture)"; \
         curl -sSLf "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${V}/otelcol-contrib_${V}_linux_${A}.deb" -o /tmp/otelcol.deb; \
         sudo dpkg -i /tmp/otelcol.deb || sudo DEBIAN_FRONTEND=noninteractive apt-get install -f -y; \
       fi; \
       sudo cp /tmp/otel-config.yaml /etc/otelcol-contrib/config.yaml; \
       sudo systemctl enable otelcol-contrib >/dev/null 2>&1 || true; sudo systemctl restart otelcol-contrib'

    # 5. hot-push the discovered scrape targets into the RUNNING monitoring server (no recreate).
    #    Keep log_shipping_target + dns_server so the re-apply preserves the hub's wiring in state.
    echo "=== up-connected: wiring Prometheus scrape targets ==="
    # Preserve tls_json here too so the content-only re-apply keeps use_internal_tls in state/render
    # (it does NOT recreate the VM — the leaf was already issued at the step-2 boot).
    echo "$targets" | jq -c --arg dns "$dns_ip" --arg log "$log_ip:514" --arg ca "$ca_pem" --argjson tls "$tls_json" \
      '{dns_server: $dns, log_shipping_target: $log, internal_ca_cert: $ca, extra_scrape_targets: .} + $tls' \
      > {{cluster_root}}/$monitoring/.cross-cluster.auto.tfvars.json
    tofu -chdir={{cluster_root}}/$monitoring apply -auto-approve   # re-renders .rendered/prometheus.yml only
    scp {{ssh_opts}} -i {{ssh_key}} \
      {{cluster_root}}/$monitoring/.rendered/prometheus.yml \
      ubuntu@"$mon_ip":/tmp/prometheus.yml
    ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$mon_ip" \
      'sudo cp /tmp/prometheus.yml /opt/stack/prometheus/prometheus.yml && sudo docker compose -f /opt/stack/compose.yaml restart prometheus'

    # 6. Internal-CA TLS DNS records — make grafana.<domain> etc. resolve to the monitoring VM so
    #    browsers get the green lock by hostname. Hot-pushed into the running AdGuard hub (no recreate).
    if [ "$tls_json" != '{}' ]; then
      echo "=== up-connected: registering monitoring TLS hostnames in AdGuard ==="
      just dns-register "$monitoring"
    fi
    echo "up-connected complete — $(echo "$targets" | jq 'length') cross-cluster scrape targets wired; fleet resolving via $dns_ip."

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

# destroy (incl. orphan cleanup) then bring the cluster back up:  just recreate centralized_logging
recreate CLUSTER: (destroy CLUSTER) (up CLUSTER)

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
    dns_ip="$(tofu -chdir={{cluster_root}}/centralized_dns output -raw server_ipv4)"
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

# HOT-PUSH a cluster's internal-CA TLS hostnames (https:// web_urls) as AdGuard host rewrites -> the
# cluster's server VM, so browsers resolve grafana.<domain> etc. for the green lock. No recreate: it
# merges dns_rewrites into the DNS hub's tfvars, re-applies (content-only), scps the seed, restarts
# AdGuard. Called by `up-connected` when INTERNAL_TLS is on.  just dns-register centralized_monitoring
dns-register CLUSTER:
    #!/usr/bin/env bash
    set -euo pipefail
    dns=centralized_dns
    ip="$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.server.ipv4')"
    rewrites="$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json web_urls \
      | jq -c --arg ip "$ip" '[.core[] | select(startswith("https://")) \
          | {domain: (ltrimstr("https://") | split("/")[0]), answer: $ip}]')"
    n="$(echo "$rewrites" | jq 'length')"
    if [ "$n" -eq 0 ]; then echo "dns-register: {{CLUSTER}} has no https hostnames (use_internal_tls off?) — nothing to do"; exit 0; fi
    echo "dns-register: seeding $n AdGuard rewrite(s) -> $ip for {{CLUSTER}}"
    # Merge into the DNS hub's existing cross-cluster tfvars so its telemetry wiring is preserved.
    f="{{cluster_root}}/$dns/.cross-cluster.auto.tfvars.json"
    base='{}'; [ -f "$f" ] && base="$(cat "$f")"
    echo "$base" | jq --argjson rw "$rewrites" '. + {dns_rewrites: $rw}' > "$f"
    dns_ip="$(tofu -chdir={{cluster_root}}/$dns output -raw server_ipv4)"
    tofu -chdir={{cluster_root}}/$dns apply -auto-approve   # re-renders .rendered/AdGuardHome.yaml only; no recreate
    scp {{ssh_opts}} -i {{ssh_key}} \
      {{cluster_root}}/$dns/.rendered/AdGuardHome.yaml ubuntu@"$dns_ip":/tmp/AdGuardHome.yaml
    ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$dns_ip" \
      'sudo install -D -m0644 /tmp/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml && sudo systemctl restart AdGuardHome'
    echo "dns-register: {{CLUSTER}} hostnames now resolve to $ip via $dns_ip"

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
