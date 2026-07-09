# centralized_k0s — HA control plane + load balancing (research shard)

Research shard for the planned `clusters/centralized_k0s/` cluster: 3 controller-only + 3
worker VMs, **etcd** datastore, on Multipass (arm64 Mac, DHCP on a macOS-bridged NAT
segment), standing in for a future Proxmox deployment. Scope = control-plane HA + how to
front the API. Sibling shards cover CNI, storage/backup, cloud-init/testinfra, and the
umbrella spec.

## Summary

- **HA is a datastore + config-consistency change, not a topology trick.** Flip
  `spec.storage.type: etcd`, keep cluster-level config byte-identical across all 3
  controllers, share the CA/SA/etcd-CA keypairs, and join controllers with controller
  tokens. k0s manages etcd membership automatically on join. 3 controllers = quorum 2 =
  tolerates 1 loss.
- **The load balancer is the one genuinely Multipass-hostile decision.** k0s's native VIP
  (CPLB/Keepalived) needs *both* a free in-subnet VIP the DHCP server won't hand out *and*
  VRRP working across Multipass's `vmnet` segment on macOS. Both are unverified-to-risky on
  this platform.
- **Recommendation for the Multipass lab: a 7th "external HAProxy" VM** fronting
  `6443`/`8132`/`9443` to all three controllers, wired via `spec.api.externalAddress` +
  `sans`. It sidesteps the VIP-allocation and multicast unknowns entirely; its own DHCP IP
  is the stable endpoint. Cost: it's a SPOF (fine for a lab) and, because it forces
  `externalAddress`, it is **mutually exclusive with NLLB** (see below).
- **On Proxmox, flip to CPLB (Keepalived VIP) + NLLB** — a real LAN gives you controllable
  IPAM (reserve the VIP) and multicast/GARP, so the native path becomes the better one and
  the HAProxy VM can be retired (or kept + paired with keepalived for a non-SPOF edge).
- **The LB must pass three TCP ports**: `6443` (kube-apiserver), `8132` (konnectivity),
  `9443` (k0s controller-join API / `k0sApiPort`). TCP/L4 passthrough only — no TLS
  termination.

## etcd HA

**Datastore.** Default single-node k0s uses kine+SQLite, which **cannot form a quorum** —
HA strictly requires `spec.storage.type: etcd`. k0s runs a stacked (co-located) etcd member
inside each controller and manages membership itself: joining a controller with a
*controller* token makes k0s add the new etcd member; there is no manual `etcdctl member add`.

**Quorum math.** quorum = ⌊n/2⌋+1. n=3 → 2 → survives 1 controller down. n=5 → 3 → survives 2
but doubles write amplification. **3 is correct here.** A 2-controller plane is *not*
etcd-HA (loses quorum when 1 is down) — never run 2.

**Per-controller config.** Cluster-level blocks (`network`, `storage` type, LB config) must
be **identical** on every controller; node-specific fields differ:
- `spec.api.address` — this controller's own IP
- `spec.storage.etcd.peerAddress` — this controller's IP (etcd raft peering on `:2380`)
- `spec.api.sans` — include every controller IP + the LB address

**Shared secrets.** All controllers must share the same
`/var/lib/k0s/pki/{ca,sa,etcd/ca}.{crt,key}` (and `sa.pub`). k0sctl distributes these
automatically; a manual/cloud-init build must generate them **once** and copy them to
controllers 2 and 3 before they start, or etcd/API TLS won't trust across members. This is
the single hardest thing to get right in a pure-cloud-init (no-k0sctl) build.

**Join flow (manual / cloud-init path).** On controller-1 (the bootstrap node):
```bash
k0s token create --role=controller --expiry=1h > controller.token   # for peers
k0s token create --role=worker     --expiry=24h > worker.token       # for workers
```
On controllers 2 & 3 (etcd required — SQLite single-node cannot join):
```bash
k0s install controller --token-file /path/controller.token -c /etc/k0s/k0s.yaml
k0s start
```
Member ops: `k0s etcd member-list`; graceful removal **before** shutting a node down
(k0s never shrinks etcd for you): `k0s etcd leave --peer-address <IP>` (or declaratively,
`kubectl patch etcdmember <name> --type merge -p '{"spec":{"leave":true}}'`).

