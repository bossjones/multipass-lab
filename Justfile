# multipass-lab — orchestrate OpenTofu/Multipass clusters by folder name.
#
#   just up centralized_logging      # tofu apply -> 3 VMs (waits for cloud-init)
#   just check centralized_logging   # hermetic: fmt + validate + tofu test (no VMs)
#   just verify centralized_logging  # live: pytest + testinfra over SSH
#   just down centralized_logging    # tofu destroy
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

# tofu init for a cluster
init CLUSTER:
    tofu -chdir={{cluster_root}}/{{CLUSTER}} init

# tofu plan
plan CLUSTER: (init CLUSTER)
    tofu -chdir={{cluster_root}}/{{CLUSTER}} plan

# bring the cluster up (one apply launches all VMs), then block until cloud-init finishes
up CLUSTER: (init CLUSTER)
    tofu -chdir={{cluster_root}}/{{CLUSTER}} apply -auto-approve
    @tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts \
      | jq -r '.[].ipv4' \
      | while read ip; do \
          echo "waiting for cloud-init: $ip"; \
          until ssh {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" \
            'cloud-init status --wait >/dev/null 2>&1 || true' 2>/dev/null; do sleep 5; done; \
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
    @ip=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.{{ROLE}}.ipv4'); \
     ssh {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip"

# list the log files collected on the central VM
logs CLUSTER:
    @ip=$(tofu -chdir={{cluster_root}}/{{CLUSTER}} output -json hosts | jq -r '.central.ipv4'); \
     ssh {{ssh_opts}} -i {{ssh_key}} ubuntu@"$ip" 'sudo find /var/log/remote -type f'
