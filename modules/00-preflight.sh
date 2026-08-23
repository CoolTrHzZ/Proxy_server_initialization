#!/usr/bin/env bash
set -Eeuo pipefail
SUITE_DIR="${SUITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"
module_context

source /etc/os-release
[ "${ID:-}" = "ubuntu" ] || die "This suite currently supports Ubuntu only."

log "OS=${PRETTY_NAME:-unknown}; kernel=$(uname -r); arch=$(uname -m)"

DEFAULT_ROUTE="$(ip route show default | head -n1 || true)"
[ -n "$DEFAULT_ROUTE" ] || die "No default route."
log "Default route: $DEFAULT_ROUTE"

if command -v warp-cli >/dev/null 2>&1 ||
   dpkg -l 2>/dev/null | grep -q '^ii[[:space:]]\+cloudflare-warp' ||
   systemctl list-unit-files 2>/dev/null | grep -qi 'warp-svc'; then
  die "Cloudflare WARP residue detected. This bootstrap intentionally does not install or use WARP."
fi

ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 || die "IPv4 connectivity failed."
curl -4 -fsS --max-time 10 https://github.com >/dev/null || die "GitHub connectivity failed."

CURRENT_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
if [ -n "$CURRENT_IP" ]; then
  log "Detected public IPv4=$CURRENT_IP"
  if [ -n "$PUBLIC_IP" ] && [ "$CURRENT_IP" != "$PUBLIC_IP" ]; then
    warn "Configured PUBLIC_IP=$PUBLIC_IP differs from detected IP=$CURRENT_IP"
  fi
fi

DNS_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}')"
[ -n "$DNS_IP" ] && log "${DOMAIN} resolves to ${DNS_IP}" || warn "${DOMAIN} does not currently resolve via A/AAAA lookup."

if [ "${VERSION_ID:-}" = "20.04" ]; then
  warn "Ubuntu 20.04 detected. v1.2.0 avoids Docker Compose completely and uses Docker CLI for compatibility."
fi
