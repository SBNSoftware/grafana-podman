# Grafana Monitoring Stack with Podman

A containerized monitoring solution using Podman, featuring Grafana, Graphite, and nginx reverse proxy.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Components](#components)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Scripts](#scripts)
- [Troubleshooting](#troubleshooting)

## Overview

- Container-based monitoring stack
- Secure deployment with nginx reverse proxy
- Automated certificate management
- Granular resource control
- Persistent data storage

## Prerequisites

- Podman >= 4.9
- Podman-compose >= 1.2
- Python >= 3.9
- systemd (user services)

## Quick Start

```bash
# Clone repository
git clone <repository-url>
cd grafana-podman

# Setup environment
cp grafana-service.env ~/.grafana-service.env
./create-needed-dirs.sh

# Generate certificates
./generate-server-certificate.sh

# Start services
./grafana-service-ctrl.sh start
```

## Architecture

```plaintext
Client -> NGINX (10443) -> Grafana (10080)
                       -> Graphite (10081)
                       -> Dozzle (10085)
```

## Components

| Service  | Port  | Purpose                    |
|----------|-------|----------------------------|
| Nginx    | 10443 | Reverse Proxy (HTTPS)      |
| Grafana  | 10080 | Visualization Platform     |
| Graphite | 10081 | Time-series Database      |
| Dozzle   | 10085 | Container Log Viewer      |

## Installation

1. Directory Structure:
```bash
mkdir -p /grafana/{data,logs,podman}
mkdir -p /grafana/data/{grafana,graphite,certs}
```

2. Environment Setup:
```bash
cp grafana-service.env ~/.grafana-service.env
source load-environment-vars.sh
```

3. Certificate Generation:
```bash
./generate-server-certificate.sh
```

## Configuration

### Environment Variables

Key configuration files:
- `grafana-service.env`: Main configuration
- `podman-compose.yml`: Container orchestration

Essential variables:
```env
BIND_IP=127.0.0.1
GRAFANA_PORT=10080
NGINX_PORT=10443
GRAPHITE_PORT=10081
```

## Usage

### Service Control

```bash
./grafana-service-ctrl.sh [command]

Commands:
  start    - Start services
  stop     - Stop services
  restart  - Restart services
  health   - Check health status
  fresh    - Clean start
  status   - Show service status
  logs     - View logs
```

### Grafana Management

```bash
python3 grafana-ninja.py --config config.env --mode [export|import]

Options:
  --wipe-existing-data  Clear existing configuration
  --token-instructions  Show API token setup
```

## Scripts

| Script | Purpose |
|--------|---------|
| `grafana-service-ctrl.sh` | Service management |
| `generate-server-certificate.sh` | SSL certificate generation |
| `grafana-ninja.py` | Configuration management |
| `grafana-login-checks.sh` | Health monitoring |

## Troubleshooting

```bash
# Check service status
./grafana-login-checks.sh

# View logs
./grafana-service-ctrl.sh logs
