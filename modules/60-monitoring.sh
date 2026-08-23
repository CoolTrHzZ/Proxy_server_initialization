#!/usr/bin/env bash
set -Eeuo pipefail
SUITE_DIR="${SUITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"
module_context

install -o root -g root -m 700 \
  "${SUITE_DIR}/payload/host-prom-metrics.sh" \
  /usr/local/sbin/host-prom-metrics.sh

cat >/etc/systemd/system/host-prom-metrics.service <<'EOF'
[Unit]
Description=Generate custom Prometheus host metrics
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/host-prom-metrics.sh
EOF

cat >/etc/systemd/system/host-prom-metrics.timer <<EOF
[Unit]
Description=Generate custom Prometheus host metrics periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=${CUSTOM_METRICS_INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
/usr/local/sbin/host-prom-metrics.sh
systemctl enable --now host-prom-metrics.timer

METRICS_TMP="$(mktemp)"
trap 'rm -f "$METRICS_TMP"' EXIT

curl -fsS --max-time 10   "http://127.0.0.1:${NODE_EXPORTER_PORT}/metrics"   -o "$METRICS_TMP" ||
  die "Unable to fetch node_exporter metrics."

grep -q "^${METRIC_PREFIX}_cert_present " "$METRICS_TMP" ||
  die "Custom Prometheus metrics are not visible through node_exporter."

TEXTFILE_ERR="$(awk '/^node_textfile_scrape_error[[:space:]]/{print $2; exit}' "$METRICS_TMP")"
[ "${TEXTFILE_ERR:-}" = "0" ] ||
  die "Textfile Collector parse error (node_textfile_scrape_error=${TEXTFILE_ERR:-missing})."

rm -f "$METRICS_TMP"
trap - EXIT
log "Custom metrics and Textfile Collector verification passed."
