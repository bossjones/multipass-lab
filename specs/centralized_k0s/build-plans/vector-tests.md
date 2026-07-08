# Build-plan: vector (📊) — Vector log-shipping config + the whole test suite

## Task Description

Write the Vector agent config and the **entire test suite** (hermetic tofu + live testinfra) plus
`docs/feature-flags.md` for `clusters/centralized_k0s/`. READ `specs/centralized_k0s.md` FIRST. You
own **only**:

```
clusters/centralized_k0s/cloud-init/vector/vector.toml.tftpl
clusters/centralized_k0s/tests/**            (tofu/*.tftest.hcl + testinfra/conftest.py + test_*.py)
clusters/centralized_k0s/docs/feature-flags.md
```

You are the **integration backstop**: your hermetic test IS the `just check` gate the LEAD runs, and
your testinfra suite IS the `just verify` gate. Assert on the OTHER agents' rendered output (k0sctl
config, cloud-init) so their work is validated. Coordinate var names with core (surface
`4ADFB530-0EE9-450A-830F-7A3FD6E4FC92`).

## Relevant Files (READ before writing)

- `specs/centralized_k0s.md` — §"Log shipping to centralized_logging — Vector" (the crux), §"Testing"
  (the hermetic + live assertion checklist is your spec), the exporter table.
- `specs/centralized_k0s/observability-logging.md` shard (backing Vector detail; umbrella wins).
- `clusters/centralized_netbox/tests/tofu/sizing_and_render.tftest.hcl` — hermetic shape:
  `mock_provider "multipass" {}`, file-level `variables {}` pinning opt-ins OFF (`:1-17`),
  `run "..." { command = plan; assert { condition = strcontains(...) / can(yamldecode(...)) } }`,
  incl. count-gated `[0]` asserts (`:451/:455`).
- `clusters/centralized_netbox/tests/testinfra/conftest.py` — `tofu_output`/`hosts` fixtures
  (`:32/:44`), `ssh_config_file` (`:88`), `_connect` (`:102`), the **skip-guarded conditional-role
  fixture** (`agent` at `:163`, skips when disabled), `_wait_for_marker` (`:122`) polling the async
  oneshot's `/var/lib/.../done`.
- `clusters/centralized_logging/docs/feature-flags.md` — structure to mirror (title → intro linking
  `variables.tf` → TOC → flag-matrix table → sections).
- `centralized_logging` syslog-ng server ingests **only syslog RFC5424/TCP:514** — that's why host
  logs go via socket+syslog codec (Vector has NO syslog sink).

## Step-by-Step Tasks — vector.toml.tftpl

Core passes: `log_shipping_target` (logging host:port), `openobserve_endpoint`, `openobserve_org`,
`openobserve_password`, **`openobserve_stream`** (NEW var), `hostname`/role. Gate the shipping sinks
on those vars being non-empty (turnkey when empty).

1. **Host + k0s-component logs:** `[sources.journald]` (journald source) → **`[sinks.syslog_out]`
   type `socket`, `mode = "tcp"`, `encoding.codec = "syslog"`** (RFC5424) → `centralized_logging:514`.
   Explicitly populate `HOSTNAME`/`APP-NAME` (a `remap`/VRL transform) so the hub's
   `keep-hostname(yes)` folders correctly.
2. **Pod logs (structured, NO K8s API):** `[sources.pod_logs]` type **`file`**, include
   `/var/log/pods/*/*/*.log` (present on all nodes now controllers run kubelet). A **`[transforms.*]`
   VRL** parses the path `/var/log/pods/<ns>_<pod>_<uid>/<container>/` → fields **namespace / pod /
   container** (NO `kubernetes_logs` source — it needs API access Vector lacks at boot; this is a
   locked decision). Two sinks:
   - **(a) OpenObserve** `[sinks.openobserve]` type **`http`**, URI
     `.../api/<org>/<stream>/_json` (uses `openobserve_org` + `openobserve_stream`), `auth.strategy =
     "basic"` (`auth.user`/`auth.password`), `encoding.codec = "json"`, **`buffer.when_full =
     "drop_newest"`** (a down hub must NOT back-pressure the archival path).
   - **(b)** a flat **socket/syslog** archival copy to `centralized_logging` (may split multiline; ok).
3. Keep multiline pod logs (stack traces) intact to OpenObserve; the syslog copy is archival.

## Step-by-Step Tasks — tests

### Hermetic: `tests/tofu/sizing_and_render.tftest.hcl`
- `mock_provider "multipass" {}`; **file-level `variables {}` pinning ALL opt-ins OFF**:
  `dns_server="", internal_ca_cert="", ntp_server="", enable_cilium=false, log_shipping_target="",
  openobserve_endpoint="", openobserve_stream=""` (a stale `.cross-cluster.auto.tfvars.json` would
  otherwise poison `just check` — file-level vars outrank auto-loaded tfvars).
