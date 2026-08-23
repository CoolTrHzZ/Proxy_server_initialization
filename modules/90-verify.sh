#!/usr/bin/env bash
set -Eeuo pipefail
SUITE_DIR="${SUITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"
module_context

FAIL=0
WARN=0
ok(){ echo "[PASS] $*"; }
bad(){ echo "[FAIL] $*"; FAIL=$((FAIL+1)); }
note(){ echo "[WARN] $*"; WARN=$((WARN+1)); }

systemctl is-active --quiet docker && ok "docker active" || bad "docker inactive"
systemctl is-active --quiet acme-renew.timer && ok "acme-renew.timer active" || bad "acme-renew.timer inactive"
systemctl is-active --quiet host-prom-metrics.timer && ok "host-prom-metrics.timer active" || bad "host-prom-metrics.timer inactive"
systemctl is-active --quiet host-health-check.timer && ok "host-health-check.timer active" || bad "host-health-check.timer inactive"

container_running "$THREEXUI_CONTAINER" && ok "3x-ui running" || bad "3x-ui not running"
container_running "$NODE_EXPORTER_CONTAINER" && ok "node_exporter running" || bad "node_exporter not running"
port_listening "$RESOLVED_PANEL_PORT" && ok "panel port ${RESOLVED_PANEL_PORT} listening" || bad "panel port not listening"
port_listening "$NODE_EXPORTER_PORT" && ok "node_exporter :${NODE_EXPORTER_PORT} listening" || bad "node_exporter port not listening"

cert_key_match "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/private.key" &&
  ok "certificate/private key match" || bad "certificate/private key mismatch"

openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -checkend 86400 >/dev/null 2>&1 &&
  ok "certificate valid >24h" || bad "certificate invalid/expiring"

METRICS_TMP="$(mktemp)"
trap 'rm -f "$METRICS_TMP"' EXIT

if curl -fsS --max-time 10      "http://127.0.0.1:${NODE_EXPORTER_PORT}/metrics"      -o "$METRICS_TMP"; then

  if grep -q "^${METRIC_PREFIX}_cert_present 1$" "$METRICS_TMP"; then
    ok "custom metrics exposed"
  else
    bad "custom metrics missing"
  fi

  TEXTFILE_ERR="$(awk '/^node_textfile_scrape_error[[:space:]]/{print $2; exit}' "$METRICS_TMP")"
  if [ "${TEXTFILE_ERR:-}" = "0" ]; then
    ok "Textfile Collector error=0"
  else
    bad "Textfile Collector parse error (value=${TEXTFILE_ERR:-missing})"
  fi

  if grep -q "${METRIC_PREFIX}_port_listening{service=\"reality\"" "$METRICS_TMP"; then
    ok "REALITY metrics discovered"
  else
    note "REALITY inbound not configured yet; create it in 3x-ui after bootstrap."
  fi
else
  bad "unable to fetch node_exporter metrics"
fi

rm -f "$METRICS_TMP"
trap - EXIT

write_result

echo
echo "=================================================================="
if [ "$FAIL" -eq 0 ]; then
  echo "STATUS: SUCCESS"
  echo "Warnings: $WARN"
  echo "Panel URL: https://${DOMAIN}:${RESOLVED_PANEL_PORT}${RESOLVED_PANEL_BASE_PATH}"
  echo "Panel/result: ${RESULT_FILE}"
  echo "Prometheus output: ${OUTPUT_DIR}"
else
  echo "STATUS: FAILED (${FAIL} checks failed)"
  exit 1
fi
echo "=================================================================="
