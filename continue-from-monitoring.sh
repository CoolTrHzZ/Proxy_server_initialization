#!/usr/bin/env bash
set -Eeuo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"

require_root
module_context

LOG_FILE="/root/vps-bootstrap-continue-$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

CURRENT_STAGE="startup"
trap 'rc=$?; echo; echo "[FAIL] stage=${CURRENT_STAGE} exit=${rc}"; echo "Log: ${LOG_FILE}"; exit $rc' ERR

for m in \
  60-monitoring.sh \
  70-health.sh \
  80-prometheus-output.sh \
  90-verify.sh
do
  CURRENT_STAGE="$m"
  stage "$m"
  bash "${SUITE_DIR}/modules/$m"
done

echo
echo "Continuation completed successfully."
echo "Result: /root/vps-bootstrap-result.env"
echo "Log: ${LOG_FILE}"
