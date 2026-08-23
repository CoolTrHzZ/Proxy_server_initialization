#!/usr/bin/env bash
set -Eeuo pipefail
SUITE_DIR="${SUITE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"
module_context

TEXT_DIR="/var/lib/node_exporter/textfile_collector"
mkdir -p "$TEXT_DIR"
chmod 755 /var/lib/node_exporter "$TEXT_DIR"

docker pull "$NODE_EXPORTER_IMAGE"

DESIRED_HASH="$(
  printf '%s\n' "$NODE_EXPORTER_IMAGE" "$NODE_EXPORTER_PORT" |
  sha256sum | awk '{print $1}'
)"
CURRENT_HASH="$(docker inspect -f '{{index .Config.Labels "io.trhzz.bootstrap.config-hash"}}' "$NODE_EXPORTER_CONTAINER" 2>/dev/null || true)"
NEED_RECREATE=0

if ! docker inspect "$NODE_EXPORTER_CONTAINER" >/dev/null 2>&1; then
  NEED_RECREATE=1
elif [ "$CURRENT_HASH" != "$DESIRED_HASH" ]; then
  NEED_RECREATE=1
elif ! container_running "$NODE_EXPORTER_CONTAINER"; then
  docker start "$NODE_EXPORTER_CONTAINER" >/dev/null || NEED_RECREATE=1
fi

if [ "$NEED_RECREATE" -eq 1 ]; then
  log "Creating/reconciling node_exporter using Docker CLI..."
  docker rm -f "$NODE_EXPORTER_CONTAINER" >/dev/null 2>&1 || true

  docker run -d \
    --name "$NODE_EXPORTER_CONTAINER" \
    --network host \
    --pid host \
    --restart always \
    --label "io.trhzz.bootstrap.managed=true" \
    --label "io.trhzz.bootstrap.config-hash=${DESIRED_HASH}" \
    -v /:/host:ro,rslave \
    -v "${TEXT_DIR}:/textfile:ro" \
    --log-driver json-file \
    --log-opt max-size=10m \
    --log-opt max-file=3 \
    "$NODE_EXPORTER_IMAGE" \
    --path.rootfs=/host \
    --collector.textfile.directory=/textfile >/dev/null
fi

wait_container "$NODE_EXPORTER_CONTAINER" 30 || die "node_exporter container failed to start."
sleep 2
curl -fsS "http://127.0.0.1:${NODE_EXPORTER_PORT}/metrics" >/dev/null ||
  die "node_exporter metrics endpoint unavailable."
log "node_exporter ready on :${NODE_EXPORTER_PORT}"
