# Grafana Monitoring Stack with Podman Quadlets

A containerized monitoring stack — Grafana, Graphite, nginx TLS reverse proxy,
and Dozzle — deployed as **rootless Podman Quadlet units under `systemd --user`**.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Components](#components)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Backup and Restore](#backup-and-restore)
- [Scripts](#scripts)
- [Troubleshooting](#troubleshooting)

## Overview

- Rootless Quadlet/systemd-managed container stack (no compose, no root daemon)
- Secure access via nginx TLS reverse proxy (self-signed CA)
- Automatic boot start via user lingering + `WantedBy=default.target`
- Systemd timers: hourly log rotation, weekly config backup, 2-minute watchdog
- Persistent data under `/grafana/` (`CONTAINER_HOME_DIR`), outside the repo

## Prerequisites

- Podman >= 4.4 with the user Quadlet generator
  (`/usr/lib/systemd/user-generators/podman-user-generator`)
- systemd user services (lingering is enabled by the installer)
- subuid/subgid range for the service user
- A valid Kerberos ticket `kinit`

## Quick Start

```bash
# Clone repository and pick the branch for this deployment
git clone <repository-url>
cd grafana-podman
git checkout release/<experiment>     # e.g. release/sbnd

# Grafana admin password (never committed)
echo '<password>' > admin_password.txt

# Provision host + render/install all units (rootless; run as the service user)
kinit
./install-quadlet.sh

# Start the stack
./grafana-quadlet-ctrl.sh start
```

## Architecture

```plaintext
Client -> NGINX (10443, HTTPS) -> Grafana  (10080)
                                -> Graphite (10081)
                                -> Dozzle   (10085)
Metrics -> carbon (2003)
```

## Components

| Service  | Port  | Purpose                  |
|----------|-------|--------------------------|
| Nginx    | 10443 | Reverse proxy (HTTPS)    |
| Grafana  | 10080 | Visualization platform   |
| Graphite | 10081 | Time-series database     |
| carbon   | 2003  | Metrics ingestion        |
| Dozzle   | 10085 | Container log viewer     |

## Installation

`./install-quadlet.sh` does everything; it is idempotent and safe to re-run:

1. Host provisioning (root steps via `ksu`, needs a Kerberos ticket):
   user lingering, cpu/memory cgroup delegation for user slices, creation of
   `CONTAINER_HOME_DIR` (default `/grafana/`).
2. Rootless setup: podman graphroot under `${CONTAINER_HOME_DIR}/podman`,
   user `podman.socket`, data/log/cert directories, `podman unshare chown`
   of the Grafana data dir, podman secret `admin_password` from
   `admin_password.txt`, self-signed CA + server certificate into
   `$SSL_CERTS_DIR` (skipped if already present), Python venv `env/`.
3. Renders the templates in `quadlet/` and `systemd/` through `envsubst`
   (variable whitelist `VARS` inside the installer) into
   `~/.config/containers/systemd/` and `~/.config/systemd/user/`, then
   `systemctl --user daemon-reload` and enables the timers.

**Editing templates in the repo does nothing until `install-quadlet.sh` is
re-run** (followed by a restart of the affected services).

Quadlet-generated container services cannot be `systemctl enable`d; boot start
works via `[Install] WantedBy=default.target` plus user lingering.

## Configuration

Single source of configuration: **`grafana-service.env`** (image versions,
ports, memory limits, `BIND_IP`, directories, `EXPERIMENT_NAME`).

- `EXPERIMENT_NAME` selects `config/<experiment>/` (Graphite/carbon configs)
  and `exported_grafana_data/<experiment>/` (dashboard backups).
- Branch model: `master` is the common base; `release/icarus` /
  `release/sbnd` carry the per-host `grafana-service.env` and merge master.
- `GRAFANA_API_KEY=changeme` is the committed placeholder — real tokens and
  `admin_password.txt` must stay out of git.

Unit templates: `quadlet/*.container`, `quadlet/grafana.network`,
`systemd/*.{service,timer}`. Dependency chain: `nginx.service` Requires
`grafana.service` + `graphite.service`; `dozzle.service` Requires the user
`podman.socket`.

## Usage

```bash
./grafana-quadlet-ctrl.sh {start|stop|restart|status|health|logs|ps}

journalctl --user -u grafana.service     # also graphite/nginx/dozzle
./grafana-login-checks.sh                # port/status health report
```

Timers (installed and enabled by `install-quadlet.sh`):

| Timer | Schedule | Action |
|-------|----------|--------|
| `grafana-log-rotate.timer` | hourly | size-rotate container logs in `$LOGS_DIR` (`rotate-logs.sh`) |
| `grafana-backup.timer` | weekly (Mon 00:00) | `grafana-ninja.py --mode export` |
| `grafana-watchdog.timer` | every 2 min | restart services down/unhealthy > 10 min (`grafana-watchdog.sh`) |

## Backup and Restore

```bash
# Mint/refresh the grafana-ninja service-account token (writes GRAFANA_API_KEY
# into grafana-service.env — working tree only, do not commit)
./create-grafana-token.sh

# Export dashboards, datasources, alert rules, contact points
./env/bin/python grafana-ninja.py --config grafana-service.env --mode export

# Import (restore) — optionally --dry-run / --wipe-existing-data
./env/bin/python grafana-ninja.py --config grafana-service.env --mode import
```

Exports land in `exported_grafana_data/<experiment>/`; commit them to back
them up ("backup dashboards" commits).

## Scripts

| Script | Purpose |
|--------|---------|
| `install-quadlet.sh` | Provision host + render/install all units |
| `grafana-quadlet-ctrl.sh` | Stack control (start/stop/restart/status/health/logs/ps) |
| `grafana-watchdog.sh` | Auto-restart of down/unhealthy services (timer-driven) |
| `rotate-logs.sh` | Log rotation (timer-driven) |
| `grafana-login-checks.sh` | Health/port report |
| `create-grafana-token.sh` | Create service account + API token for backups |
| `generate-server-certificate.sh` | Standalone SSL certificate (re)generation |
| `grafana-ninja.py` | Config export/import (backup/restore) |

## Troubleshooting

```bash
# Overall stack state
./grafana-quadlet-ctrl.sh status
./grafana-quadlet-ctrl.sh health
./grafana-login-checks.sh

# Per-service journal
journalctl --user -u nginx.service -n 200

# After changing templates or grafana-service.env
./install-quadlet.sh && systemctl --user daemon-reload
./grafana-quadlet-ctrl.sh restart
```