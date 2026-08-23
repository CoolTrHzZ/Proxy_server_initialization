#!/usr/bin/env bash
set -Eeuo pipefail
SUITE_DIR="${SUITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"
module_context

export DEBIAN_FRONTEND=noninteractive
log "Ensuring required base packages..."
apt-get update
apt-get install -y \
  ca-certificates curl git jq openssl socat sqlite3 dnsutils \
  cron iproute2 procps util-linux

TOTAL_SWAP_MB="$(awk '/SwapTotal:/{print int($2/1024)}' /proc/meminfo)"
if [ "$SWAP_SIZE_MB" -gt 0 ] && [ "$TOTAL_SWAP_MB" -lt "$SWAP_SIZE_MB" ]; then
  log "Active swap=${TOTAL_SWAP_MB}MB < target=${SWAP_SIZE_MB}MB; creating /swapfile..."
  if [ ! -f /swapfile ]; then
    fallocate -l "${SWAP_SIZE_MB}M" /swapfile ||
      dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=progress
  fi
  chmod 600 /swapfile
  blkid /swapfile 2>/dev/null | grep -q 'TYPE="swap"' || mkswap /swapfile >/dev/null
  swapon --show=NAME --noheadings | grep -qx '/swapfile' || swapon /swapfile
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
else
  log "Active swap=${TOTAL_SWAP_MB}MB; no additional swap required."
fi

cat >/etc/sysctl.d/99-vps-bootstrap-swap.conf <<EOF
vm.swappiness=${SWAPPINESS}
EOF
sysctl -p /etc/sysctl.d/99-vps-bootstrap-swap.conf >/dev/null

mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-vps-bootstrap-size.conf <<EOF
[Journal]
SystemMaxUse=${JOURNAL_MAX_USE}
RuntimeMaxUse=${JOURNAL_RUNTIME_MAX_USE}
MaxRetentionSec=${JOURNAL_RETENTION}
EOF
systemctl restart systemd-journald

log "Memory/swap state:"
free -h
