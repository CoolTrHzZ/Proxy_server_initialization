#!/usr/bin/env bash
set -Eeuo pipefail

SUITE_DIR="${SUITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ETC_DIR="/etc/vps-bootstrap"
STATE_DIR="/var/lib/vps-bootstrap"
CONFIG_FILE="${ETC_DIR}/config.env"
SECRETS_FILE="${ETC_DIR}/secrets.env"
RUNTIME_FILE="${ETC_DIR}/runtime.env"
RESULT_FILE="/root/vps-bootstrap-result.env"
OUTPUT_DIR="/root/vps-bootstrap-output"

log(){ printf '[%s] [INFO] %s\n' "$(date '+%F %T')" "$*"; }
warn(){ printf '[%s] [WARN] %s\n' "$(date '+%F %T')" "$*" >&2; }
die(){ printf '[%s] [FAIL] %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

require_root(){ [ "$(id -u)" -eq 0 ] || die "Run as root."; }
has(){ command -v "$1" >/dev/null 2>&1; }

bootstrap_prereqs(){
  # Fresh Ubuntu images may not contain curl/openssl. Install only the minimal
  # commands needed before the first interactive configuration.
  local missing=0
  for cmd in curl openssl ip ss awk grep sed; do
    command -v "$cmd" >/dev/null 2>&1 || missing=1
  done

  if [ "$missing" -eq 1 ]; then
    log "Installing minimal first-run prerequisites..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl openssl iproute2 gawk grep sed
  fi
}

container_running(){
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

port_listening(){
  ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${1}$"
}

random_hex(){
  local bytes="${1:-12}"
  od -An -N"$bytes" -tx1 /dev/urandom | tr -d ' \n'
}

random_port(){
  local p
  while :; do
    p="$((20000 + RANDOM % 20000 + RANDOM % 20000))"
    [ "$p" -le 60000 ] || p="$((20000 + RANDOM % 40000))"
    port_listening "$p" || { echo "$p"; return 0; }
  done
}

valid_port(){
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

wait_container(){
  local name="$1" timeout="${2:-60}" i
  for i in $(seq 1 "$timeout"); do
    container_running "$name" && return 0
    sleep 1
  done
  return 1
}

cert_key_match(){
  local cert="$1" key="$2" a b
  [ -s "$cert" ] && [ -s "$key" ] || return 1
  a="$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null |
       openssl pkey -pubin -outform DER 2>/dev/null |
       sha256sum | awk '{print $1}')"
  b="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null |
       sha256sum | awk '{print $1}')"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

normalize_path(){
  local p="$1"
  [[ "$p" == /* ]] || p="/$p"
  [[ "$p" == */ ]] || p="${p}/"
  printf '%s\n' "$p"
}

init_dirs(){
  mkdir -p "$ETC_DIR" "$STATE_DIR" "$OUTPUT_DIR"
  chmod 700 "$ETC_DIR" "$STATE_DIR"
  chmod 755 "$OUTPUT_DIR"
}

recover_existing_config(){
  init_dirs

  if [ ! -s "$CONFIG_FILE" ]; then
    for f in \
      "${SUITE_DIR}/config.env" \
      "/root/proxy-emergency-bootstrap/config.env"
    do
      if [ -s "$f" ]; then
        log "Recovering existing config from $f"
        install -o root -g root -m 600 "$f" "$CONFIG_FILE"
        break
      fi
    done
  fi

  if [ ! -s "$SECRETS_FILE" ]; then
    for f in \
      "${SUITE_DIR}/secrets.env" \
      "/root/proxy-emergency-bootstrap/secrets.env"
    do
      if [ -s "$f" ]; then
        log "Recovering existing secrets from $f"
        install -o root -g root -m 600 "$f" "$SECRETS_FILE"
        break
      fi
    done
  fi

  [ -f "${SUITE_DIR}/config.env" ] && chmod 600 "${SUITE_DIR}/config.env" || true
  [ -f "${SUITE_DIR}/secrets.env" ] && chmod 600 "${SUITE_DIR}/secrets.env" || true
  [ -f "/root/proxy-emergency-bootstrap/config.env" ] && chmod 600 "/root/proxy-emergency-bootstrap/config.env" || true
  [ -f "/root/proxy-emergency-bootstrap/secrets.env" ] && chmod 600 "/root/proxy-emergency-bootstrap/secrets.env" || true
}

interactive_config(){
  recover_existing_config
  [ -s "$CONFIG_FILE" ] && return 0

  local default_ip instance domain public_ip email token zone metric_prefix v

  default_ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"

  echo
  echo "=================================================================="
  echo "FIRST-RUN CONFIGURATION"
  echo "=================================================================="
  echo "No personal domain or email is embedded in this package."
  echo

  read -rp "Instance name [vps-node]: " v
  instance="${v:-vps-node}"

  while :; do
    read -rp "Domain (required, e.g. panel.example.com): " domain
    [ -n "$domain" ] && break
    echo "Domain cannot be empty."
  done

  read -rp "Public IPv4 [${default_ip:-auto-detect later}]: " v
  public_ip="${v:-$default_ip}"

  while :; do
    read -rp "ACME email (required): " email
    [ -n "$email" ] && break
    echo "ACME email cannot be empty."
  done

  read -rp "Prometheus metric prefix [vpsnode]: " v
  metric_prefix="${v:-vpsnode}"
  [[ "$metric_prefix" =~ ^[A-Za-z_:][A-Za-z0-9_:]*$ ]] ||
    die "Invalid metric prefix: $metric_prefix"

  echo
  echo "Cloudflare token permissions:"
  echo "  Zone -> DNS -> Edit"
  echo "  Zone -> Zone -> Read"
  read -rsp "Cloudflare API Token: " token
  echo
  [ -n "$token" ] || die "Cloudflare API Token is required."

  read -rp "Cloudflare Zone ID (optional, press Enter to auto-discover): " zone

  cat >"$CONFIG_FILE" <<EOF
INSTANCE_NAME=$(printf '%q' "$instance")
PUBLIC_IP=$(printf '%q' "$public_ip")
DOMAIN=$(printf '%q' "$domain")
ACME_EMAIL=$(printf '%q' "$email")
ACME_MODE="dns_api"
ACME_DNS_PROVIDER="dns_cf"
CERT_WILDCARD="1"
CERT_DIR=""
THREEXUI_IMAGE="ghcr.io/mhsanaei/3x-ui:v3.6.0"
THREEXUI_CONTAINER="3xui-blue"
PANEL_PORT="auto"
PANEL_BASE_PATH="auto"
PANEL_USERNAME="auto"
PANEL_PASSWORD="auto"
FORCE_RECONFIGURE_PANEL="0"
NODE_EXPORTER_IMAGE="quay.io/prometheus/node-exporter:v1.9.1"
NODE_EXPORTER_CONTAINER="node-exporter"
NODE_EXPORTER_PORT="9100"
METRIC_PREFIX=$(printf '%q' "$metric_prefix")
SWAP_SIZE_MB="1024"
SWAPPINESS="10"
JOURNAL_MAX_USE="200M"
JOURNAL_RUNTIME_MAX_USE="50M"
JOURNAL_RETENTION="14day"
CUSTOM_METRICS_INTERVAL="1min"
HEALTH_CHECK_INTERVAL="10min"
DISK_WARN_PCT="80"
DISK_CRIT_PCT="90"
MEM_AVAIL_WARN_MB="150"
MEM_AVAIL_CRIT_MB="80"
SWAP_WARN_PCT="60"
SWAP_CRIT_PCT="85"
CERT_WARN_DAYS="15"
CERT_CRIT_DAYS="7"
EOF

  {
    printf 'CF_Token=%q\n' "$token"
    [ -n "$zone" ] && printf 'CF_Zone_ID=%q\n' "$zone"
  } >"$SECRETS_FILE"

  chmod 600 "$CONFIG_FILE" "$SECRETS_FILE"
  log "First-run configuration saved securely to ${ETC_DIR}."
}

load_config(){
  [ -s "$CONFIG_FILE" ] || die "Missing $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  INSTANCE_NAME="${INSTANCE_NAME:-vps-node}"
  PUBLIC_IP="${PUBLIC_IP:-}"
  DOMAIN="${DOMAIN:-}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  ACME_MODE="${ACME_MODE:-dns_api}"
  ACME_DNS_PROVIDER="${ACME_DNS_PROVIDER:-dns_cf}"
  CERT_WILDCARD="${CERT_WILDCARD:-1}"
  CERT_DIR="${CERT_DIR:-/etc/ssl/${DOMAIN}}"

  THREEXUI_IMAGE="${THREEXUI_IMAGE:-ghcr.io/mhsanaei/3x-ui:v3.6.0}"
  THREEXUI_CONTAINER="${THREEXUI_CONTAINER:-3xui-blue}"
  PANEL_PORT="${PANEL_PORT:-auto}"
  PANEL_BASE_PATH="${PANEL_BASE_PATH:-auto}"
  PANEL_USERNAME="${PANEL_USERNAME:-auto}"
  PANEL_PASSWORD="${PANEL_PASSWORD:-auto}"
  FORCE_RECONFIGURE_PANEL="${FORCE_RECONFIGURE_PANEL:-0}"

  NODE_EXPORTER_IMAGE="${NODE_EXPORTER_IMAGE:-quay.io/prometheus/node-exporter:v1.9.1}"
  NODE_EXPORTER_CONTAINER="${NODE_EXPORTER_CONTAINER:-node-exporter}"
  NODE_EXPORTER_PORT="${NODE_EXPORTER_PORT:-9100}"
  METRIC_PREFIX="${METRIC_PREFIX:-vpsnode}"

  SWAP_SIZE_MB="${SWAP_SIZE_MB:-1024}"
  SWAPPINESS="${SWAPPINESS:-10}"
  JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-200M}"
  JOURNAL_RUNTIME_MAX_USE="${JOURNAL_RUNTIME_MAX_USE:-50M}"
  JOURNAL_RETENTION="${JOURNAL_RETENTION:-14day}"
  CUSTOM_METRICS_INTERVAL="${CUSTOM_METRICS_INTERVAL:-1min}"
  HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-10min}"

  DISK_WARN_PCT="${DISK_WARN_PCT:-80}"
  DISK_CRIT_PCT="${DISK_CRIT_PCT:-90}"
  MEM_AVAIL_WARN_MB="${MEM_AVAIL_WARN_MB:-150}"
  MEM_AVAIL_CRIT_MB="${MEM_AVAIL_CRIT_MB:-80}"
  SWAP_WARN_PCT="${SWAP_WARN_PCT:-60}"
  SWAP_CRIT_PCT="${SWAP_CRIT_PCT:-85}"
  CERT_WARN_DAYS="${CERT_WARN_DAYS:-15}"
  CERT_CRIT_DAYS="${CERT_CRIT_DAYS:-7}"

  [[ "$METRIC_PREFIX" =~ ^[A-Za-z_:][A-Za-z0-9_:]*$ ]] || die "Invalid METRIC_PREFIX"
  [ -n "$DOMAIN" ] || die "DOMAIN is empty."
  [ -n "$ACME_EMAIL" ] || die "ACME_EMAIL is empty."

  if [ -z "$PUBLIC_IP" ] && command -v curl >/dev/null 2>&1; then
    PUBLIC_IP="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  fi

  export INSTANCE_NAME PUBLIC_IP DOMAIN ACME_EMAIL ACME_MODE ACME_DNS_PROVIDER CERT_WILDCARD CERT_DIR
  export THREEXUI_IMAGE THREEXUI_CONTAINER PANEL_PORT PANEL_BASE_PATH PANEL_USERNAME PANEL_PASSWORD FORCE_RECONFIGURE_PANEL
  export NODE_EXPORTER_IMAGE NODE_EXPORTER_CONTAINER NODE_EXPORTER_PORT METRIC_PREFIX
  export SWAP_SIZE_MB SWAPPINESS JOURNAL_MAX_USE JOURNAL_RUNTIME_MAX_USE JOURNAL_RETENTION
  export CUSTOM_METRICS_INTERVAL HEALTH_CHECK_INTERVAL
  export DISK_WARN_PCT DISK_CRIT_PCT MEM_AVAIL_WARN_MB MEM_AVAIL_CRIT_MB
  export SWAP_WARN_PCT SWAP_CRIT_PCT CERT_WARN_DAYS CERT_CRIT_DAYS
}

