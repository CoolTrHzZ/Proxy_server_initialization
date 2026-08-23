#!/usr/bin/env bash
set -Eeuo pipefail

REPO="CoolTrHzZ/Proxy_server_initialization"
VERSION="${1:-latest}"
TMP="/tmp/proxy-server-init.zip"
WORK="/tmp/proxy-server-init-download"

if [ "$(id -u)" != "0" ]; then
  echo "Please run as root"
  exit 1
fi

command -v curl >/dev/null || { apt update && apt install -y curl; }
command -v unzip >/dev/null || { apt update && apt install -y unzip; }

rm -rf "$WORK"
mkdir -p "$WORK"

if [ "$VERSION" = "latest" ]; then
  URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | awk -F '"' '/browser_download_url/ && /zip/ {print $4; exit}')
else
  URL="https://github.com/${REPO}/releases/download/${VERSION}/proxy-server-initialization-${VERSION}.zip"
fi

if [ -z "${URL:-}" ]; then
  echo "Cannot find release package"
  exit 1
fi

echo "Downloading ${URL}"
curl -fL "$URL" -o "$TMP"

unzip -q "$TMP" -d "$WORK"
DIR=$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -1)

cd "$DIR"
chmod +x *.sh

exec ./install.sh
