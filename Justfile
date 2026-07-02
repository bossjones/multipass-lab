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
    @echo "  just verify CLUSTER        live: pytest + testinfra over SSH"
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
      uv run "$cli" --cluster {{CLUSTER}} check || rc=1
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

# OpenObserve health + auth, exit nonzero on failure:  just openobserve-check centralized_monitoring
openobserve-check CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/openobserve_cli.py --cluster {{CLUSTER}} check

# list OpenObserve ingest streams:  just openobserve-streams centralized_monitoring
openobserve-streams CLUSTER:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/openobserve_cli.py --cluster {{CLUSTER}} streams

# SQL search over a stream:  just openobserve-search centralized_monitoring 'SELECT * FROM default'
openobserve-search CLUSTER SQL:
    uv run {{cluster_root}}/{{CLUSTER}}/scripts/openobserve_cli.py --cluster {{CLUSTER}} search {{quote(SQL)}}

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
