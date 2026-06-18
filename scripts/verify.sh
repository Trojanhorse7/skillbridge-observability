#!/usr/bin/env bash
set -euo pipefail

API_PORT_PROD="${API_PORT_PROD:-5001}"
API_PORT_STAGING="${API_PORT_STAGING:-4001}"
BACKEND_PROD_URL="${BACKEND_PROD_URL:-http://localhost:${API_PORT_PROD}}"
BACKEND_STAGING_URL="${BACKEND_STAGING_URL:-http://localhost:${API_PORT_STAGING}}"
FRONTEND_PROD_URL="${FRONTEND_PROD_URL:-}"
FRONTEND_STAGING_URL="${FRONTEND_STAGING_URL:-}"

echo "=============================================="
echo "  SkillBridge Observability — Verify"
echo "=============================================="

PASS=0; FAIL=0

check_service() {
    local name="$1"
    if systemctl is-active --quiet "$name" 2>/dev/null; then
        echo "  ✓ $name is active"
        PASS=$((PASS+1))
    else
        echo "  ✗ $name is NOT active"
        FAIL=$((FAIL+1))
    fi
}

check_http() {
    local label="$1" url="$2"
    if curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
        echo "  ✓ $label  →  $url"
        PASS=$((PASS+1))
    else
        echo "  ✗ $label  →  $url  (not responding)"
        FAIL=$((FAIL+1))
    fi
}

echo ""
echo "── Systemd services ──────────────────────────"
check_service "prometheus"
check_service "node_exporter"
check_service "blackbox_exporter"
check_service "alertmanager"
check_service "grafana-server"
check_service "loki"
check_service "promtail"
check_service "tempo"
check_service "otelcol"
check_service "pushgateway"

echo ""
echo "── HTTP endpoints ────────────────────────────"
check_http "Prometheus health"   "http://localhost:9090/-/healthy"
check_http "Alertmanager health" "http://localhost:9093/-/healthy"
check_http "Node Exporter"       "http://localhost:9100/metrics"
check_http "Blackbox Exporter"   "http://localhost:9115/metrics"
check_http "Grafana health"      "http://localhost:3200/api/health"
check_http "Loki ready"          "http://localhost:3100/ready"
check_http "Promtail ready"      "http://localhost:9080/ready"
check_http "Tempo ready"         "http://localhost:3300/ready"
check_http "Pushgateway health"  "http://localhost:9091/-/healthy"

echo ""
echo "── SkillBridge app probes ────────────────────"
check_http "API health     [prod]"    "${BACKEND_PROD_URL}/health"
check_http "API probe      [prod]"    "${BACKEND_PROD_URL}/probe"
check_http "API metrics    [prod]"    "${BACKEND_PROD_URL}/metrics"
check_http "API health     [staging]" "${BACKEND_STAGING_URL}/health"
[ -n "${FRONTEND_PROD_URL}" ]    && check_http "Frontend       [prod]"    "${FRONTEND_PROD_URL}/api/health"
[ -n "${FRONTEND_STAGING_URL}" ] && check_http "Frontend       [staging]" "${FRONTEND_STAGING_URL}/api/health"

echo ""

PUBLIC_IP=$(curl -sf --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null \
    || curl -sf --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' \
    || hostname -I | awk '{print $1}')

echo "────────────────────────────────────────────"
echo "Passed: $PASS  Failed: $FAIL"
echo ""
echo "Grafana:      http://${PUBLIC_IP}:3200"
echo "Prometheus:   http://${PUBLIC_IP}:9090"
echo "Alertmanager: http://${PUBLIC_IP}:9093"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "Some checks failed — run: journalctl -u <service> -n 50"
    exit 1
fi
