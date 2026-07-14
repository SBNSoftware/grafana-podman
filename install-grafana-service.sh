#!/bin/bash

print_usage() {
    echo "Usage: $0 [OPTION]"
    echo "This script sets up Podman, Podman Compose, and Grafana with Podman."
    echo "It installs necessary components, configures storage, and sets up a systemd service for Grafana."
    echo ""
    echo "Options:"
    echo "  -h, /?, --help    Display this help message and exit"
}

if [[ "$1" == "-h" || "$1" == "/?" || "$1" == "--help" ]]; then
    print_usage
    exit 0
fi

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "This script is being sourced. Please run it instead."
    return 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOADENV_BASH="$SCRIPT_DIR/load-environment-vars.sh"
[[ -f "$LOADENV_BASH" ]] && source "$LOADENV_BASH" || { echo "Error: $LOADENV_BASH not found."; exit 1; }

if ! command -v podman &> /dev/null
then
    echo "Podman is not installed. Installing..."
    ksu dnf install -y podman

else
    echo "Podman is already installed."
fi


mkdir -p "$PODMAN_DATA_DIR/containers"
mkdir -p ~/.config/containers
cat <<EOF > ~/.config/containers/storage.conf
[storage]
driver = "overlay"
graphroot = "$PODMAN_DATA_DIR/containers"
EOF

mkdir -p ~/.config/systemd/user
cat <<EOF > ~/.config/systemd/user/grafana.service
# This is a systemd unit file for managing the Grafana Service Stack

[Unit]
Description=Grafana Service Stack
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=%h/grafana-podman/grafana-service-ctrl.sh start
ExecStop=%h/grafana-podman/grafana-service-ctrl.sh stop
ExecReload=%h/grafana-podman/grafana-service-ctrl.sh restart

[Install]
WantedBy=default.target

EOF

#ksu loginctl enable-linger `whoami`
systemctl --user daemon-reload

if ! systemctl --user  is-active --quiet podman.socket
then
    echo "Podman socket is not running. Starting..."
    systemctl --user enable podman.socket
    systemctl --user start podman.socket
else
    echo "Podman socket is already running."
fi

#systemctl --user enable --now grafana.service
