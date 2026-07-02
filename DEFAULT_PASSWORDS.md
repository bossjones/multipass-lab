# Default Passwords

> ⚠️ **Local Multipass lab defaults only.** Everything below is a throwaway dev
> credential baked into cloud-init for these local VMs. **Do NOT reuse any of these
> on a promoted/Proxmox target or anywhere real** — they exist so the lab boots with
> zero manual setup. Rotate/override before any of this leaves your laptop.

## Host name mapping

The `<server>` / `<docker>` / `<central>` / `<k0s>` placeholders below are the DHCP
IPs Multipass hands out at launch — they are not fixed. To resolve them:

```sh
just status                          # multipass list (all VMs + IPs)
tofu -chdir=clusters/<name> output hosts   # {role: {name, ipv4}} for a cluster
just open centralized_monitoring     # open the human dashboards in a browser
just open centralized_monitoring --full   # + every enabled /metrics endpoint
```

SSH onto any VM: `just ssh <cluster> <role>` (login user is `ubuntu`, key-based).

---

## centralized_monitoring

### Logins (real credentials)

| Service | URL / port | Username | Password |
|---|---|---|---|
| Grafana | `http://<server>:3000` | `admin` | `admin` |
| OpenObserve | `http://<server>:5080` | `admin@example.com` | `Complexpass#123` |
| Grafana → OpenObserve datasource | internal basic auth | `admin@example.com` | `Complexpass#123` |
| OTel Collector → OpenObserve | Basic auth header | `root@example.com` | `admin` |
| ssh_exporter probe module | `:9312` | `monitor` | `monitor` |
| Uptime Kuma | `http://<server>:3001` | *set on first visit* | *set on first visit* |
| SSH (all VMs) | — | `ubuntu` | *key-only, no password* |

- **Grafana** — `admin/admin`. Overridable: it's the `sensitive` var
  `grafana_admin_password` (default `"admin"`) — pass `-var grafana_admin_password=...`.
- **OpenObserve** — `admin@example.com` / `Complexpass#123` (strong value required; OO
  rejects weak passwords). The same pair is reused for Grafana's OpenObserve datasource
  basic auth, so the two must stay in sync.
- **OTel → OpenObserve header** — base64 `cm9vdEBleGFtcGxlLmNvbTphZG1pbg==` decodes to
  `root@example.com:admin`. ⚠️ This is a **known placeholder that does not match** the
  real OpenObserve root above — see `clusters/centralized_monitoring/docs/operations.md`
  ("Future work").
- **Uptime Kuma** — no baked-in default; you create the admin account on first browser visit.

### No login required (open by design)

Everything here binds `0.0.0.0` with no auth — it's a lab.

- **server VM**: Prometheus `:9090`, Alertmanager `:9093`, Heimdall `:80`,
  Traefik dashboard `:8082` (`--api.insecure=true`), blackbox `:9115`, node `:9100`,
  cAdvisor `:8080`, statsd `:9102` / `:8125`, OTLP receivers `:4317` / `:4318`,
  OTel self-metrics `:8888`, Vector `:8686` *(off by default)*.
- **k0s VM**: kubelet read-only `:10255` (HTTP, no auth — deliberate, scrape-friendly),
  k0s API `:6443`, node `:9100`, cAdvisor `:8089`, process `:9256`, netdata `:19999`,
  kube-state-metrics `:8081` (authenticates with a generated k0s admin kubeconfig),
  filestat `:9943`, plus several off-by-default exporters.

---

## centralized_logging

### Logins (real credentials)

| Service | URL / port | Username | Password |
|---|---|---|---|
| Grafana | `http://<docker>:3000` | `admin` | `admin` |
| SSH (all VMs) | — | `ubuntu` | *key-only, no password* |

Grafana `admin/admin` is this cluster's **only** real login — there is no OpenObserve,
ssh_exporter, or OTel credential here. Note the Grafana password is **hardcoded** in the
compose template (`GF_SECURITY_ADMIN_PASSWORD=admin`), unlike monitoring where it's a
tofu variable.

### No login required (open by design)

- **central VM**: syslog-ng TCP `:514` (no auth — accepts from any sender), node `:9100`,
  systemd `:9558`, journald `:12345` *(off by default)*, process `:9256`, filestat `:9943`.
- **k0s VM**: cAdvisor `:8089`, kube-proxy `:10249`, kubelet read-only `:10255`,
  kube-state-metrics `:8081`, node `:9100`.
- **docker VM**: Traefik `:80` / `:8080` / `:8082` (`--api.insecure=true`, no auth),
  Heimdall `:80`, Prometheus `:9090`, Alertmanager `:9093`, cAdvisor `:8089`.

---

## Notes

- **Grafana password source differs by cluster.** `centralized_monitoring` uses the
  overridable `sensitive` var `grafana_admin_password`; `centralized_logging` hardcodes
  it in `cloud-init/docker/compose.yaml.tftpl`. Both default to `admin/admin`.
- **OTel → OpenObserve auth is a known mismatch** (`root@example.com:admin` vs the real
  `admin@example.com` / `Complexpass#123`). Documented as future work; traces may not export.
- **Plaintext creds also land in generated artifacts.** The fully-rendered cloud-init in
  each cluster's `.rendered/*.yaml` and the `terraform.tfstate` contain these passwords in
  cleartext. Both are gitignored — keep it that way; don't commit them.
