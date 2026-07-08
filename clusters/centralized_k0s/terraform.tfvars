# Live defaults for `just up centralized_k0s`: 1 controller + 2 workers, NO HAProxy (etcd
# single-member). This fits `up-connected`. For the HA opt-in (3 controllers + 3 workers +
# HAProxy, ~13 vCPU / 19 G — essentially the whole Mac, bring it up stand-alone), drop a throwaway
# ha.auto.tfvars with `k0s_control_plane_count = 3` / `worker_count = 3` (outranks this file).
#
# Cross-cluster opt-ins (dns_server / internal_ca_cert / ntp_server / log_shipping_target /
# openobserve_*) are left at their empty defaults so a plain `just up` is turnkey + isolated;
# `just up-connected` wires them from live hub IPs.

name_prefix = "centralized-k0s"
image       = "24.04"

k0s_control_plane_count = 1
worker_count            = 2

k0s_version = "v1.34.9+k0s.0"

ssh_pubkey_path = "~/.ssh/id_ed25519.pub"
