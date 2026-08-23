#!/usr/bin/env bash
set -Eeuo pipefail
SUITE_DIR="${SUITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"
module_context

mkdir -p "$CERT_DIR"
chmod 700 "$CERT_DIR"

if [ ! -x /root/.acme.sh/acme.sh ]; then
  log "Installing acme.sh..."
  TMP="$(mktemp -d)"
  git clone --depth 1 https://github.com/acmesh-official/acme.sh.git "$TMP/acme.sh"
  (
    cd "$TMP/acme.sh"
    ./acme.sh --install -m "$ACME_EMAIL" --nocron
  )
  rm -rf "$TMP"
fi

/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

install -o root -g root -m 700 \
  "${SUITE_DIR}/payload/reload-vps-cert-consumers.sh" \
  /usr/local/sbin/reload-vps-cert-consumers.sh

cat >/etc/systemd/system/acme-renew.service <<EOF
[Unit]
Description=acme.sh certificate renewal
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${SECRETS_FILE}
ExecStart=/root/.acme.sh/acme.sh --cron --home /root/.acme.sh
EOF

cat >/etc/systemd/system/acme-renew.timer <<'EOF'
[Unit]
Description=Daily acme.sh certificate renewal check

[Timer]
OnCalendar=*-*-* 03:10:00
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now acme-renew.timer

if [ -s "$SECRETS_FILE" ]; then
  set -a
  source "$SECRETS_FILE"
  set +a
fi

[ "$ACME_MODE" = "dns_api" ] || die "v1.1.0 production profile currently expects ACME_MODE=dns_api."
[ "$ACME_DNS_PROVIDER" = "dns_cf" ] || warn "DNS provider is $ACME_DNS_PROVIDER; only dns_cf was validated in this rebuild."
[ -n "${CF_Token:-}" ] || die "CF_Token is missing from ${SECRETS_FILE}."
log "Cloudflare API token loaded (length=${#CF_Token}); token value is not printed."

CERT="${CERT_DIR}/fullchain.pem"
KEY="${CERT_DIR}/private.key"
MANAGED_CONF="/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.conf"

PROD_OK=0
if cert_key_match "$CERT" "$KEY" &&
   openssl x509 -in "$CERT" -noout -checkend $((30*86400)) >/dev/null 2>&1 &&
   openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -Fq "DNS:${DOMAIN}"; then
  if [ "$CERT_WILDCARD" != "1" ] ||
     openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null | grep -Fq "DNS:*.${DOMAIN}"; then
    PROD_OK=1
  fi
fi

if [ "$PROD_OK" -eq 1 ] && [ -s "$MANAGED_CONF" ]; then
  log "Existing production certificate is healthy and managed by acme.sh; skipping issuance."
else
  log "Issuing/refreshing certificate for ${DOMAIN}..."
  ISSUE=(--issue --server letsencrypt --dns "$ACME_DNS_PROVIDER" --keylength ec-256 -d "$DOMAIN")
  [ "$CERT_WILDCARD" = "1" ] && ISSUE+=(-d "*.${DOMAIN}")

  if ! /root/.acme.sh/acme.sh "${ISSUE[@]}"; then
    if cert_key_match "$CERT" "$KEY" &&
       openssl x509 -in "$CERT" -noout -checkend 86400 >/dev/null 2>&1; then
      warn "acme.sh returned non-zero but the installed production certificate is valid; continuing."
    else
      die "Certificate issuance failed and no valid production certificate is available."
    fi
  fi
fi

/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
  --key-file "${CERT_DIR}/private.key" \
  --fullchain-file "${CERT_DIR}/fullchain.pem" \
  --reloadcmd "/usr/local/sbin/reload-vps-cert-consumers.sh"

chmod 700 "$CERT_DIR"
chmod 644 "${CERT_DIR}/fullchain.pem"
chmod 600 "${CERT_DIR}/private.key"

cert_key_match "${CERT_DIR}/fullchain.pem" "${CERT_DIR}/private.key" ||
  die "Certificate/private key mismatch."

openssl x509 -in "${CERT_DIR}/fullchain.pem" -noout -subject -issuer -dates -ext subjectAltName