**k0sctl vs per-VM cloud-init.** k0sctl (`apiVersion: k0sctl.k0sproject.io/v1beta1`) is the
paved road: it SSHes to each host, distributes PKI, creates+consumes join tokens, and orders
controller-then-worker automatically. But it's an **imperative, host-driven** tool that
fights this repo's declarative OpenTofu+cloud-init model and needs all IPs known up front —
which Multipass DHCP defeats. Two viable shapes for the umbrella spec to choose between:
1. **Pure cloud-init** — controller-1 renders first, OpenTofu reads its `ipv4`, then renders
   controllers 2/3 + workers with the discovered IP + a shared token (mirrors the existing
   runtime-IP-injection pattern in `centralized_monitoring`). Hardest part: distributing the
   shared PKI without k0sctl (pre-generate CA material like `centralized_pki` does, inject
   via `write_files`, or have controller-1 publish tokens that carry the CA).
2. **k0sctl as a post-apply `terraform_data` step** — OpenTofu launches bare VMs, discovers
   all IPs, writes a `k0sctl.yaml`, runs `k0sctl apply`. Keeps PKI distribution "for free"
   at the cost of a non-declarative provisioner. (Flagged for the umbrella-spec decision.)

## LB options on Multipass

Ports every option must carry (TCP passthrough, no TLS termination): **6443** kube-apiserver,
**8132** konnectivity, **9443** k0s controller-join (`k0sApiPort`). (NLLB internally uses
`7443`/`7132` on loopback — not LB-facing.)

| Option | Works on Multipass? | Pros | Cons |
|---|---|---|---|
| **CPLB — Keepalived VIP, userspace reverse-proxy** (default LB mode since ~1.32; VIP:6443 → iptables REDIRECT → localhost:6444 → reconciler spreads to all controllers) | ⚠️ **Risky/unverified.** Needs (a) a **free in-subnet VIP** the Multipass dnsmasq won't lease — no reservation API on macOS, so collision risk is real; (b) VRRP + GARP across the `vmnet`/QEMU L2 segment. Multicast *may* traverse the shared segment; **unicast mode** (`unicastSourceIP`/`unicastPeers`) removes the multicast dependency but **not** the free-VIP problem. | No extra VM; k0s-native; VIP floats between controllers; pairs with NLLB; is the "real" answer on Proxmox | Free-VIP allocation is the blocker on Multipass; GARP for an IP the DHCP server doesn't know about may not be honored; hardest to prove healthy in a lab |
| **CPLB — Keepalived + `virtualServers` (IPVS)** | ❌ Also VIP-dependent **and** "incompatible with controller+worker" per docs — our controllers are controller-only, but IPVS adds a `dummyvip0 /32` on every node and only the master balances | Higher throughput than userspace proxy | Extra failure surface; no reason to use over the userspace proxy in a lab; same VIP problem |
| **NLLB — Envoy per-worker (loopback)** | ✅ Works (arm64 = Envoy supported; ARMv7/RISC-V would need Traefik) — but it is **internal-only** | Zero external infra; each worker load-balances its *own* kubelet/konnectivity to all controllers; auto-reconfigures as controllers change | Does **not** help external clients (kubectl/Lens/CI from the Mac); **incompatible with `spec.api.externalAddress`** (so cannot coexist with the HAProxy path below); existing workers must **restart** to adopt it |
| **External HAProxy VM (7th VM)** — L4 `mode tcp` frontends on 6443/8132/9443 → 3 controller backends; set `spec.api.externalAddress` = HAProxy IP + add it to every controller's `sans` | ✅ **Yes — most reliable on Multipass.** Uses the VM's own DHCP IP as the stable endpoint; no VIP to allocate, no multicast | Simple, well-understood, one stable address; L4 passthrough is trivial to config + health-check; matches how the repo already stands up single-purpose VMs | Another VM to boot/patch; **SPOF** unless paired with keepalived (which reintroduces the VIP problem); forcing `externalAddress` **disables NLLB** and routes worker→API through it too, so its outage hits workers, not just external clients |

