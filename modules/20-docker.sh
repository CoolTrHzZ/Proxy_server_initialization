#!/usr/bin/env bash
set -Eeuo pipefail
SUITE_DIR="${SUITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"
module_context

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  log "Docker already active: $(docker --version)"
else
  log "Installing Docker Engine from Ubuntu repository (Compose is not required by this suite)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y docker.io
  systemctl enable --now docker
fi

systemctl enable --now docker
docker info >/dev/null
log "$(docker --version)"
log "Docker Compose is intentionally not required."
