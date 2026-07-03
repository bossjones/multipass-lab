name_prefix = "centralized-unifi"
image       = "24.04"
syslog_port = 514

# Fidelity: 'exact' runs the appliances' real Debian packages in containers
# (syslog-ng 3.28.1 bullseye + rsyslog 5.8.11 wheezy). 'modern' runs Ubuntu-stock
# syslog-ng 4.x / rsyslog 8.x on the bare VM. See specs/centralized_unifi.md.
version_mode = "exact"

controller = {
  cpus   = 2
  memory = "2G"
  disk   = "20G"
}

usg = {
  cpus   = 2
  memory = "2G"
  disk   = "15G"
}