**HAProxy config sketch** (`/etc/haproxy/haproxy.cfg`, L4 passthrough):
```haproxy
defaults
  mode tcp
  timeout connect 5s
  timeout client 30m
  timeout server 30m
  option tcplog
frontend k8s_api
  bind :6443
  default_backend cp_api
backend cp_api
  balance roundrobin
  option tcp-check
  server c1 <ctrl1_ip>:6443 check
  server c2 <ctrl2_ip>:6443 check
  server c3 <ctrl3_ip>:6443 check
# repeat frontend/backend pairs for :8132 (konnectivity) and :9443 (controller join)
```
Health-check note: a bare TCP connect is enough for a lab; a stricter check would probe
`GET /readyz` on `:6443` (needs `option httpchk` + TLS `check-ssl verify none`, since the
API serves HTTPS). Start with `option tcp-check`.

## Recommendation

**Multipass lab: external HAProxy VM (Option "External HAProxy") — the user's preferred path,
and the correct one here.**

- 3 controllers (`storage.type: etcd`) + 3 workers + **1 HAProxy VM** = 7 VMs.
- `spec.api.externalAddress: <haproxy_ip>`; add `<haproxy_ip>` to `spec.api.sans` on every
  controller (OpenTofu discovers the HAProxy VM's `ipv4` and injects it, same runtime-IP
  pattern the repo already uses).
- **Do not enable CPLB** (its `virtualServers`/endpoint-reconciler conflict with
  `externalAddress`) and **do not enable NLLB** (incompatible with `externalAddress`).
  Workers reach the API through HAProxy.
- Point kubectl/k9s/CI at `<haproxy_ip>:6443`, never a single controller.
- **Why not CPLB here:** the two Multipass unknowns — obtaining a collision-free VIP from
  Multipass's dnsmasq, and VRRP/GARP behavior over `vmnet` — are exactly the things a lab
  should *not* gamble its control-plane reachability on. HAProxy makes the endpoint a boring,
  observable DHCP IP.
- **SPOF honesty:** the HAProxy VM is a single point of failure for API reachability. That is
  acceptable for a lab whose *purpose* is to rehearse the etcd-quorum failover drill (kill a
  controller, prove the API stays up via HAProxy's other 2 backends). Document it; optionally
  add a 2nd HAProxy + keepalived later, accepting that keepalived reintroduces the VIP
  question.

**Validation gates** (hand to the testinfra shard): `k0s etcd member-list` shows 3 members;
`etcdctl ... endpoint health` all healthy; `kubectl get nodes` lists all 6; failover drill =
hard-stop the current apiserver-serving controller, confirm `kubectl get --raw=/readyz`
through HAProxy stays 200 and etcd keeps quorum (2/3), then rejoin.

## Multipass → Proxmox delta

| Concern | Multipass lab (now) | Proxmox (later) |
|---|---|---|
| Front-end LB | External HAProxy VM; `externalAddress` = its DHCP IP | **CPLB (Keepalived VIP)** — reserve a static VIP in the router/DHCP; multicast+GARP work on a real LAN. Retire HAProxy (or keep it paired w/ keepalived) |
| Internal worker→API HA | via HAProxy (no NLLB, because `externalAddress` set) | **Enable NLLB (Envoy)** once you drop `externalAddress` for the CPLB VIP; workers get loopback HA independent of the edge |
| VIP allocation | not attempted (no reservation API) | reserve VIP outside the DHCP pool in OPNsense/pfSense/router |
| Controller anti-affinity | all VMs on one Mac (no HW HA) | **spread the 3 controllers across ≥3 Proxmox hosts** so one hypervisor loss ≠ quorum loss |
| PKI distribution | pre-generated + cloud-init, or k0sctl post-apply | k0sctl handles it, or same pre-gen approach |
| Config change to flip | remove `externalAddress`, add `controlPlaneLoadBalancing` + `nodeLocalLoadBalancing` blocks | same YAML deltas; requires a controller reconfigure/restart |

The switch is a **config edit, not a rebuild** — the etcd datastore, tokens, and PKI are
unchanged. That's the whole point of choosing `externalAddress`+HAProxy now and CPLB+NLLB
later: they're two ends of the same k0s config surface.

## Open risks / adversarial-bait

- **CPLB *might* actually work on Multipass and I recommended against trying it.** A hostile
  reviewer will say "you didn't test it." True — this is a paper decision. Mitigation: the
  recommendation is reversible (config edit), and a fast spike (`unicast` VRRP + a hand-picked
  high VIP like `.240`, watch `k0s status` / `journalctl -u k0scontroller` for keepalived
  master election) could confirm/deny in an hour. If it works, prefer it.
- **Free-VIP collision is asserted, not proven.** Multipass on macOS uses a dnsmasq-managed
  segment (commonly `192.168.64.0/24`) with no documented reservation mechanism. Whether a
  hand-picked high address is safe from future leases is an empirical question — a reviewer
  can rightly demand the actual DHCP range before trusting any static VIP.
- **HAProxy SPOF vs. the stated HA goal.** "You built an HA control plane and put a
  single-VM chokepoint in front of it." Defensible for a lab (the drill exercises *etcd*
  failover; HAProxy has 3 live backends), but it is a real asterisk on the word "HA."
