#!/usr/bin/env bash
set -Eeuo pipefail

RUNTIME="/etc/vps-bootstrap/runtime.env"
[ -r "$RUNTIME" ] || { echo "Missing $RUNTIME" >&2; exit 1; }
# shellcheck disable=SC1090
source "$RUNTIME"

OUT="/root/vps-bootstrap-output"
mkdir -p "$OUT"

TARGET="${PUBLIC_IP:-<PUBLIC_IP>}:${NODE_EXPORTER_PORT}"
SAFE_INSTANCE="$(printf '%s' "$INSTANCE_NAME" | tr -cs 'A-Za-z0-9_.-' '_')"

cat >"${OUT}/node-exporter-target.json" <<EOF
[
  {
    "targets": ["${TARGET}"],
    "labels": {
      "env": "vps",
      "instance_name": "${INSTANCE_NAME}",
      "managed_by": "vps-bootstrap"
    }
  }
]
EOF

cat >"${OUT}/${SAFE_INSTANCE}-rules.yml" <<EOF
groups:
- name: VPSBootstrap.rules
  rules:
  - alert: VpsCustomMetricsMissing
    expr: absent(${METRIC_PREFIX}_metrics_last_run_timestamp_seconds{job="node-exporter",instance_name="${INSTANCE_NAME}"})
    for: 5m
    labels: {severity: ERROR, category: monitor}
    annotations:
      title: "${INSTANCE_NAME} 自定义监控指标消失"
      description: "Textfile 自定义指标连续 5 分钟无法获取。"

  - alert: VpsCustomMetricsStale
    expr: time() - ${METRIC_PREFIX}_metrics_last_run_timestamp_seconds{job="node-exporter",instance_name="${INSTANCE_NAME}"} > 300
    for: 5m
    labels: {severity: ERROR, category: monitor}
    annotations:
      title: "${INSTANCE_NAME} 自定义指标停止更新"
      description: "自定义指标超过 5 分钟没有刷新。"

  - alert: VpsTextfileCollectorError
    expr: node_textfile_scrape_error{job="node-exporter",instance_name="${INSTANCE_NAME}"} == 1
    for: 2m
    labels: {severity: WARNING, category: monitor}
    annotations:
      title: "${INSTANCE_NAME} Textfile Collector 异常"
      description: "node_exporter 无法解析自定义指标文件。"

  - alert: VpsCertificateMissing
    expr: ${METRIC_PREFIX}_cert_present{job="node-exporter",instance_name="${INSTANCE_NAME}"} == 0
    for: 1m
    labels: {severity: ERROR, category: certificate}
    annotations:
      title: "${INSTANCE_NAME} TLS 证书不存在"
      description: "统一 TLS 证书文件不存在。"

  - alert: VpsCertificateKeyMismatch
    expr: ${METRIC_PREFIX}_cert_key_match{job="node-exporter",instance_name="${INSTANCE_NAME}"} == 0
    for: 1m
    labels: {severity: ERROR, category: certificate}
    annotations:
      title: "${INSTANCE_NAME} TLS cert/key 不匹配"
      description: "证书与私钥不匹配。"

  - alert: VpsCertificateExpireWarning
    expr: (${METRIC_PREFIX}_cert_days_remaining{job="node-exporter",instance_name="${INSTANCE_NAME}"} < 15) and (${METRIC_PREFIX}_cert_days_remaining{job="node-exporter",instance_name="${INSTANCE_NAME}"} >= 7)
    for: 5m
    labels: {severity: WARNING, category: certificate}
    annotations:
      title: "${INSTANCE_NAME} TLS 证书即将过期"
      description: "证书剩余 {{ \$value | printf \"%.0f\" }} 天。"

  - alert: VpsCertificateExpireCritical
    expr: ${METRIC_PREFIX}_cert_days_remaining{job="node-exporter",instance_name="${INSTANCE_NAME}"} < 7
    for: 1m
    labels: {severity: ERROR, category: certificate}
    annotations:
      title: "${INSTANCE_NAME} TLS 证书即将过期"
      description: "证书仅剩 {{ \$value | printf \"%.0f\" }} 天。"

  - alert: VpsAcmeTimerDown
    expr: ${METRIC_PREFIX}_acme_timer_active{job="node-exporter",instance_name="${INSTANCE_NAME}"} == 0
    for: 5m
    labels: {severity: ERROR, category: certificate}
    annotations:
      title: "${INSTANCE_NAME} ACME 自动续签任务停止"
      description: "acme-renew.timer 未运行。"

  - alert: Vps3xUIDown
    expr: ${METRIC_PREFIX}_service_up{job="node-exporter",instance_name="${INSTANCE_NAME}",service="3xui"} == 0
    for: 2m
    labels: {severity: ERROR, category: proxy}
    annotations:
      title: "${INSTANCE_NAME} 3x-ui 服务异常"
      description: "3x-ui 容器停止运行。"

  - alert: VpsPanelTlsMismatch
    expr: ${METRIC_PREFIX}_panel_tls_cert_match{job="node-exporter",instance_name="${INSTANCE_NAME}"} == 0
    for: 5m
    labels: {severity: WARNING, category: certificate}
    annotations:
      title: "${INSTANCE_NAME} 3x-ui 正在使用旧证书"
      description: "3x-ui 对外证书与当前安装证书不一致。"

  - alert: VpsRealityPortDown
    expr: ${METRIC_PREFIX}_port_listening{job="node-exporter",instance_name="${INSTANCE_NAME}",service="reality"} == 0
    for: 2m
    labels: {severity: ERROR, category: proxy}
    annotations:
      title: "${INSTANCE_NAME} REALITY 端口异常"
      description: "REALITY 端口 {{ \$labels.port }} 未监听。"
EOF

echo "Generated:"
echo "  ${OUT}/node-exporter-target.json"
echo "  ${OUT}/${SAFE_INSTANCE}-rules.yml"
