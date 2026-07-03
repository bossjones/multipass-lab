#!/usr/bin/env bash
# Managed by OpenTofu — SHARED cross-cluster snippet (clusters/_shared/cloud-init).
# Self-contained, arch-aware node_exporter installer for clusters that do NOT already ship the
# generic install-exporter.sh helper. Installs the binary + a systemd unit listening on :9100 so
# the monitoring hub can scrape this VM cross-cluster. Idempotent: re-running upgrades in place.
#
# Escaping note: this file is dropped verbatim via cloud-init write_files (NOT rendered by
# templatefile), so ordinary shell $ is used — do not double it.
set -euo pipefail

VERSION="1.8.2"
arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$arch" in aarch64) arch=arm64 ;; x86_64) arch=amd64 ;; esac
url="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-${arch}.tar.gz"

tmp="$(mktemp -d)"
curl -sSLf "$url" -o "$tmp/dl"
tar -xzf "$tmp/dl" -C "$tmp"
found="$(find "$tmp" -type f -name node_exporter | head -n1)"
install -m0755 "$found" /usr/local/bin/node_exporter
rm -rf "$tmp"

cat >/etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus node_exporter
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/node_exporter --collector.systemd
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now node_exporter
