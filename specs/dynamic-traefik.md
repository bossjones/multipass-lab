# Plan: fleet-edge Traefik (dynamic file provider, host CLI hot-push)

Status: **implemented** (adapted from the original plan — see "Deviations from the original plan"
below) · Task type: **feature** · Complexity: **complex**
Edge lives in: `centralized_pki` (extends the existing Traefik) · Reference precedent: the
Prometheus scrape-target hot-push in `Justfile` (`up-connected`, §5) and `specs/cross-cluster.md`
DNS/rewrite hub: `centralized_dns` (AdGuard Home) · k0s ingress: `centralized_logging` (ingress-nginx)

## Task Description

Make the Traefik instance already running in `centralized_pki` the **single reverse-proxy edge
for the whole fleet** — every human-facing service in every cluster reachable through it over TLS
at a stable hostname, instead of raw `IP:port`.

The routing table is **updatable dynamically and remotely** — no VM recreate, no Traefik restart.
This reuses the way the repo already hot-pushes `prometheus.yml`: a host-run **uv single-file CLI**
(`traefik_cli.py`) reads every cluster's `tofu output`, renders a fleet dynamic-config file, and
`scp`s it onto the Traefik VM, where Traefik's **file provider** (`directory` + `watch: true`)
hot-reloads it. The generated `fleet.yaml` sits in a watched directory *alongside* pki's existing
`dynamic.yaml`, which is left untouched.

**k0s clusters are treated as a black-box ingress, not re-implemented.** The fleet Traefik routes
to the k0s edge (NodePort, or ingress-nginx with a Host-rewrite) rather than becoming the
in-cluster ingress — Kubernetes owns everything inside the node.

## Deviations from the original plan

This plan was written before two things landed on `main`, both discovered mid-implementation:

1. **`centralized_monitoring` already has its own Traefik + TLS** (Phase 2 of
   `specs/pki-and-dns.md`, merged after this plan was drafted). It fronts Grafana/Prometheus/
   Alertmanager/OpenObserve/Uptime-Kuma at `<svc>.<domain>` directly, with its own `dns_records`.
   Routing those same hostnames through pki's edge too would be unreachable dead config (see #2)
   and would duplicate a problem already solved. **Monitoring is excluded from the fleet-edge
   contract.** Only `centralized_netbox`, `centralized_dns` (the AdGuard UI), and
   `centralized_logging` (Coroot, opt-in) declare `reverse_proxy_routes` — the clusters still
   without their own hostname+TLS story. `centralized_unifi` is also excluded: its "controller" VM
   is a syslog-ng stand-in with no real web UI to front.
