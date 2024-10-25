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
    sudo dnf install -y podman

else
    echo "Podman is already installed."
fi

if ! command -v podman-compose &> /dev/null
then
    echo "Podman Compose is not installed. Installing..."
    sudo dnf install -y podman-compose podman-plugins
else
    echo "Podman Compose is already installed."
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
[Unit]
Description=Grafana Podman Compose Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/path/to/your/compose/dir
Environment=PODMAN_USERNS=keep-id
ExecStartPre=/usr/bin/podman-compose down
ExecStart=/usr/bin/podman-compose up
ExecStop=/usr/bin/podman-compose down
Restart=always

[Install]
WantedBy=default.target
EOF

#loginctl enable-linger $(whoami)
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
