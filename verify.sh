#!/usr/bin/env bash
set -Eeuo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"
require_root
recover_existing_config
load_config
ensure_runtime
bash "${SUITE_DIR}/modules/90-verify.sh"
echo
/usr/local/sbin/host-health-check.sh || true
