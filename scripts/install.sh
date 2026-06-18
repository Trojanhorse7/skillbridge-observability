#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${REPO_DIR:-/home/trojan/skillbridge-observability}"
LOG_FILE="/var/log/skillbridge-observability-install.log"

BACKEND_PROD_URL="${BACKEND_PROD_URL:-https://api.skillbridge.hng14.com}"
BACKEND_STAGING_URL="${BACKEND_STAGING_URL:-https://api.staging.skillbridge.hng14.com}"
FRONTEND_PROD_URL="${FRONTEND_PROD_URL:-https://skillbridge.hng14.com}"
FRONTEND_STAGING_URL="${FRONTEND_STAGING_URL:-https://staging.skillbridge.hng14.com}"

API_PORT_PROD="${API_PORT_PROD:-5001}"
API_PORT_STAGING="${API_PORT_STAGING:-4001}"

GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:?ERROR: set GRAFANA_ADMIN_PASSWORD}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:?ERROR: set SLACK_WEBHOOK_URL}"
SERVER_HOST="${SERVER_HOST:-}"

RESEND_API_KEY="${RESEND_API_KEY:?ERROR: set RESEND_API_KEY}"

ALERT_EMAIL_TO="${ALERT_EMAIL_TO:?ERROR: set ALERT_EMAIL_TO}"

PM2_LOGS_DIR="${PM2_LOGS_DIR:-/home/deploy/.pm2/logs}"
PM2_APP_NAME_PROD="${PM2_APP_NAME_PROD:-skillbridge-api-prod}"
PM2_APP_NAME_STAGING="${PM2_APP_NAME_STAGING:-skillbridge-api-staging}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "Starting SkillBridge observability install from $REPO_DIR"

log "Preparing apt..."
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
killall apt apt-get unattended-upgrade 2>/dev/null || true
sleep 3
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
      /var/cache/apt/archives/lock /var/lib/apt/lists/lock
dpkg --configure -a 2>/dev/null || true

log "Installing dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget unzip tar git jq net-tools \
    apt-transport-https software-properties-common

for user in prometheus alertmanager node_exporter blackbox; do
    id "$user" &>/dev/null || useradd --no-create-home --shell /bin/false "$user"
    log "User ready: $user"
done

mkdir -p /var/lib/{prometheus,alertmanager}
mkdir -p /etc/{prometheus/rules,alertmanager/templates,blackbox}
mkdir -p /var/log/observability
mkdir -p /var/lib/grafana/dashboards

chown prometheus:prometheus /var/lib/prometheus /etc/prometheus
chown alertmanager:alertmanager /var/lib/alertmanager /etc/alertmanager

download() {
    local url=$1 dest=$2
    for attempt in 1 2 3; do
        wget -q --timeout=60 --tries=3 -O "$dest" "$url" && return 0
        log "Download attempt $attempt failed for $url, retrying..."
        sleep 5
    done
    log "ERROR: Failed to download $url after 3 attempts"
    exit 1
}

install_binary() {
    local name="$1" path="/usr/local/bin/${1}"
    [ -x "$path" ] && { log "$name already installed, skipping"; return 0; }
    return 1
}

PROMETHEUS_VERSION="2.51.2"
if ! install_binary prometheus; then
    log "Installing Prometheus ${PROMETHEUS_VERSION}..."
    cd /tmp
    download "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/prometheus-${PROMETHEUS_VERSION}.linux-amd64.tar.gz" \
        prometheus.tar.gz
    tar -xzf prometheus.tar.gz
    cp "prometheus-${PROMETHEUS_VERSION}.linux-amd64/prometheus" /usr/local/bin/
    cp "prometheus-${PROMETHEUS_VERSION}.linux-amd64/promtool" /usr/local/bin/
    cp -r "prometheus-${PROMETHEUS_VERSION}.linux-amd64/consoles" /etc/prometheus/
    cp -r "prometheus-${PROMETHEUS_VERSION}.linux-amd64/console_libraries" /etc/prometheus/
    chown prometheus:prometheus /usr/local/bin/prometheus /usr/local/bin/promtool
fi

cp "$REPO_DIR/prometheus/prometheus.yml" /etc/prometheus/prometheus.yml
cp "$REPO_DIR/prometheus/rules/"*.yml    /etc/prometheus/rules/

