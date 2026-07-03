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
    @echo "  just verify-all            run the live testinfra suite for every cluster"
    @echo "  just open   CLUSTER [--full]  open dashboards (core; --full adds /metrics endpoints)"
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
# every consumer cluster ships logs to centralized_logging + pushes host logs to
# centralized_monitoring's OpenObserve, and Prometheus scrapes every consumer VM.  just up-connected
#
# Ordering resolves the logging<->monitoring cycle: logging (pure sink) and monitoring (OTLP/
# OpenObserve sink) come up FIRST so consumers learn both hub IPs and wire all three signals in a
# single boot (stable IPs, no recreate). Consumer scrape targets are then HOT-PUSHED into the
# already-running Prometheus (scp the re-rendered prometheus.yml + restart the container) so the
# monitoring VM is never recreated — which would churn the IP consumers push OTLP to.
up-connected:
    #!/usr/bin/env bash
    set -uo pipefail
    logging=centralized_logging
    monitoring=centralized_monitoring

    # 1. logging hub first — pure sink, depends on nobody.
    echo "=== up-connected: logging hub ($logging) ==="
    just up "$logging"
    log_ip="$(tofu -chdir={{cluster_root}}/$logging output -raw central_ipv4)"
    echo "    syslog-ng collector: $log_ip:514"

    # 2. monitoring hub next — brings up OpenObserve/OTLP + Prometheus so consumers can push. The
    #    logging hub is already up, so the monitoring hub ALSO ships its OWN OS logs there at first
    #    boot (log_shipping_target). No extra_scrape_targets yet — consumer IPs aren't known until
    #    step 3, and they're hot-pushed in step 4 without recreating this VM.
    echo "=== up-connected: monitoring hub ($monitoring) ==="
    jq -n --arg log "$log_ip:514" '{log_shipping_target: $log}' \
      > {{cluster_root}}/$monitoring/.cross-cluster.auto.tfvars.json
    just up "$monitoring"
    mon_ip="$(tofu -chdir={{cluster_root}}/$monitoring output -raw server_ipv4)"
    echo "    OpenObserve/OTLP sink: $mon_ip:5080"

    # 3. consumers — everything except the two hubs and non-cluster dirs. Single boot with BOTH
    #    hub IPs known: syslog shipping + OTLP push + node_exporter all wired at first boot.
    targets='[]'
    for dir in {{cluster_root}}/*/; do
      c="$(basename "$dir")"
      [ -f "$dir/main.tf" ] || continue
      case "$c" in "$logging"|"$monitoring") continue ;; esac
      echo "=== up-connected: consumer $c ==="
      jq -n --arg log "$log_ip:514" --arg oo "$mon_ip:5080" \
        '{log_shipping_target: $log, openobserve_endpoint: $oo}' \
        > "$dir/.cross-cluster.auto.tfvars.json"
      just up "$c"
      # accumulate this consumer's VM IPs as Prometheus scrape targets (node_exporter :9100)
      targets="$(tofu -chdir={{cluster_root}}/$c output -json hosts 2>/dev/null \
        | jq --argjson acc "$targets" \
            '$acc + [to_entries[] | {job: .value.name, ip: .value.ipv4, port: 9100}]')"
    done

    # 4. hot-push the discovered scrape targets into the RUNNING monitoring server (no recreate).
    #    Keep log_shipping_target so the re-apply preserves the hub's self-shipping wiring in state.
    echo "=== up-connected: wiring Prometheus scrape targets ==="
    echo "$targets" | jq -c --arg log "$log_ip:514" '{log_shipping_target: $log, extra_scrape_targets: .}' \
      > {{cluster_root}}/$monitoring/.cross-cluster.auto.tfvars.json
    tofu -chdir={{cluster_root}}/$monitoring apply -auto-approve   # re-renders .rendered/prometheus.yml only
    scp {{ssh_opts}} -i {{ssh_key}} \
      {{cluster_root}}/$monitoring/.rendered/prometheus.yml \
      ubuntu@"$mon_ip":/tmp/prometheus.yml
    ssh -n {{ssh_opts}} -i {{ssh_key}} ubuntu@"$mon_ip" \
      'sudo cp /tmp/prometheus.yml /opt/stack/prometheus/prometheus.yml && sudo docker compose -f /opt/stack/compose.yaml restart prometheus'
    echo "up-connected complete — $(echo "$targets" | jq 'length') cross-cluster scrape targets wired."

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
# 1) a centralized_pki VM's log line reaches the logging hub; 2) Prometheus scrapes the pki VMs.
verify-connected:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
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

# run all PKI service checks + cert-chain checks for auth./vault.:  just verify-pki centralized_pki
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
      for h in auth vault; do
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

# assert a Traefik-served host's cert (chains to step-ca root, or is LE staging):  just tls-check centralized_pki <services-ip> --sni vault.<domain>
tls-check CLUSTER HOST *ARGS:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/tls_cli.py --cluster {{CLUSTER}} check {{HOST}} {{ARGS}}

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
