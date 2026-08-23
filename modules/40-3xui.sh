#!/usr/bin/env bash
set -Eeuo pipefail
SUITE_DIR="${SUITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"
module_context

DB_DIR="/opt/3x-ui-blue/db"
DB="${DB_DIR}/x-ui.db"
MARKER="/opt/3x-ui-blue/.bootstrap-initialized"

mkdir -p "$DB_DIR"
chmod 700 "$DB_DIR"

log "Pulling 3x-ui image ${THREEXUI_IMAGE}..."
docker pull "$THREEXUI_IMAGE"

DESIRED_HASH="$(
  printf '%s\n' \
    "$THREEXUI_IMAGE" \
    "$RESOLVED_PANEL_PORT" \
    "$RESOLVED_PANEL_BASE_PATH" \
    "$CERT_DIR" |
  sha256sum | awk '{print $1}'
)"

CURRENT_HASH="$(docker inspect -f '{{index .Config.Labels "io.trhzz.bootstrap.config-hash"}}' "$THREEXUI_CONTAINER" 2>/dev/null || true)"
NEED_RECREATE=0

if ! docker inspect "$THREEXUI_CONTAINER" >/dev/null 2>&1; then
  NEED_RECREATE=1
elif [ "$CURRENT_HASH" != "$DESIRED_HASH" ]; then
  NEED_RECREATE=1
elif ! container_running "$THREEXUI_CONTAINER"; then
  docker start "$THREEXUI_CONTAINER" >/dev/null || NEED_RECREATE=1
fi

if [ "$NEED_RECREATE" -eq 1 ]; then
  log "Creating/reconciling 3x-ui container using Docker CLI (no Compose dependency)..."
  docker rm -f "$THREEXUI_CONTAINER" >/dev/null 2>&1 || true

  docker run -d \
    --name "$THREEXUI_CONTAINER" \
    --network host \
    --restart unless-stopped \
    --label "io.trhzz.bootstrap.managed=true" \
    --label "io.trhzz.bootstrap.config-hash=${DESIRED_HASH}" \
    -e XRAY_VMESS_AEAD_FORCED=false \
    -e XUI_ENABLE_FAIL2BAN=false \
    -e XUI_PORT="$RESOLVED_PANEL_PORT" \
    -e XUI_INIT_WEB_BASE_PATH="$RESOLVED_PANEL_BASE_PATH" \
    -v "${DB_DIR}:/etc/x-ui" \
    -v "${CERT_DIR}:/root/cert:ro" \
    --log-driver json-file \
    --log-opt max-size=10m \
    --log-opt max-file=3 \
    "$THREEXUI_IMAGE" >/dev/null
fi

wait_container "$THREEXUI_CONTAINER" 60 || {
  docker logs --tail 200 "$THREEXUI_CONTAINER" 2>&1 || true
  die "3x-ui container failed to start."
}

# Wait until the DB is initialized.
for _ in $(seq 1 40); do
  [ -s "$DB" ] && break
  sleep 1
done
[ -s "$DB" ] || {
  docker logs --tail 200 "$THREEXUI_CONTAINER" 2>&1 || true
  die "3x-ui database was not created."
}

if [ ! -f "$MARKER" ] || [ "$FORCE_RECONFIGURE_PANEL" = "1" ]; then
  log "Applying bootstrap panel credentials/path..."
  docker exec "$THREEXUI_CONTAINER" /app/x-ui setting \
    -username "$RESOLVED_PANEL_USERNAME" \
    -password "$RESOLVED_PANEL_PASSWORD" \
    -port "$RESOLVED_PANEL_PORT" \
    -webBasePath "$RESOLVED_PANEL_BASE_PATH"

  docker restart "$THREEXUI_CONTAINER" >/dev/null
  wait_container "$THREEXUI_CONTAINER" 60 || die "3x-ui failed after panel setting update."
  sleep 3
fi

# Persist TLS + randomized subscription paths directly in the SQLite setting
# table. This also works around historical fresh-install TLS CLI persistence
# issues while keeping username/password changes on the official CLI.
docker stop "$THREEXUI_CONTAINER" >/dev/null

sql_set(){
  local key="$1" value="$2"
  sqlite3 "$DB" "
    UPDATE settings SET value='${value}' WHERE key='${key}';
    INSERT INTO settings(key,value)
      SELECT '${key}','${value}'
      WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='${key}');
  "
}

sql_set webBasePath "$RESOLVED_PANEL_BASE_PATH"
sql_set webCertFile "/root/cert/fullchain.pem"
sql_set webKeyFile "/root/cert/private.key"
sql_set subPath "$RESOLVED_SUB_PATH"
sql_set subJsonPath "$RESOLVED_SUB_JSON_PATH"
sql_set subClashPath "$RESOLVED_SUB_CLASH_PATH"
sql_set subDomain "$DOMAIN"
sql_set subCertFile "/root/cert/fullchain.pem"
sql_set subKeyFile "/root/cert/private.key"

docker start "$THREEXUI_CONTAINER" >/dev/null
wait_container "$THREEXUI_CONTAINER" 60 || die "3x-ui failed after TLS/subscription settings."
sleep 5

port_listening "$RESOLVED_PANEL_PORT" || {
  docker logs --tail 200 "$THREEXUI_CONTAINER" 2>&1 || true
  die "3x-ui panel port ${RESOLVED_PANEL_PORT} is not listening."
}

HTTP_CODE="$(
  curl -k -sS -o /dev/null -w '%{http_code}' \
    --connect-timeout 5 --max-time 10 \
    --resolve "${DOMAIN}:${RESOLVED_PANEL_PORT}:127.0.0.1" \
    "https://${DOMAIN}:${RESOLVED_PANEL_PORT}${RESOLVED_PANEL_BASE_PATH}" 2>/dev/null || true
)"
case "$HTTP_CODE" in
  2??|3??) log "3x-ui HTTPS panel responded with HTTP ${HTTP_CODE}." ;;
  *)
    docker logs --tail 200 "$THREEXUI_CONTAINER" 2>&1 || true
    die "3x-ui HTTPS verification failed (HTTP=${HTTP_CODE:-none})."
    ;;
esac

INSTALLED_FP="$(openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
SERVED_FP="$(
  timeout 8 openssl s_client \
    -connect "127.0.0.1:${RESOLVED_PANEL_PORT}" \
    -servername "$DOMAIN" </dev/null 2>/dev/null |
  openssl x509 -noout -fingerprint -sha256 2>/dev/null |
  cut -d= -f2
)"
[ -n "$SERVED_FP" ] && [ "$SERVED_FP" = "$INSTALLED_FP" ] ||
  die "3x-ui is not serving the installed TLS certificate."

touch "$MARKER"
chmod 600 "$MARKER"
write_result
log "3x-ui ready: https://${DOMAIN}:${RESOLVED_PANEL_PORT}${RESOLVED_PANEL_BASE_PATH}"