ensure_runtime(){
  init_dirs

  local old_port="" old_path="" old_user="" old_pass="" old_sub="" old_json="" old_clash=""
  if [ -s "$RUNTIME_FILE" ]; then
    # shellcheck disable=SC1090
    source "$RUNTIME_FILE"
    old_port="${RESOLVED_PANEL_PORT:-}"
    old_path="${RESOLVED_PANEL_BASE_PATH:-}"
    old_user="${RESOLVED_PANEL_USERNAME:-}"
    old_pass="${RESOLVED_PANEL_PASSWORD:-}"
    old_sub="${RESOLVED_SUB_PATH:-}"
    old_json="${RESOLVED_SUB_JSON_PATH:-}"
    old_clash="${RESOLVED_SUB_CLASH_PATH:-}"
  fi

  if [ "$PANEL_PORT" = "auto" ]; then
    RESOLVED_PANEL_PORT="${old_port:-$(random_port)}"
  else
    valid_port "$PANEL_PORT" || die "Invalid PANEL_PORT=$PANEL_PORT"
    RESOLVED_PANEL_PORT="$PANEL_PORT"
  fi

  if [ "$PANEL_BASE_PATH" = "auto" ]; then
    RESOLVED_PANEL_BASE_PATH="${old_path:-/$(random_hex 12)/}"
  else
    RESOLVED_PANEL_BASE_PATH="$(normalize_path "$PANEL_BASE_PATH")"
  fi

  RESOLVED_PANEL_USERNAME="$(
    if [ "$PANEL_USERNAME" = "auto" ]; then
      printf '%s\n' "${old_user:-u_$(random_hex 5)}"
    else
      printf '%s\n' "$PANEL_USERNAME"
    fi
  )"

  RESOLVED_PANEL_PASSWORD="$(
    if [ "$PANEL_PASSWORD" = "auto" ]; then
      printf '%s\n' "${old_pass:-$(random_hex 18)}"
    else
      printf '%s\n' "$PANEL_PASSWORD"
    fi
  )"

  RESOLVED_SUB_PATH="${old_sub:-/$(random_hex 12)/}"
  RESOLVED_SUB_JSON_PATH="${old_json:-/$(random_hex 12)/}"
  RESOLVED_SUB_CLASH_PATH="${old_clash:-/$(random_hex 12)/}"

  cat >"$RUNTIME_FILE" <<EOF