2. **Every cluster already registers its own hostname directly in AdGuard** via a `dns_records`
   output + `just set-dns-all` (predates this plan). AdGuard's exact-match rewrites always win over
   a `*.<domain>` wildcard, so the plan's original Step 7/8 (a new `traefik_edge_ip` Terraform var
   + a wildcard rewrite baked into `AdGuardHome.yaml.tftpl` at boot) would have been silently
   unreachable for any host that already has its own `dns_records` entry — i.e. every host this
   plan actually cares about. **Fix:** `traefik_cli.py dns-rewrites` emits `{"<host>.<domain>":
   pki_ip}` for every fleet-fronted route (excluding pki's own auth/warden), and `just set-dns-all`
   / `just verify-dns` layer that mapping OVER the raw per-cluster `dns_records` merge (`jq '. *
   $fleet'` — later operand wins). A host the fleet edge claims resolves to pki's IP; everything
   else is unaffected. This is a **hot, REST-API-driven override** (mirrors how `dns_records` is
   already registered via `adguard_cli.py rewrite-sync`), not a Terraform variable / boot-time
   `AdGuardHome.yaml` change — no `just recreate centralized_dns` needed, and no new opt-in var on
   any consumer cluster.

Everything else below (directory file provider, `reverse_proxy_routes` output contract,
`traefik_cli.py`'s `targets`/`render`/`sync`/`check`/`hosts` subcommands, the k0s NodePort vs.
ingress-Host-rewrite handling, the `just traefik-*` recipes) was implemented as originally designed.

## Objective

After `just up-connected` (or `just traefik-sync` + `just set-dns-all`), a browser pointed at
`https://netbox.lab.theblacktonystark.com`, `https://adguard.lab.…`, `https://coroot.lab.…` (when
`enable_coroot`) reaches the right service in the right cluster through the one pki Traefik edge —
TLS served by step-ca's existing default cert, no port to remember. Adding, removing, or re-IPing a
service is a single `just traefik-sync` away — no recreate, no restart. `just check
centralized_pki`, `just verify centralized_pki`, and `just traefik-check` all pass.

## Problem Statement

1. **No clean hostname+TLS for most services.** `dns_records` already gives every cluster a stable
   `A`-record, but the caller still needs the raw port (`http://netbox.<domain>:8000`) and gets no
   TLS. Only `centralized_monitoring` has solved this for itself (Phase 2).
2. **No dynamic remote update path.** pki's Traefik read a **static** `dynamic.yaml` baked into
   cloud-init at boot. Re-pointing a router at a new backend IP meant editing a `.tftpl` and `just
   recreate` — a full VM rebuild.

The two missing pieces mirror `specs/cross-cluster.md`:

1. **Cross-state endpoint discovery** — pki's `main.tf` can only see its own `multipass_instance`
   resources, so it can't learn another cluster's DHCP IP to write a router for it.
2. **A remote, hot, no-restart update mechanism** for both the Traefik routing table AND the DNS
   rewrite that must point at it.

## Solution Approach

Reuse patterns the repo already ships:

- **Traefik's file provider in `directory`/`watch` mode.** pki's own base routes stay in
  `dynamic.yaml`; the fleet routes land in a separate `fleet.yaml`, both under
  `/opt/stack/traefik/dynamic/` (mounted `/etc/traefik/dynamic` in the container). Traefik merges
  every `*.yaml` in the directory and hot-reloads on any change.
- **The `prometheus.yml` hot-push idiom** (`Justfile` `up-connected` §5): `scp` + `ssh cp`, never a
  container restart, never a `tofu apply` that recreates a VM.
- **The `dns_records`/`rewrite-sync` idiom** (predates this plan): `traefik_cli.py dns-rewrites`
  produces the same `{hostname: ip}` shape `adguard_cli.py rewrite-sync` already consumes, so the
  fleet-edge override folds into the exact same REST-API-driven registration path every cluster's
  plain `dns_records` already uses — no new mechanism.

### The discovery + render + push loop

```
                          host (developer laptop)
  ┌───────────────────────────────────────────────────────────────────────┐
  │  traefik_cli.py sync                                                     │
  │    for each cluster dir with a main.tf:                                  │
  │      tofu -chdir=clusters/<c> output -json reverse_proxy_routes   ──┐    │
  │    aggregate routes ─► render fleet.yaml (routers + services)       │    │
  │    scp fleet.yaml  ubuntu@<pki_services_ip>:/tmp/fleet.yaml         │    │
  │    ssh 'sudo cp /tmp/fleet.yaml /opt/stack/traefik/dynamic/'  ──────┘    │
  └───────────────────────────────────────────────────────────────────────┘
                                   │  (no recreate, no restart)
                                   ▼
        centralized_pki  services VM  ──  Traefik v3.1  (file provider, directory + watch)
         /opt/stack/traefik/dynamic/dynamic.yaml   (base: auth., warden.)   [in cloud-init]
         /opt/stack/traefik/dynamic/fleet.yaml     (netbox., adguard., …)   [hot-pushed] ◄── reloads instantly
                                   │
      ┌────────────────────────────┼───────────────────────────────────────────┐
      ▼                            ▼                                            ▼
  netbox server VM             dns (AdGuard) server VM               logging k0s node
  NetBox :8000                 AdGuard Home UI :3000                 ingress-nginx :80  /  NodePort :30080
                                                                       (Coroot — Traefik routes to the
                                                                        k0s edge, does NOT replace it)

  just set-dns-all: merged_dns_records * traefik_cli.py dns-rewrites  ──► adguard_cli.py rewrite-sync
  (fleet-fronted hosts override their cluster's own direct-IP record; everything else unaffected)
```

### The routing contract: a per-cluster `reverse_proxy_routes` output

Each cluster that wants to be fronted publishes an explicit, hermetically-testable contract:

```hcl
output "reverse_proxy_routes" {
  description = "Routes the fleet-edge Traefik should publish for this cluster. Consumed by scripts/traefik_cli.py."
  value = [
    { host = "netbox", ip = multipass_instance.server.ipv4, port = var.netbox_port, scheme = "http", sso = false, k0s = false },
  ]
}
```

Field semantics:

| Field | Meaning |
|---|---|
| `host` | left-most label; the router rule becomes `Host(\`${host}.${domain}\`)` (domain from pki) |
| `ip` / `port` | upstream `loadBalancer` server (`${scheme}://${ip}:${port}`) |
| `scheme` | `http` (default) or `https` (for services that already terminate TLS internally) |
| `sso` | `true` → attach the Authelia forward-auth middleware (gate behind SSO) |
| `k0s` | `true` → this backend is a Kubernetes ingress/NodePort; apply the k0s handling below |
| `k0s_ingress_host` | only consulted when `k0s` routes through ingress-nginx (see below) |

`traefik_cli.py discover_routes()` aggregates `reverse_proxy_routes` across every cluster whose
apply is in state (tolerating clusters that aren't up — contributes nothing), and `render_fleet()`
renders one `fleet.yaml`, **skipping** `host in {"auth", "warden"}` (pki's own dynamic.yaml already
owns those Host() rules — a second router for the same rule would be a pointless duplicate/self-
loop) and raising loudly on a duplicate host claimed by two clusters.

### k0s handling (route to the ingress, don't replace it)

Two supported shapes, both encoded by `k0s = true`:

- **NodePort (recommended, simplest; what `centralized_logging`'s `coroot` route uses).** Service
  upstream = `http://<k0s_ip>:<nodeport>`. No Host-matching needed, so `render_fleet` adds no
  header-rewrite middleware for a port in the Kubernetes NodePort range (30000-32767).
- **ingress-nginx (when `enable_ingress`).** ingress-nginx routes by the ingress `Host`. For a k0s
  route whose port is **outside** the NodePort range, `render_fleet` emits a `headers` middleware
  (`customRequestHeaders: {Host: <k0s_ingress_host>}`) and `passHostHeader: false` on the service —
  otherwise ingress-nginx 404s.

### DNS: exact-override on the AdGuard hub (not a boot-time wildcard)

`just set-dns-all` merges every cluster's `dns_records`, then layers `traefik_cli.py
dns-rewrites`'s `{host.domain: pki_ip}` mapping on top (`jq '. * $fleet'` — the fleet edge wins for
the hosts it fronts) before calling the existing `adguard_cli.py rewrite-sync`. `just verify-dns`
does the same layering so its expectations match what was actually registered. `dns-rewrites` is
best-effort: it prints `{}` (not an error) when `centralized_pki` isn't up yet, so a plain
`set-dns-all` on a fleet without pki is unaffected.

## Files touched

- `clusters/centralized_pki/cloud-init/traefik/traefik.yaml.tftpl` — `providers.file.directory`
  (was `filename`), same `watch: true`.
- `clusters/centralized_pki/cloud-init/traefik/fleet.yaml.seed` — new; a valid empty dynamic doc
  shipped in cloud-init so the directory provider is happy before the first `traefik-sync`.
- `clusters/centralized_pki/cloud-init/services.yaml.tftpl` / `main.tf` — write both `dynamic.yaml`
  and the seeded `fleet.yaml` under `/opt/stack/traefik/dynamic/`.
- `clusters/{centralized_pki,centralized_netbox,centralized_dns,centralized_logging}/outputs.tf` —
  `reverse_proxy_routes` (+ hermetic `tests/tofu/*.tftest.hcl` assertions in each).
- `clusters/centralized_pki/scripts/traefik_cli.py` — new. `targets` / `render` / `sync` / `check`
  / `hosts` / `dns-rewrites`, `_pki_common`-based tofu resolution.
- `clusters/centralized_pki/tests/traefik/` — new hermetic suite (`render_fleet`, `probe_route`,
  `discover_routes`, CLI commands via `CliRunner`).
- `clusters/centralized_pki/tests/testinfra/test_fleet_edge.py` — new live e2e (auto-skips if the
  route hasn't been synced).
- `Justfile` — `traefik-targets`/`traefik-render`/`traefik-sync`/`traefik-check`/`traefik-hosts`;
  `traefik-sync` wired into `up-connected` and `refresh-cross-cluster`; `set-dns-all`/`verify-dns`
  fold in `dns-rewrites`.
- `specs/centralized_pki.md` — layout/testing sections updated.

## Acceptance Criteria

- `just check centralized_pki` and `just check` for netbox/dns/logging pass (hermetic, no VMs).
- Each participating cluster exposes a `reverse_proxy_routes` output with correct host/ip/port/k0s.
- `traefik_cli.py render` produces valid Traefik dynamic YAML from live `tofu output`; `sync`
  installs `fleet.yaml` onto the running pki VM **without a recreate or a restart**, visible in the
  Traefik dashboard (`:8080`).
- With the fleet up and synced, `https://netbox.<domain>` and (when `enable_coroot`)
  `https://coroot.<domain>` reach the correct backend over TLS through the single edge.
- `just traefik-check` exits 0 when every fleet backend is reachable, nonzero when one is down.
- `up-connected`/`refresh-cross-cluster` run `traefik-sync` at their tail; `set-dns-all`/
  `verify-dns` register/expect the fleet-edge override for fronted hosts.
- Adding/removing a route (edit a cluster's output → `just traefik-sync`) updates routing live, no
  restart.

## Notes

- **Why file provider over Redis/HTTP.** Redis adds a stateful store that must be re-seeded on
  every `just recreate` and a container to run. The file provider + host-CLI push reuses the exact
  `prometheus.yml` hot-push already proven in `up-connected`, needs no new service, and keeps the
  routing table diffable.
- **Why extend pki, not a new cluster.** The edge belongs where TLS (step-ca) and SSO (Authelia
  forward-auth) already live; a `centralized_traefik` cluster would duplicate both.
- **Ordering.** Step 1 (directory-mode switch) needs one `just recreate centralized_pki` (cloud-init
  content change alone doesn't recreate a VM). After that, all route changes are hot.
- **Security.** Throwaway lab VMs; the edge serves step-ca-issued TLS — browsers warn unless the
  step-ca root is trusted. `sso = true` routes gate behind Authelia; default `sso = false` matches
  today's open-on-the-lab-subnet posture. Do not carry this to Proxmox.
- **Future work.** (1) Drive routes from NetBox instead of `tofu output` (self-registration). (2) A
  Traefik `http` provider pointed at a small read-only endpoint the CLI publishes, eliminating the
  scp. (3) Bring `centralized_monitoring` onto the SAME edge (retire its own Phase-2 Traefik) once
  there's an appetite to consolidate two TLS edges into one. (4) `centralized_unifi` gets a route if
  it ever grows a real web UI.