sed -i "s|__API_PORT_PROD__|${API_PORT_PROD}|g"           /etc/prometheus/prometheus.yml
sed -i "s|__API_PORT_STAGING__|${API_PORT_STAGING}|g"     /etc/prometheus/prometheus.yml
sed -i "s|__BACKEND_PROD_URL__|${BACKEND_PROD_URL}|g"     /etc/prometheus/prometheus.yml
sed -i "s|__BACKEND_STAGING_URL__|${BACKEND_STAGING_URL}|g" /etc/prometheus/prometheus.yml
sed -i "s|__FRONTEND_PROD_URL__|${FRONTEND_PROD_URL}|g"   /etc/prometheus/prometheus.yml
sed -i "s|__FRONTEND_STAGING_URL__|${FRONTEND_STAGING_URL}|g" /etc/prometheus/prometheus.yml

chown -R prometheus:prometheus /etc/prometheus

cat > /etc/systemd/system/prometheus.service << 'UNIT'
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/prometheus \
    --config.file=/etc/prometheus/prometheus.yml \
    --storage.tsdb.path=/var/lib/prometheus \
    --storage.tsdb.retention.time=30d \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries \
    --web.listen-address=0.0.0.0:9090 \
    --web.enable-remote-write-receiver

[Install]
WantedBy=multi-user.target
UNIT
log "Prometheus configured"

NODE_VERSION="1.7.0"
if ! install_binary node_exporter; then
    log "Installing Node Exporter ${NODE_VERSION}..."
    cd /tmp
    download "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/node_exporter-${NODE_VERSION}.linux-amd64.tar.gz" \
        node_exporter.tar.gz
    tar -xzf node_exporter.tar.gz
    cp "node_exporter-${NODE_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
    chown node_exporter:node_exporter /usr/local/bin/node_exporter
fi

cat > /etc/systemd/system/node_exporter.service << 'UNIT'
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/node_exporter --web.listen-address=0.0.0.0:9100

[Install]
WantedBy=multi-user.target
UNIT
log "Node Exporter configured"

BLACKBOX_VERSION="0.24.0"
if ! install_binary blackbox_exporter; then
    log "Installing Blackbox Exporter ${BLACKBOX_VERSION}..."
    cd /tmp
    download "https://github.com/prometheus/blackbox_exporter/releases/download/v${BLACKBOX_VERSION}/blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64.tar.gz" \
        blackbox_exporter.tar.gz
    tar -xzf blackbox_exporter.tar.gz
    cp "blackbox_exporter-${BLACKBOX_VERSION}.linux-amd64/blackbox_exporter" /usr/local/bin/
    chown blackbox:blackbox /usr/local/bin/blackbox_exporter
fi

cat > /etc/blackbox/blackbox.yml << 'CONFIG'
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []
      method: GET
      follow_redirects: true
      preferred_ip_protocol: "ip4"
  http_2xx_ssl:
    prober: http
    timeout: 10s
    http:
      valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
      valid_status_codes: []
      method: GET
      follow_redirects: true
      preferred_ip_protocol: "ip4"
      tls_config:
        insecure_skip_verify: false
CONFIG

cat > /etc/systemd/system/blackbox_exporter.service << 'UNIT'
[Unit]
Description=Blackbox Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=blackbox
Group=blackbox
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/blackbox_exporter \
    --config.file=/etc/blackbox/blackbox.yml \
    --web.listen-address=0.0.0.0:9115

[Install]
WantedBy=multi-user.target
UNIT
log "Blackbox Exporter configured"

ALERTMANAGER_VERSION="0.27.0"
if ! install_binary alertmanager; then
    log "Installing Alertmanager ${ALERTMANAGER_VERSION}..."
    cd /tmp
    download "https://github.com/prometheus/alertmanager/releases/download/v${ALERTMANAGER_VERSION}/alertmanager-${ALERTMANAGER_VERSION}.linux-amd64.tar.gz" \
        alertmanager.tar.gz
    tar -xzf alertmanager.tar.gz
    cp "alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/alertmanager" /usr/local/bin/
    cp "alertmanager-${ALERTMANAGER_VERSION}.linux-amd64/amtool" /usr/local/bin/
    chown alertmanager:alertmanager /usr/local/bin/alertmanager /usr/local/bin/amtool
fi

cp "$REPO_DIR/alertmanager/alertmanager.yml" /etc/alertmanager/
cp "$REPO_DIR/alertmanager/templates/"*.tmpl  /etc/alertmanager/templates/

