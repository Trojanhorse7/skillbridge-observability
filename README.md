# SkillBridge Observability

Systemd-based observability stack for the SkillBridge platform. Covers metrics, logs, uptime probing, and alerting across production and staging environments.

## Stack

| Component | Purpose | Port |
|---|---|---|
| Prometheus | Metrics collection & alert evaluation | 9090 |
| Node Exporter | Server CPU / memory / disk metrics | 9100 |
| Blackbox Exporter | HTTP uptime + SSL probing | 9115 |
| Alertmanager | Alert routing to Slack + email | 9093 |
| Grafana | Dashboards & visualisation | 3200 |
| Loki | Log aggregation | 3100 |
| Promtail | Log shipping from PM2 files | 9080 |

## What is monitored

- **Server health** — CPU, memory, disk (Node Exporter)
- **API metrics** — request rate, error rate, latency per environment (prom-client `/metrics`)
- **Uptime probes** — backend-prod, backend-staging, frontend-prod, frontend-staging (Blackbox)
- **Application logs** — PM2 stdout/stderr files for all environments (Promtail → Loki)

## Dashboards

| Dashboard | Description |
|---|---|
| Node Exporter | Server infrastructure health |
| SkillBridge — Unified Observability | Golden signals, logs, environment filter |
| SkillBridge — SLO & Error Budget | SLI gauges, error budget, burn rate |

All dashboards have an **Environment** dropdown (`All / production / staging`).

## Setup

### 1. Prerequisites

- Ubuntu server with `sudo` access
- PM2 running the API apps (`skillbridge-api-prod`, `skillbridge-api-staging`)
- Nginx installed (for reverse-proxying Grafana)

### 2. Clone the repo

```bash
git clone <repo-url> /home/trojan/skillbridge-observability
cd /home/trojan/skillbridge-observability
```

### 3. Configure environment

```bash
cp .env.example .env
nano .env   # fill in all values — no defaults for secrets
```

Required values:

| Variable | Description |
|---|---|
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin login password |
| `SLACK_WEBHOOK_URL` | Incoming webhook URL for `#alerts` channel |
| `RESEND_API_KEY` | Resend API key for email alerts |
| `ALERT_EMAIL_TO` | Email address to receive alerts |
| `SERVER_HOST` | Public hostname for Grafana (e.g. `skillbridge-grafana.duckdns.org`) |
| `PM2_LOGS_DIR` | Path to PM2 logs directory (e.g. `/home/deploy/.pm2/logs`) |

### 4. Run the installer

```bash
sudo bash -c "set -a; source .env; set +a; bash scripts/install.sh"
```

The script installs and enables all components as systemd services that survive reboots.

### 5. Verify

```bash
bash scripts/verify.sh
```

## Alerting

Alerts route through Alertmanager to:

- **Slack** — `#alerts` channel (all severities)
- **Email** — via Resend SMTP (critical alerts only)

Alert categories:
- Infrastructure — high CPU, low memory, disk space, instance down
- SLO burn rate — fast burn (14.4×) and slow burn (5×) error budget consumption
- Availability — uptime below 99.5% SLO
- SSL — certificate expiry within 14 days

## Backend metrics

The NestJS API exposes `/metrics` via `prom-client`. Add the `MetricsModule` to `app.module.ts` and ensure `/metrics` is excluded from the global API prefix in `main.ts`.

Key metrics collected:
- `http_requests_total` — request count by method, route, status
- `http_request_duration_seconds` — latency histogram
- `skillbridge_nodejs_*` — Node.js process metrics (heap, GC, event loop)
