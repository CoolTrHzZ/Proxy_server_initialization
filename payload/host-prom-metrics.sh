#!/usr/bin/env bash
set -u
set -o pipefail

RUNTIME="/etc/vps-bootstrap/runtime.env"
[ -r "$RUNTIME" ] || exit 1
source "$RUNTIME"

PROM_DIR="/var/lib/node_exporter/textfile_collector"
PROM_FILE="${PROM_DIR}/host_health.prom"
TMP="${PROM_FILE}.$$"
CERT="${CERT_DIR}/fullchain.pem"
KEY="${CERT_DIR}/private.key"
NOW="$(date +%s)"

mkdir -p "$PROM_DIR"

container_running(){
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}
port_listening(){
  ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"
}

CERT_PRESENT=0
CERT_KEY_MATCH=0
CERT_DAYS=-1
ACME_TIMER_ACTIVE=0
XUI_UP=0
PANEL_TLS_MATCH=0

if [ -s "$CERT" ]; then
  CERT_PRESENT=1
  END_DATE="$(openssl x509 -in "$CERT" -noout -enddate 2>/dev/null | cut -d= -f2-)"
  END_EPOCH="$(date -d "$END_DATE" +%s 2>/dev/null || echo 0)"
  [ "$END_EPOCH" -gt 0 ] && CERT_DAYS=$(( (END_EPOCH - NOW) / 86400 ))
fi

if [ -s "$CERT" ] && [ -s "$KEY" ]; then
  CH="$(openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}')"
  KH="$(openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}')"
  [ -n "$CH" ] && [ "$CH" = "$KH" ] && CERT_KEY_MATCH=1
fi

systemctl is-active --quiet acme-renew.timer 2>/dev/null && ACME_TIMER_ACTIVE=1
container_running "$THREEXUI_CONTAINER" && XUI_UP=1

if [ "$XUI_UP" -eq 1 ] && [ "$CERT_PRESENT" -eq 1 ]; then
  INSTALLED_FP="$(openssl x509 -in "$CERT" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)"
  SERVED_FP="$(
    timeout 5 openssl s_client -connect "127.0.0.1:${RESOLVED_PANEL_PORT}" \
      -servername "$DOMAIN" </dev/null 2>/dev/null |
    openssl x509 -noout -fingerprint -sha256 2>/dev/null |
    cut -d= -f2
  )"
  [ -n "$SERVED_FP" ] && [ "$SERVED_FP" = "$INSTALLED_FP" ] && PANEL_TLS_MATCH=1
fi

cat >"$TMP" <<EOF
# HELP ${METRIC_PREFIX}_metrics_last_run_timestamp_seconds Last successful custom metric generation time.
# TYPE ${METRIC_PREFIX}_metrics_last_run_timestamp_seconds gauge
${METRIC_PREFIX}_metrics_last_run_timestamp_seconds ${NOW}

# HELP ${METRIC_PREFIX}_cert_present Whether the TLS certificate exists.
# TYPE ${METRIC_PREFIX}_cert_present gauge
${METRIC_PREFIX}_cert_present ${CERT_PRESENT}

# HELP ${METRIC_PREFIX}_cert_days_remaining TLS certificate remaining validity in days.
# TYPE ${METRIC_PREFIX}_cert_days_remaining gauge
${METRIC_PREFIX}_cert_days_remaining ${CERT_DAYS}

# HELP ${METRIC_PREFIX}_cert_key_match Whether certificate and private key match.
# TYPE ${METRIC_PREFIX}_cert_key_match gauge
${METRIC_PREFIX}_cert_key_match ${CERT_KEY_MATCH}

# HELP ${METRIC_PREFIX}_acme_timer_active Whether acme-renew.timer is active.
# TYPE ${METRIC_PREFIX}_acme_timer_active gauge
${METRIC_PREFIX}_acme_timer_active ${ACME_TIMER_ACTIVE}

# HELP ${METRIC_PREFIX}_service_up Custom service state.
# TYPE ${METRIC_PREFIX}_service_up gauge
${METRIC_PREFIX}_service_up{service="3xui"} ${XUI_UP}

# HELP ${METRIC_PREFIX}_panel_tls_cert_match Whether 3x-ui serves the current installed certificate.
# TYPE ${METRIC_PREFIX}_panel_tls_cert_match gauge
${METRIC_PREFIX}_panel_tls_cert_match ${PANEL_TLS_MATCH}
EOF

if [ "$XUI_UP" -eq 1 ]; then
  docker exec "$THREEXUI_CONTAINER" sh -c 'cat /app/bin/config.json 2>/dev/null || true' |
  jq -r '
    .inbounds[]?
    | select(.protocol == "vless" and .streamSettings.security == "reality")
    | .port
  ' 2>/dev/null |
  awk '/^[0-9]+$/' |
  while read -r PORT; do
    VALUE=0
    port_listening "$PORT" && VALUE=1
    echo "${METRIC_PREFIX}_port_listening{service=\"reality\",port=\"${PORT}\"} ${VALUE}" >>"$TMP"
  done
fi

mv "$TMP" "$PROM_FILE"
chmod 644 "$PROM_FILE"