sed -i "s|slack_api_url: 'replace-this'|slack_api_url: '${SLACK_WEBHOOK_URL}'|" \
    /etc/alertmanager/alertmanager.yml
log "Slack webhook injected"

sed -i "s|REPLACE_AT_INSTALL|${RESEND_API_KEY}|" \
    /etc/alertmanager/alertmanager.yml
log "Resend API key injected"

sed -i "s|team@skillbridge.hng14.com|${ALERT_EMAIL_TO}|g" \
    /etc/alertmanager/alertmanager.yml
log "Alert recipient emails set: ${ALERT_EMAIL_TO}"

chown -R alertmanager:alertmanager /etc/alertmanager /var/lib/alertmanager

cat > /etc/systemd/system/alertmanager.service << 'UNIT'
[Unit]
Description=Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/alertmanager \
    --config.file=/etc/alertmanager/alertmanager.yml \
    --storage.path=/var/lib/alertmanager \
    --web.listen-address=0.0.0.0:9093

[Install]
WantedBy=multi-user.target
UNIT
log "Alertmanager configured"

if ! command -v grafana-server &>/dev/null; then
    log "Installing Grafana..."
    wget -q -O /usr/share/keyrings/grafana.key https://apt.grafana.com/gpg.key
    echo "deb [signed-by=/usr/share/keyrings/grafana.key] https://apt.grafana.com stable main" \
        > /etc/apt/sources.list.d/grafana.list
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y grafana
fi

mkdir -p /etc/grafana/provisioning/{datasources,dashboards}
cp "$REPO_DIR/grafana/provisioning/datasources/"*.yml /etc/grafana/provisioning/datasources/
cp "$REPO_DIR/grafana/provisioning/dashboards/"*.yml  /etc/grafana/provisioning/dashboards/
cp "$REPO_DIR/grafana/dashboards/"*.json              /var/lib/grafana/dashboards/
chown -R grafana:grafana /etc/grafana/provisioning /var/lib/grafana/dashboards

sed -i "s/^;*admin_password = .*/admin_password = ${GRAFANA_ADMIN_PASSWORD}/" /etc/grafana/grafana.ini
sed -i 's/^;*admin_user = .*/admin_user = admin/' /etc/grafana/grafana.ini
sed -i 's/^;*http_port = .*/http_port = 3200/'   /etc/grafana/grafana.ini
grep -q '^http_port' /etc/grafana/grafana.ini || \
    sed -i '/^\[server\]/a http_port = 3200' /etc/grafana/grafana.ini
sed -i "s|^;*domain = .*|domain = ${SERVER_HOST}|"                        /etc/grafana/grafana.ini
grep -q '^domain' /etc/grafana/grafana.ini || \
    sed -i '/^\[server\]/a domain = '"${SERVER_HOST}" /etc/grafana/grafana.ini
sed -i "s|^;*root_url = .*|root_url = https://${SERVER_HOST}/|"           /etc/grafana/grafana.ini
grep -q '^root_url' /etc/grafana/grafana.ini || \
    sed -i '/^\[server\]/a root_url = https://'"${SERVER_HOST}/" /etc/grafana/grafana.ini
sed -i 's|^;*serve_from_sub_path = .*|serve_from_sub_path = false|'       /etc/grafana/grafana.ini
grep -q '^serve_from_sub_path' /etc/grafana/grafana.ini || \
    sed -i '/^\[server\]/a serve_from_sub_path = false' /etc/grafana/grafana.ini
log "Grafana configured"

LOKI_VERSION="2.9.6"
id loki &>/dev/null || useradd --no-create-home --shell /bin/false loki
mkdir -p /var/lib/loki /etc/loki
chown loki:loki /var/lib/loki /etc/loki

if ! install_binary loki; then
    log "Installing Loki ${LOKI_VERSION}..."
    cd /tmp
    download "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip" \
        loki.zip
    unzip -q -o loki.zip
    cp loki-linux-amd64 /usr/local/bin/loki
    chmod +x /usr/local/bin/loki
    chown loki:loki /usr/local/bin/loki
fi

cp "$REPO_DIR/loki/loki-config.yml" /etc/loki/
mkdir -p /etc/loki/rules /var/lib/loki/rules
cp "$REPO_DIR/loki/rules/"*.yml /etc/loki/rules/ 2>/dev/null || true
chown -R loki:loki /etc/loki /var/lib/loki

