#!/usr/bin/env bash
set -Eeuo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SUITE_DIR
source "${SUITE_DIR}/lib/common.sh"

require_root
bootstrap_prereqs
interactive_config
load_config
ensure_runtime

LOG_FILE="/root/vps-bootstrap-run-$(date '+%Y%m%d_%H%M%S').log"
exec > >(tee -a "$LOG_FILE") 2>&1

CURRENT_STAGE="startup"
trap 'rc=$?; echo; echo "[FAIL] stage=${CURRENT_STAGE} exit=${rc}"; echo "Log: ${LOG_FILE}"; echo "You can safely rerun: bash run.sh"; exit $rc' ERR

echo "=================================================================="
echo "Proxy Server Initialization v1.2.0"
echo "=================================================================="
echo "State-aware / idempotent bootstrap"
echo "No legacy x-ui"
echo "No Cloudflare WARP"
echo "No Docker Compose dependency"
echo "Instance: ${INSTANCE_NAME}"
echo "Domain: ${DOMAIN}"
echo "Public IP: ${PUBLIC_IP:-auto}"
echo "Metric prefix: ${METRIC_PREFIX}"
echo "Log: ${LOG_FILE}"
echo

declare -a MODULES=(
  "00-preflight.sh"
  "10-system.sh"
  "20-docker.sh"
  "30-acme.sh"
  "40-3xui.sh"
  "50-node-exporter.sh"
  "60-monitoring.sh"
  "70-health.sh"
  "80-prometheus-output.sh"
  "90-verify.sh"
)

for m in "${MODULES[@]}"; do
  CURRENT_STAGE="$m"
  stage "$m"
  bash "${SUITE_DIR}/modules/$m"
done

CURRENT_STAGE="done"
echo
echo "Bootstrap completed successfully."
echo "Credentials/result file: ${RESULT_FILE}"
echo "Prometheus output: ${OUTPUT_DIR}"
echo "Verify anytime: bash ${SUITE_DIR}/verify.sh"
echo
echo "To view panel credentials:"
echo "  cat ${RESULT_FILE}"