INSTANCE_NAME=$(printf '%q' "$INSTANCE_NAME")
PUBLIC_IP=$(printf '%q' "$PUBLIC_IP")
DOMAIN=$(printf '%q' "$DOMAIN")
CERT_DIR=$(printf '%q' "$CERT_DIR")
METRIC_PREFIX=$(printf '%q' "$METRIC_PREFIX")
THREEXUI_CONTAINER=$(printf '%q' "$THREEXUI_CONTAINER")
NODE_EXPORTER_CONTAINER=$(printf '%q' "$NODE_EXPORTER_CONTAINER")
NODE_EXPORTER_PORT=$(printf '%q' "$NODE_EXPORTER_PORT")
RESOLVED_PANEL_PORT=$(printf '%q' "$RESOLVED_PANEL_PORT")
RESOLVED_PANEL_BASE_PATH=$(printf '%q' "$RESOLVED_PANEL_BASE_PATH")
RESOLVED_PANEL_USERNAME=$(printf '%q' "$RESOLVED_PANEL_USERNAME")
RESOLVED_PANEL_PASSWORD=$(printf '%q' "$RESOLVED_PANEL_PASSWORD")
RESOLVED_SUB_PATH=$(printf '%q' "$RESOLVED_SUB_PATH")
RESOLVED_SUB_JSON_PATH=$(printf '%q' "$RESOLVED_SUB_JSON_PATH")
RESOLVED_SUB_CLASH_PATH=$(printf '%q' "$RESOLVED_SUB_CLASH_PATH")
DISK_WARN_PCT=$(printf '%q' "$DISK_WARN_PCT")
DISK_CRIT_PCT=$(printf '%q' "$DISK_CRIT_PCT")
MEM_AVAIL_WARN_MB=$(printf '%q' "$MEM_AVAIL_WARN_MB")
MEM_AVAIL_CRIT_MB=$(printf '%q' "$MEM_AVAIL_CRIT_MB")
SWAP_WARN_PCT=$(printf '%q' "$SWAP_WARN_PCT")
SWAP_CRIT_PCT=$(printf '%q' "$SWAP_CRIT_PCT")
CERT_WARN_DAYS=$(printf '%q' "$CERT_WARN_DAYS")
CERT_CRIT_DAYS=$(printf '%q' "$CERT_CRIT_DAYS")
EOF
  chmod 600 "$RUNTIME_FILE"
  export RESOLVED_PANEL_PORT RESOLVED_PANEL_BASE_PATH RESOLVED_PANEL_USERNAME RESOLVED_PANEL_PASSWORD
  export RESOLVED_SUB_PATH RESOLVED_SUB_JSON_PATH RESOLVED_SUB_CLASH_PATH
}

