# centralized_dns — usage

## Bring it up

```sh
just up centralized_dns
DNS_IP=$(tofu -chdir=clusters/centralized_dns output -raw dns_endpoint)
```

`dns_endpoint` is the single VM's IP by default, or the floating VIP once `enable_ha = true` (see
"HA mode" below) — it's what the rest of the fleet resolves against either way.

First boot installs Unbound (apt), runs the official AdGuard Home installer, and builds the two
DNS exporters from source (`go install`) — give it a few minutes. The cloud-init frees `:53` by
disabling the `systemd-resolved` stub (`DNSStubListener=no`) before AdGuard binds it.

## Point a client at it

```sh
dig @"$DNS_IP" example.com +short          # normal domain resolves (AdGuard -> Unbound)
dig @"$DNS_IP" doubleclick.net +short      # blocked -> 0.0.0.0 / empty
```

Across the fleet, `just up-connected` does this automatically: it applies `centralized_dns`
first and points every other VM's `systemd-resolved` at `$DNS_IP` at first boot.

## Inspect / verify from the host

```sh
just adguard-status centralized_dns        # AdGuard status
just adguard-check  centralized_dns        # running + forwarding to 127.0.0.1:5335 (exit code)
just unbound-stats  centralized_dns        # cache hits/misses, queries (via :9167)
just unbound-check  centralized_dns        # unbound_up == 1 (exit code)
just dns-check                             # both, exit nonzero on any failure
just verify-api centralized_dns            # auto-discovers both CLIs' `check`
```

The AdGuard Home web UI is at `http://$DNS_IP:3000` (`just open centralized_dns`). Credentials:
`tofu -chdir=clusters/centralized_dns output -json adguard_credentials` (dev-only — see
[DEFAULT_PASSWORDS.md](DEFAULT_PASSWORDS.md)).

## Metrics

`node_exporter` `:9100`, `adguard-exporter` `:9618`, `unbound_exporter` `:9167`
(+ process `:9256` / systemd `:9558` when enabled). `just open centralized_dns --full` opens
every enabled `/metrics` endpoint. `up-connected` adds all three to Prometheus.

## Iterating on cloud-init

**Do not** `just recreate centralized_dns` while the fleet is up-connected — recreating churns the
DNS IP and breaks every other VM's resolver (this is exactly what HA mode's VIP fixes — see
below). Instead SSH in, patch `/opt/AdGuardHome/AdGuardHome.yaml` or
`/etc/unbound/unbound.conf.d/centralized-dns.conf`, and `sudo systemctl restart AdGuardHome` /
`unbound`; then fold the fix back into the `.tftpl`.

## HA mode (opt-in)

```sh
# throwaway .auto.tfvars — outranks terraform.tfvars, see the root CLAUDE.md gotcha
cat > clusters/centralized_dns/ha.auto.tfvars <<'EOF'
enable_ha   = true
vip_address = "10.0.7.99"   # a free IP on the Multipass subnet
EOF
just recreate centralized_dns          # editing cloud-init (enable_ha flips it) needs recreate, not up
just verify   centralized_dns          # HA-aware: adds keepalived + sync + failover tests
just dns-failover-test centralized_dns # kill AdGuard on the VIP holder; assert it moves + preempts back
just dns-sync-status   centralized_dns # AdGuardHome-Sync journal on primary
```

`dns_endpoint` becomes the VIP; `tofu output -json hosts` becomes `{primary, secondary}` instead
of `{server}`. **Edit AdGuard config on `primary`'s real IP only** — `dns_rewrite_target` (what
`just set-dns-all` pushes to) and `adguard_cli.py`'s default target both resolve to `primary`,
never the VIP, but the web UI itself is reachable at either address; hitting `secondary` directly
is silently reverted on the next AdGuardHome-Sync cycle. Because HA is genuinely additive and
`dns_endpoint` — not `server_ipv4` — is the stable address, **recreating the DNS nodes in HA mode
no longer churns the address the fleet depends on**; the "do not recreate" gotcha above is a
single-mode-only constraint. See [`specs/ha-dns.md`](../../specs/ha-dns.md) and this cluster's
[`README.md`](README.md#ha-mode-opt-in-enable_ha) for the full design.