- `run "default_1cp_2w"` (`command = plan`): assert **1 controller + 2 workers, NO haproxy**
  (`multipass_instance.haproxy` count 0 / `length(...) == 0`); controller cpus == 3, worker cpus == 2;
  rendered **`k0sctl.yaml`** carries `storage.type: etcd`, per-host `privateAddress`, `--enable-worker`
  on controllers, `externalAddress: k0s-api.<domain>`; each node cloud-init has the pinned tool
  installs + `K0S_VERSION`, the **UNCONDITIONAL** resolver gate, oh-my-zsh + `_<tool>` completions,
  and the **Vector** config (journald→syslog + `file` `/var/log/pods`→OpenObserve `http` sink);
  `terraform_data.k0s_bootstrap` + `k0s_kubeconfig_distribute` (`depends_on`) exist.
- `run "ha_3cp_3w"` (set `k0s_control_plane_count=3`, `worker_count=3`): renders **3+3 + HAProxy**,
  controller 3 vCPU/3G, HAProxy cloud-init has the `:8405` prometheus frontend, k0sctl still
  `storage.type: etcd`.
- `run "*_off_by_default"`: `enable_cilium`, `log_shipping_target`, `openobserve_endpoint` render
  nothing when empty (Vector shipping sinks absent).
- Use `strcontains(local_file.<x>.content, "...")` and `can(yamldecode(local_file.<x>.content))`.

### Live: `tests/testinfra/{conftest.py,test_*.py}`
- `conftest.py`: mirror netbox — `tofu_output`/`hosts`/`ssh_config_file`/`_connect`. Enumerate the
  **max** role set as **skip-guarded fixtures** (`controller-1`, `worker-1`, `worker-2` always;
  `controller-2`, `controller-3`, `worker-3`, `haproxy` each `pytest.skip` when absent from `hosts`).
  `_wait_for_marker(host, "/var/lib/k0s-nodeprep/done")` to block on the async oneshot.
- `test_*.py`: each controller `sudo k0s status` Running; `sudo k0s kubectl get nodes` all Ready
  (3 default / 6 HA); standalone `kubectl get nodes` as `ubuntu` on every node; tools present
  (`kubectl/helm/k9s/stern/etcdctl/k0s`); zsh default shell + completions; **Vector running +
  enrichment asserted** — an OpenObserve record with populated `namespace/pod/container` (NOT merely
  "a record appears") + a syslog line in logging's `/var/log/remote/`; HA-only: `k0s etcd
  member-list` == 3 + a failover drill; HAProxy `:8405/metrics` returns `haproxy_*`.

### `docs/feature-flags.md`
- Mirror `centralized_logging/docs/feature-flags.md`: title → intro linking `../variables.tf` → TOC →
  flag-matrix table (`k0s_control_plane_count`, `worker_count`, `enable_cilium`, `enable_netdata`,
  `log_shipping_target`, `openobserve_*`, `dns_server`, `internal_ca_cert`, `ntp_server`) → sections
  (topology/HA, CNI, log shipping, changing the footprint).

## Validation Commands

```sh
just check centralized_k0s     # your hermetic suite — must go GREEN (the LEAD's CHECK gate)
uvx ruff check clusters/centralized_k0s/tests/testinfra/*.py     # ruff not on PATH → uvx
# live (ops): just verify centralized_k0s  → your testinfra suite
```

## Acceptance Criteria

- `vector.toml.tftpl`: journald→socket/syslog codec host logs; `file` `/var/log/pods` + VRL
  path-parse → OpenObserve `http` sink (`drop_newest`) + syslog archival copy; **no
  `kubernetes_logs`**; shipping sinks gated on non-empty vars.
- Hermetic suite passes `just check` for default (1+2, no HAProxy) AND HA (3+3+HAProxy) renders, plus
  `_off_by_default`; opts pinned OFF at file level.
- testinfra uses skip-guarded max-role fixtures + marker-polling; asserts Vector **enrichment**
  (populated ns/pod/container), not just record presence.
- `docs/feature-flags.md` mirrors the logging cluster's structure.

## Rules

- Edit ONLY `cloud-init/vector/`, `tests/**`, `docs/feature-flags.md`. Never touch `.rendered/`.
- Lint Python with `uvx ruff check <file>` (ruff/ty not on PATH).
- `just check`/`tofu test` auto-loads `*.auto.tfvars.json` — pin opts OFF at **file level** so a
  stale `.cross-cluster.auto.tfvars.json` can't flip `_off_by_default`.
- Keep tab pill current every step:
  `cmux rename-tab --surface E1DEF030-CE30-4314-8888-79D90E815E20 "🔵 vector <n>/<N> [<bar>] · <log>"`.
  End with `TASK-DONE: vector | <summary>`.
