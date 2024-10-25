#!/bin/bash

print_usage() {
    echo "Usage: $0 [OPTION]"
    echo "This script manages Podman containers using podman-compose."
    echo "It checks for running Podman systemd services, pulls the latest images,"
    echo "stops existing containers, and starts new ones."
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

echo "Checking if podman systemd services are running..."
if ! systemctl --user is-active --quiet podman.socket; then
    echo "Podman systemd services are not running. Starting them..."
    systemctl --user enable --now podman.socket
    if [ $? -ne 0 ]; then
        echo "Failed to start podman systemd services. Exiting."
        exit 1
    fi
fi

echo "Pulling latest images..."
podman-compose pull
if [ $? -ne 0 ]; then
    echo "Failed to pull images. Exiting."
    exit 1
fi

echo "Stopping and removing existing containers..."
podman-compose down
if [ $? -ne 0 ]; then
    echo "Failed to stop existing containers. Continuing..."
fi

echo "Starting containers..."
podman-compose up -d
if [ $? -ne 0 ]; then
    echo "Failed to start containers. Exiting."
    exit 1
fi

echo "Containers started successfully."
