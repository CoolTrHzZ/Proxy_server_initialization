#!/usr/bin/env bash
set -u
set -o pipefail

RUNTIME="/etc/vps-bootstrap/runtime.env"
[ -r "$RUNTIME" ] || exit 0
source "$RUNTIME"

CERT="${CERT_DIR}/fullchain.pem"
KEY="${CERT_DIR}/private.key"
[ -s "$CERT" ] && [ -s "$KEY" ] || exit 1

CH="$(openssl x509 -in "$CERT" -pubkey -noout 2>/dev/null |
      openssl pkey -pubin -outform DER 2>/dev/null |
      sha256sum | awk '{print $1}')"
KH="$(openssl pkey -in "$KEY" -pubout -outform DER 2>/dev/null |
      sha256sum | awk '{print $1}')"
[ -n "$CH" ] && [ "$CH" = "$KH" ] || exit 1

if [ "$(docker inspect -f '{{.State.Running}}' "$THREEXUI_CONTAINER" 2>/dev/null || true)" = "true" ]; then
  docker restart "$THREEXUI_CONTAINER" >/dev/null 2>&1 || exit 1
fi

logger -t vps-cert-reload "certificate consumers reloaded"
exit 0
