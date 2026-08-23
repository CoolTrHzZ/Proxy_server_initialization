#!/usr/bin/env bash
set -Eeuo pipefail
SUITE_DIR="${SUITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"
module_context

install -o root -g root -m 700 \
  "${SUITE_DIR}/payload/host-health-check.sh" \
  /usr/local/sbin/host-health-check.sh

cat >/etc/systemd/system/host-health-check.service <<'EOF'
[Unit]
Description=Read-only VPS health check
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/host-health-check.sh
NoNewPrivileges=true
EOF

cat >/etc/systemd/system/host-health-check.timer <<EOF
[Unit]
Description=Run VPS health check periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=${HEALTH_CHECK_INTERVAL}
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
/usr/local/sbin/host-health-check.sh
systemctl enable --now host-health-check.timer
