#!/usr/bin/env bash
# Install docker TUI/inspection tools on any VM that runs a docker daemon:
#   wharf  (idesyatov/wharf)  — Go TUI for managing docker
#   oxker  (mrjackwills/oxker) — Rust TUI for inspecting running containers
#   dive   (wagoodman/dive)   — image-layer explorer (.deb)
#
# These are interactive operator tools, NOT /metrics exporters — so, unlike
# install-exporter.sh, this installs plain binaries with no systemd unit.
#
# Idempotent + best-effort: each tool is guarded by `command -v` and a failed
# download for one never aborts the others (no `set -e`); the caller invokes
# this `|| true` so a transient network blip can't break cloud-init. Re-run by
# hand to repair: `sudo /usr/local/sbin/install-docker-tools.sh`.
#
# arm64 (Apple-Silicon Multipass) and amd64 (Proxmox) both supported — the arch
# is detected and mapped to each project's own release-asset naming scheme.
set -uo pipefail

WHARF_VERSION="0.9.1"
OXKER_VERSION="0.13.2"
DIVE_VERSION="0.13.1"

arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
case "$arch" in
  aarch64|arm64) deb_arch=arm64; oxker_arch=aarch64; wharf_arch=arm64 ;;
  x86_64|amd64)  deb_arch=amd64; oxker_arch=x86_64;  wharf_arch=amd64 ;;
  *) echo "install-docker-tools: unsupported arch '$arch'" >&2; exit 0 ;;
esac

# wharf — tar.gz containing the `wharf` binary
if ! command -v wharf >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  if curl -sSLf "https://github.com/idesyatov/wharf/releases/download/v${WHARF_VERSION}/wharf-v${WHARF_VERSION}-linux-${wharf_arch}.tar.gz" -o "$tmp/wharf.tgz"; then
    tar -xzf "$tmp/wharf.tgz" -C "$tmp" || true
    bin="$(find "$tmp" -type f -name wharf | head -n1)"
    [ -n "$bin" ] && install -m0755 "$bin" /usr/local/bin/wharf
  fi
fi

# oxker — tar.gz containing the `oxker` binary
if ! command -v oxker >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  if curl -sSLf "https://github.com/mrjackwills/oxker/releases/download/v${OXKER_VERSION}/oxker_linux_${oxker_arch}.tar.gz" -o "$tmp/oxker.tgz"; then
    tar -xzf "$tmp/oxker.tgz" -C "$tmp" || true
    bin="$(find "$tmp" -type f -name oxker | head -n1)"
    [ -n "$bin" ] && install -m0755 "$bin" /usr/local/bin/oxker
  fi
fi

# dive — .deb (lands in /usr/bin/dive)
if ! command -v dive >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  if curl -sSLf "https://github.com/wagoodman/dive/releases/download/v${DIVE_VERSION}/dive_${DIVE_VERSION}_linux_${deb_arch}.deb" -o "$tmp/dive.deb"; then
    dpkg -i "$tmp/dive.deb" || apt-get install -f -y || true
  fi
fi

# Let the ubuntu user reach the docker socket without sudo (throwaway lab VMs).
getent group docker >/dev/null 2>&1 && usermod -aG docker ubuntu || true