write_result(){
  cat >"$RESULT_FILE" <<EOF
PANEL_URL=$(printf '%q' "https://${DOMAIN}:${RESOLVED_PANEL_PORT}${RESOLVED_PANEL_BASE_PATH}")
PANEL_USERNAME=$(printf '%q' "$RESOLVED_PANEL_USERNAME")
PANEL_PASSWORD=$(printf '%q' "$RESOLVED_PANEL_PASSWORD")
PANEL_PORT=$(printf '%q' "$RESOLVED_PANEL_PORT")
PANEL_BASE_PATH=$(printf '%q' "$RESOLVED_PANEL_BASE_PATH")
SUBSCRIPTION_BASE=$(printf '%q' "https://${DOMAIN}:2096${RESOLVED_SUB_PATH}")
SUB_PATH=$(printf '%q' "$RESOLVED_SUB_PATH")
SUB_JSON_PATH=$(printf '%q' "$RESOLVED_SUB_JSON_PATH")
SUB_CLASH_PATH=$(printf '%q' "$RESOLVED_SUB_CLASH_PATH")
NODE_EXPORTER_TARGET=$(printf '%q' "${PUBLIC_IP:-<PUBLIC_IP>}:${NODE_EXPORTER_PORT}")
CERT_FILE=$(printf '%q' "${CERT_DIR}/fullchain.pem")
CERT_KEY=$(printf '%q' "${CERT_DIR}/private.key")
EOF
  chmod 600 "$RESULT_FILE"
}

module_context(){
  recover_existing_config
  load_config
  ensure_runtime
}

stage(){
  printf '\n==================================================================\n'
  printf 'STAGE: %s\n' "$1"
  printf '==================================================================\n'
}
