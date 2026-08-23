#!/usr/bin/env bash
set -u
set -o pipefail

RUNTIME="/etc/vps-bootstrap/runtime.env"
[ -r "$RUNTIME" ] || exit 1
source "$RUNTIME"

LOG_DIR="/root/logs/host-health"
DAILY_LOG="${LOG_DIR}/host-health-$(date '+%Y%m%d').log"
LATEST="${LOG_DIR}/latest-status.txt"
CERT="${CERT_DIR}/fullchain.pem"
KEY="${CERT_DIR}/private.key"

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

PASS=0 WARN=0 FAIL=0
ts(){ date '+%F %T %Z'; }
pass(){ PASS=$((PASS+1)); echo "[$(ts)] [PASS] $*"; }
warn(){ WARN=$((WARN+1)); echo "[$(ts)] [WARN] $*"; }
fail(){ FAIL=$((FAIL+1)); echo "[$(ts)] [FAIL] $*"; }
port(){ ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"; }
container(){ [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]; }

{
echo "=================================================================="
echo "VPS HOST HEALTH CHECK"
echo "=================================================================="

PCT="$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}')"
if [ "$PCT" -ge "$DISK_CRIT_PCT" ]; then fail "root disk=${PCT}%"
elif [ "$PCT" -ge "$DISK_WARN_PCT" ]; then warn "root disk=${PCT}%"
else pass "root disk=${PCT}%"; fi

MEM_KB="$(awk '/MemAvailable:/{print $2}' /proc/meminfo)"
MEM_MB=$(( ${MEM_KB:-0} / 1024 ))
if [ "$MEM_MB" -le "$MEM_AVAIL_CRIT_MB" ]; then fail "available memory=${MEM_MB}MB"
elif [ "$MEM_MB" -le "$MEM_AVAIL_WARN_MB" ]; then warn "available memory=${MEM_MB}MB"
else pass "available memory=${MEM_MB}MB"; fi

ST="$(awk '/SwapTotal:/{print $2}' /proc/meminfo)"
SF="$(awk '/SwapFree:/{print $2}' /proc/meminfo)"
if [ "${ST:-0}" -gt 0 ]; then
  SP=$(( (ST-SF)*100/ST ))
  if [ "$SP" -ge "$SWAP_CRIT_PCT" ]; then fail "swap=${SP}%"
  elif [ "$SP" -ge "$SWAP_WARN_PCT" ]; then warn "swap=${SP}%"
  else pass "swap=${SP}%"; fi
else
  warn "swap not configured"
fi

if [ -s "$CERT" ] && [ -s "$KEY" ]; then
  CH="$(openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null |
        openssl pkey -pubin -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}')"
  KH="$(openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}')"
  [ -n "$CH" ] && [ "$CH" = "$KH" ] && pass "certificate/private key match" || fail "certificate/private key mismatch"

  if openssl x509 -in "$CERT" -noout -checkend $((CERT_CRIT_DAYS*86400)) >/dev/null 2>&1; then
    if openssl x509 -in "$CERT" -noout -checkend $((CERT_WARN_DAYS*86400)) >/dev/null 2>&1; then
      pass "certificate valid >${CERT_WARN_DAYS}d"
    else
      warn "certificate expires within ${CERT_WARN_DAYS}d"
    fi
  else
    fail "certificate expires within ${CERT_CRIT_DAYS}d"
  fi
else
  fail "certificate/key missing"
fi

systemctl is-active --quiet acme-renew.timer 2>/dev/null && pass "acme-renew.timer active" || fail "acme-renew.timer inactive"
systemctl is-active --quiet docker 2>/dev/null && pass "docker active" || fail "docker inactive"

container "$THREEXUI_CONTAINER" && pass "3x-ui running" || fail "3x-ui not running"
port "$RESOLVED_PANEL_PORT" && pass "panel port ${RESOLVED_PANEL_PORT} listening" || fail "panel port ${RESOLVED_PANEL_PORT} not listening"

if container "$THREEXUI_CONTAINER"; then
  mapfile -t RPORTS < <(
    docker exec "$THREEXUI_CONTAINER" sh -c 'cat /app/bin/config.json 2>/dev/null || true' |
    jq -r '.inbounds[]? | select(.protocol=="vless" and .streamSettings.security=="reality") | .port' 2>/dev/null |
    awk '/^[0-9]+$/'
  )
  if [ "${#RPORTS[@]}" -eq 0 ]; then
    warn "REALITY inbound not configured yet"
  else
    for p in "${RPORTS[@]}"; do
      port "$p" && pass "REALITY port ${p} listening" || fail "REALITY port ${p} not listening"
    done
  fi
fi

container "$NODE_EXPORTER_CONTAINER" && pass "node_exporter running" || fail "node_exporter not running"
port "$NODE_EXPORTER_PORT" && pass "node_exporter port ${NODE_EXPORTER_PORT} listening" || fail "node_exporter port ${NODE_EXPORTER_PORT} not listening"

ERR="$(curl -fsS "http://127.0.0.1:${NODE_EXPORTER_PORT}/metrics" 2>/dev/null |
       awk '/^node_textfile_scrape_error /{print $2;exit}')"
[ "$ERR" = "0" ] && pass "Textfile Collector error=0" || fail "Textfile Collector error=${ERR:-unknown}"

OOM="$(journalctl -k --since '1 hour ago' --no-pager 2>/dev/null |
       grep -Ei 'out of memory|oom-killer|killed process' | tail -n 3 || true)"
[ -z "$OOM" ] && pass "no OOM in last hour" || fail "recent OOM detected"

if [ "$FAIL" -gt 0 ]; then OVERALL=CRITICAL
elif [ "$WARN" -gt 0 ]; then OVERALL=WARN
else OVERALL=HEALTHY
fi

echo "overall=${OVERALL} pass=${PASS} warn=${WARN} fail=${FAIL}"
cat >"$LATEST" <<EOF
timestamp=$(ts)
overall=${OVERALL}
pass=${PASS}
warn=${WARN}
fail=${FAIL}
EOF
chmod 600 "$LATEST"
find "$LOG_DIR" -maxdepth 1 -type f -name 'host-health-*.log' -mtime +30 -delete 2>/dev/null || true
echo "=================================================================="
} | tee -a "$DAILY_LOG"

chmod 600 "$DAILY_LOG"
exit 0
