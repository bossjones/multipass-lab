# multipass-lab — orchestrate OpenTofu/Multipass clusters by folder name.
#
#   just up centralized_logging      # tofu apply -> 3 VMs
#   just check centralized_logging   # hermetic: fmt + validate + tofu test (no VMs)
#   just verify centralized_logging  # live: pytest + testinfra over SSH
#   just down centralized_logging    # tofu destroy

cluster_root := "clusters"

# Multipass instance names use hyphens; cluster folders may use underscores.
# `prefix` maps the folder name to the VM name_prefix.

_default:
    @just --list

# tofu init for a cluster
init CLUSTER:
    tofu -chdir={{cluster_root}}/{{CLUSTER}} init

# tofu plan
plan CLUSTER: (init CLUSTER)
    tofu -chdir={{cluster_root}}/{{CLUSTER}} plan

# bring the cluster up (one apply launches all VMs), then block until cloud-init finishes
up CLUSTER: (init CLUSTER)
    tofu -chdir={{cluster_root}}/{{CLUSTER}} apply -auto-approve
    @multipass list --format csv \
      | awk -F, 'NR>1 && $1 ~ /^{{replace(CLUSTER, "_", "-")}}-/ {print $1}' \
      | while read vm; do \
          echo "waiting for cloud-init: $vm"; \
          multipass exec "$vm" -- cloud-init status --wait || true; \
        done

# tear the cluster down
down CLUSTER:
    tofu -chdir={{cluster_root}}/{{CLUSTER}} destroy -auto-approve

# hermetic inner loop — never touches Multipass
check CLUSTER: (init CLUSTER)
    tofu -chdir={{cluster_root}}/{{CLUSTER}} fmt -check -recursive
    tofu -chdir={{cluster_root}}/{{CLUSTER}} validate
    tofu -chdir={{cluster_root}}/{{CLUSTER}} test -test-directory=tests/tofu

# live verify against the running VMs (pytest + testinfra over SSH)
verify CLUSTER:
    cd {{cluster_root}}/{{CLUSTER}}/tests/testinfra && uv run pytest -v

# multipass list
status:
    multipass list

# open a shell on a VM:  just ssh centralized_logging central
ssh CLUSTER ROLE:
    multipass shell {{replace(CLUSTER, "_", "-")}}-{{ROLE}}

# list the log files collected on the central VM
logs CLUSTER:
    multipass exec {{replace(CLUSTER, "_", "-")}}-central -- sudo find /var/log/remote -type f
