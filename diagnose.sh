#!/usr/bin/env bash
set -u
set -o pipefail

TS="$(date '+%Y%m%d_%H%M%S')"
OUT="/root/vps-bootstrap-diagnostic-${TS}.log"
exec > >(tee "$OUT") 2>&1

RUNTIME="/etc/vps-bootstrap/runtime.env"
CONFIG="/etc/vps-bootstrap/config.env"

DOMAIN=""
CERT_DIR=""
NODE_EXPORTER_PORT="9100"
METRIC_PREFIX=""

if [ -r "$RUNTIME" ]; then
  # shellcheck disable=SC1090
  source "$RUNTIME"
elif [ -r "$CONFIG" ]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
  [ -n "${DOMAIN:-}" ] && CERT_DIR="${CERT_DIR:-/etc/ssl/${DOMAIN}}"
fi

mask_env(){
  local f="$1"
  [ -r "$f" ] || { echo "[missing] $f"; return 0; }
  awk -F= '
    BEGIN{OFS="="}
    /^[[:space:]]*#/ || NF<2 {print; next}
    {
      k=$1; l=tolower(k)
      if (l ~ /(token|secret|password|passwd|private|api[_-]?key|username|uuid)/)
        print k,"<REDACTED>"
      else if (l ~ /(base.*path|sub.*path)/)
        print k,"<REDACTED_PATH>"
      else
        print
    }
  ' "$f"
}

echo "Proxy Bootstrap Diagnostic v1.2.0"
echo "Generated: $(date -Is 2>/dev/null || date)"
echo "Output: $OUT"

echo
echo "=== HOST / OS ==="
hostnamectl 2>&1 || true
uname -a
cat /etc/os-release

echo
echo "=== NETWORK ==="
ip -br addr
ip route
ip rule
echo "Public IPv4: $(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || echo UNKNOWN)"
[ -n "${DOMAIN:-}" ] && getent ahostsv4 "$DOMAIN" || true

echo
echo "=== WARP RESIDUE ==="
command -v warp-cli || true
dpkg -l 2>/dev/null | grep -Ei 'cloudflare|warp' || true
systemctl list-unit-files 2>/dev/null | grep -Ei 'cloudflare|warp' || true
ip route show table all 2>/dev/null | grep -Ei 'warp|wgcf|cloudflare' || true

echo
echo "=== RESOURCES ==="
free -h
swapon --show
df -h /

echo
echo "=== DOCKER ==="
docker --version 2>/dev/null || true
docker info 2>/dev/null || true
docker ps -a 2>/dev/null || true
docker images 2>/dev/null || true

echo
echo "=== CONFIG (SANITIZED) ==="
mask_env "$CONFIG"
echo
mask_env "$RUNTIME"

echo
echo "=== ACME ==="
/root/.acme.sh/acme.sh --version 2>/dev/null || true
/root/.acme.sh/acme.sh --list 2>/dev/null || true

echo
echo "=== CERTIFICATE ==="
if [ -n "${CERT_DIR:-}" ] && [ -s "${CERT_DIR}/fullchain.pem" ]; then
  openssl x509 -in "${CERT_DIR}/fullchain.pem" \
    -noout -subject -issuer -dates -serial -fingerprint -sha256 -ext subjectAltName 2>/dev/null || true
else
  echo "certificate not found or CERT_DIR unknown"
fi

echo
echo "=== TIMERS ==="
systemctl list-timers --all --no-pager 2>/dev/null |
  grep -E 'acme-renew|host-prom|host-health' || true

echo
echo "=== RELEVANT SERVICES ==="
systemctl status \
  acme-renew.timer \
  host-prom-metrics.timer \
  host-health-check.timer \
  --no-pager -l 2>&1 || true

echo
echo "=== CONTAINER LOGS ==="
for c in 3xui-blue node-exporter; do
  echo "--- $c ---"
  docker inspect -f 'status={{.State.Status}} restart={{.HostConfig.RestartPolicy.Name}} image={{.Config.Image}}' "$c" 2>/dev/null || true
  docker logs --tail 100 "$c" 2>&1 || true
done

echo
echo "=== METRICS ==="
if [ -n "${NODE_EXPORTER_PORT:-}" ]; then
  TMP="$(mktemp)"
  if curl -fsS --max-time 10 "http://127.0.0.1:${NODE_EXPORTER_PORT}/metrics" -o "$TMP" 2>/dev/null; then
    if [ -n "${METRIC_PREFIX:-}" ]; then
      grep -E "^(${METRIC_PREFIX}_|node_textfile_)" "$TMP" | head -n 150 || true
    else
      grep -E '^node_textfile_' "$TMP" | head -n 50 || true
    fi
  else
    echo "node_exporter metrics unavailable"
  fi
  rm -f "$TMP"
fi

echo
echo "=== FAILED UNITS ==="
systemctl --failed --no-pager || true

echo
echo "DONE: $OUT"
