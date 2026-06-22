name_prefix = "centralized-logging"
image       = "24.04"
syslog_port = 514

# $HOST foldering on central: keep | dns | ip (see variables.tf).
hostname_source = "keep"

central = {
  cpus   = 2
  memory = "2G"
  disk   = "40G"
}

k0s_client = {
  cpus   = 2
  memory = "2G"
  disk   = "20G"
}

docker_client = {
  cpus   = 2
  memory = "4G"
  disk   = "25G"
}