cat > /etc/systemd/system/loki.service << 'UNIT'
[Unit]
Description=Loki Log Aggregator
Wants=network-online.target
After=network-online.target

[Service]
User=loki
Group=loki
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/loki -config.file=/etc/loki/loki-config.yml

[Install]
WantedBy=multi-user.target
UNIT
log "Loki configured"

PROMTAIL_VERSION="2.9.6"
id promtail &>/dev/null || useradd --no-create-home --shell /bin/false promtail
mkdir -p /etc/promtail

if ! install_binary promtail; then
    log "Installing Promtail ${PROMTAIL_VERSION}..."
    cd /tmp
    download "https://github.com/grafana/loki/releases/download/v${PROMTAIL_VERSION}/promtail-linux-amd64.zip" \
        promtail.zip
    unzip -q -o promtail.zip
    cp promtail-linux-amd64 /usr/local/bin/promtail
    chmod +x /usr/local/bin/promtail
    chown promtail:promtail /usr/local/bin/promtail
fi

cp "$REPO_DIR/promtail/promtail-config.yml" /etc/promtail/config.yml

sed -i "s|__PM2_LOGS_DIR__|${PM2_LOGS_DIR}|g"             /etc/promtail/config.yml
sed -i "s|__PM2_APP_NAME_PROD__|${PM2_APP_NAME_PROD}|g"   /etc/promtail/config.yml
sed -i "s|__PM2_APP_NAME_STAGING__|${PM2_APP_NAME_STAGING}|g" /etc/promtail/config.yml

PM2_USER=$(stat -c '%U' "${PM2_LOGS_DIR}" 2>/dev/null || echo "ubuntu")
usermod -aG "$PM2_USER" promtail 2>/dev/null || true
chmod -R a+r "${PM2_LOGS_DIR}" 2>/dev/null || true

chown -R promtail:promtail /etc/promtail

cat > /etc/systemd/system/promtail.service << 'UNIT'
[Unit]
Description=Promtail Log Shipper
Wants=network-online.target loki.service
After=network-online.target loki.service

[Service]
User=promtail
Group=promtail
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/config.yml

[Install]
WantedBy=multi-user.target
UNIT
log "Promtail configured"

# ── Tempo ─────────────────────────────────────────────────────────────────────
TEMPO_VERSION="2.5.0"
id tempo &>/dev/null || useradd --no-create-home --shell /bin/false tempo
mkdir -p /var/lib/tempo/{blocks,wal,generator/wal} /etc/tempo

if ! install_binary tempo; then
    log "Installing Tempo ${TEMPO_VERSION}..."
    cd /tmp
    download "https://github.com/grafana/tempo/releases/download/v${TEMPO_VERSION}/tempo_${TEMPO_VERSION}_linux_amd64.tar.gz" \
        tempo.tar.gz
    tar -xzf tempo.tar.gz
    cp tempo /usr/local/bin/tempo
    chmod +x /usr/local/bin/tempo
fi

cp "$REPO_DIR/tempo/tempo-config.yml" /etc/tempo/tempo-config.yml
chown -R tempo:tempo /etc/tempo /var/lib/tempo

cat > /etc/systemd/system/tempo.service << 'UNIT'
[Unit]
Description=Tempo Distributed Tracing Backend
Wants=network-online.target
After=network-online.target

[Service]
User=tempo
Group=tempo
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/tempo -config.file=/etc/tempo/tempo-config.yml

[Install]
WantedBy=multi-user.target
UNIT
log "Tempo configured"

# ── OpenTelemetry Collector ────────────────────────────────────────────────────
OTELCOL_VERSION="0.99.0"
id otelcol &>/dev/null || useradd --no-create-home --shell /bin/false otelcol
mkdir -p /etc/otelcol

if ! install_binary otelcol-contrib; then
    log "Installing OTel Collector ${OTELCOL_VERSION}..."
    cd /tmp
    download "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol-contrib_${OTELCOL_VERSION}_linux_amd64.tar.gz" \
        otelcol.tar.gz
    tar -xzf otelcol.tar.gz
    cp otelcol-contrib /usr/local/bin/otelcol-contrib
    chmod +x /usr/local/bin/otelcol-contrib
fi

