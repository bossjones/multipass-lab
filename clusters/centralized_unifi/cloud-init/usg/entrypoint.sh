#!/bin/sh
# PID 1 for the USG rsyslog 5.8.11 container: start rsyslogd in the foreground-ish (backgrounded
# so we can also run the traffic generator in the same container, sharing /dev/log), then optionally
# launch the generator. ENABLE_TRAFFIC is set by compose from var.enable_unifi_traffic.
set -eu

# -n: do not fork (we manage backgrounding here so the generator can co-exist).
rsyslogd -n &
RSYSLOG_PID=$!

# Give imuxsock a moment to create /dev/log before the generator starts logging.
sleep 2

if [ "${ENABLE_TRAFFIC:-1}" = "1" ]; then
	/usr/local/bin/unifi-gen.sh &
fi

# Track rsyslogd; if it dies, the container exits (compose restarts it).
wait "$RSYSLOG_PID"