- **Losing NLLB is a real downgrade, not just a config note.** With `externalAddress` set,
  every worker's kubelet/konnectivity depends on HAProxy; an HAProxy blip disrupts workers,
  not just laptops. On the native (CPLB+NLLB) path, workers survive edge failure. Call this
  out so nobody thinks the lab topology is HA-equivalent to the Proxmox target.
- **Pure-cloud-init PKI distribution is under-specified here** and is the likeliest thing to
  silently break a 3-controller join (mismatched CA ⇒ etcd peer TLS refuses). The umbrella
  spec must pick mechanism #1 or #2 above and prove it, not hand-wave it.
- **`externalAddress` immutability during backup/restore.** `k0s backup`/`restore` requires
  the `externalAddress` be unchanged between snapshot and restore — pinning it to a *DHCP* IP
  that can change across a full teardown is a latent footgun; consider a stable hostname
  (AdGuard `dns_records`) instead of the raw IP.
- **etcd/config-consistency drift.** Any per-controller divergence in cluster-level config
  (e.g. one controller missing the LB address in `sans`) yields a cluster that boots but
  fails intermittently — exactly the "hermetic tests pass, live fails confusingly" trap the
  repo already warns about for stale cloud-init.

## Sources

- https://docs.k0sproject.io/stable/high-availability/ — controller count, LB ports 6443/8132/9443, `externalAddress`, shared PKI
- https://docs.k0sproject.io/stable/cplb/ — Keepalived VRRP, userspace reverse-proxy (:6444) vs `virtualServers`/IPVS, multicast vs unicast, VIP-must-be-routable, `externalAddress` mutual exclusion, NLLB compatibility
- https://docs.k0sproject.io/stable/nllb/ — Envoy (arm64 ✓, not ARMv7)/Traefik, internal-only, incompatible with `externalAddress`, worker-restart requirement
- https://docs.k0sproject.io/stable/configuration/ — `spec.api` (address/externalAddress/sans/port=6443/k0sApiPort=9443), `spec.storage.etcd.peerAddress`, LB config blocks, NLLB default ports 7443/7132
- https://docs.k0sproject.io/stable/cli/ — `k0s token create`, `k0s install controller --token-file`, `k0s etcd member-list`, `k0s etcd leave`, `k0s backup`/`restore`
- Repo: `ai_docs/claude-multipass-infra-upgrade-brief.md` (Option 2 = etcd/CPLB/NLLB, Proxmox-oriented) and `clusters/centralized_monitoring/cloud-init/k0s-client.yaml.tftpl` (current single-node `--single` baseline)