cp "$REPO_DIR/otelcol/otelcol-config.yml" /etc/otelcol/config.yml
chown -R otelcol:otelcol /etc/otelcol

cat > /etc/systemd/system/otelcol.service << 'UNIT'
[Unit]
Description=OpenTelemetry Collector
Wants=network-online.target tempo.service
After=network-online.target tempo.service

[Service]
User=otelcol
Group=otelcol
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/otelcol-contrib --config=/etc/otelcol/config.yml

[Install]
WantedBy=multi-user.target
UNIT
log "OTel Collector configured"

# ── Prometheus Pushgateway ─────────────────────────────────────────────────────
PUSHGW_VERSION="1.8.0"
id pushgateway &>/dev/null || useradd --no-create-home --shell /bin/false pushgateway
mkdir -p /var/lib/pushgateway

if ! install_binary pushgateway; then
    log "Installing Pushgateway ${PUSHGW_VERSION}..."
    cd /tmp
    download "https://github.com/prometheus/pushgateway/releases/download/v${PUSHGW_VERSION}/pushgateway-${PUSHGW_VERSION}.linux-amd64.tar.gz" \
        pushgateway.tar.gz
    tar -xzf pushgateway.tar.gz
    cp "pushgateway-${PUSHGW_VERSION}.linux-amd64/pushgateway" /usr/local/bin/
    chown pushgateway:pushgateway /usr/local/bin/pushgateway
fi

cat > /etc/systemd/system/pushgateway.service << 'UNIT'
[Unit]
Description=Prometheus Pushgateway
Wants=network-online.target
After=network-online.target

[Service]
User=pushgateway
Group=pushgateway
Type=simple
Restart=always
RestartSec=5s
ExecStart=/usr/local/bin/pushgateway \
    --web.listen-address=0.0.0.0:9091 \
    --persistence.file=/var/lib/pushgateway/metrics.db \
    --persistence.interval=5m

[Install]
WantedBy=multi-user.target
UNIT
log "Pushgateway configured"

log "Starting all services..."
systemctl daemon-reload

SERVICES="prometheus node_exporter blackbox_exporter alertmanager grafana-server loki promtail tempo otelcol pushgateway"

for svc in $SERVICES; do
    systemctl enable "$svc"
    systemctl restart "$svc"
    sleep 2
    if systemctl is-active --quiet "$svc"; then
        log "✓ $svc running"
    else
        log "✗ $svc FAILED"
        journalctl -u "$svc" -n 20 --no-pager | tee -a "$LOG_FILE"
    fi
done

log "Resetting Grafana admin password via grafana-cli..."
systemctl stop grafana-server
sleep 2
GRAFANA_BIN=$(command -v grafana || echo "/usr/bin/grafana")
cd /usr/share/grafana && "${GRAFANA_BIN}" cli admin reset-admin-password "${GRAFANA_ADMIN_PASSWORD}" \
    --config /etc/grafana/grafana.ini 2>&1 | tee -a "$LOG_FILE" || true
systemctl start grafana-server
sleep 3

if [ -n "${SERVER_HOST}" ]; then
    PUBLIC_IP="${SERVER_HOST}"
else
    PUBLIC_IP=$(curl -sf --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
    [ -z "${PUBLIC_IP}" ] && PUBLIC_IP=$(curl -sf --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
    [ -z "${PUBLIC_IP}" ] && PUBLIC_IP=$(hostname -I | awk '{print $1}')
fi

GRAFANA_URL="http://${PUBLIC_IP}:3200"
log "Patching dashboard URLs → ${GRAFANA_URL}"
for f in /etc/prometheus/rules/*.yml /etc/loki/rules/*.yml /etc/alertmanager/alertmanager.yml; do
    sed -i "s|http://localhost:3200|${GRAFANA_URL}|g" "$f"
done
systemctl reload prometheus alertmanager loki 2>/dev/null || true

log "======================================================"
log "SkillBridge Observability — Installation Complete"
log "Grafana:      ${GRAFANA_URL}  (admin/${GRAFANA_ADMIN_PASSWORD})"
log "Prometheus:   http://${PUBLIC_IP}:9090"
log "Alertmanager: http://${PUBLIC_IP}:9093"
log "Loki:         http://${PUBLIC_IP}:3100"
log "Tempo:        http://${PUBLIC_IP}:3300"
log "Pushgateway:  http://${PUBLIC_IP}:9091"
log "======================================================"
