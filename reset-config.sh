#!/usr/bin/env bash
set -Eeuo pipefail
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

echo "This only removes bootstrap identity/config state."
echo "It does NOT delete Docker containers, certificates, or service data."
read -rp "Type RESET to continue: " ans
[ "$ans" = "RESET" ] || { echo "Cancelled."; exit 0; }

rm -f \
  /etc/vps-bootstrap/config.env \
  /etc/vps-bootstrap/secrets.env \
  /etc/vps-bootstrap/runtime.env \
  /root/vps-bootstrap-result.env

echo "Bootstrap config state removed."
echo "Run bash install.sh to enter first-run configuration again."
