#!/bin/sh
# USG traffic generator — emits representative Vyatta / UniFi-style syslog so the pipeline shows
# live data and the collector's syslog_ng_exporter counters move. Runs inside the rsyslog 5.8.11
# container; `logger` writes to the container's /dev/log, which imuxsock reads and the Vyatta rule
# forwards (UDP) to the collector.
#
# The mix deliberately exercises the UCK's not2msg filter: the [ALIEN BLOCK] / [TOR BLOCK] firewall
# markers are EXCLUDED from the collector's local /var/log/messages fan-out but still received over
# the network path, while a plain local7.info line survives to prove end-to-end delivery.
set -eu

while true; do
	logger -p local7.info  -t vyatta-firewall "[ALIEN BLOCK]-DROP IN=eth0 OUT= SRC=203.0.113.7 DST=192.168.3.1 PROTO=TCP DPT=23"
	logger -p local7.info  -t vyatta-firewall "[TOR BLOCK]-DROP IN=eth0 OUT= SRC=198.51.100.9 DST=192.168.3.1 PROTO=UDP DPT=53"
	logger -p daemon.notice -t hostapd        "wlan0: STA aa:bb:cc:dd:ee:ff IEEE 802.11: authenticated"
	logger -p kern.warning  -t kernel         "[UIFW] WAN_LOCAL-default-D DROP SRC=203.0.113.50 DST=192.168.3.1"
	logger -p local7.info  -t ubnt-dpi        "dpi: app=BitTorrent cat=P2P bytes=10240 client=192.168.3.44"
	logger -p local7.info  -t usg-heartbeat   "gateway alive uptime=$(cat /proc/uptime 2>/dev/null | cut -d. -f1)s"
	sleep 10
done
