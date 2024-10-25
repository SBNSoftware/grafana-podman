#!/bin/bash

SERVICE_NAME='Grafana'


print_help() {
    echo "Usage: $0 [OPTION]"
    echo "Options:"
    echo "  -h, /?, --help    Display this help message and exit"
    echo "This script initializes and verifies directory paths listed in an environment configuration file."
}

if [[ "$#" -eq 1 && ("$1" == "-h" || "$1" == "--help" || "$1" == "/?") ]]; then
    print_help
    exit 0
fi

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "This script is being sourced. Please run it instead."
    return 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

unset SERVICE_ENVIRONMENT_CONFIG

if [ -z "${SERVICE_ENVIRONMENT_CONFIG-}" ]; then
    SERVICE_NAME_LOWER=$(echo "$SERVICE_NAME" | tr '[:upper:]' '[:lower:]')
    SERVICE_ENVIRONMENT_CONFIG="$HOME/.${SERVICE_NAME_LOWER}-service.env"
fi

if [ ! -f "$SERVICE_ENVIRONMENT_CONFIG" ]; then
    SERVICE_ENVIRONMENT_CONFIG="$SCRIPT_DIR/${SERVICE_NAME_LOWER}-service.env"
    if [ ! -f "$SERVICE_ENVIRONMENT_CONFIG" ]; then
        echo "Error: File $SERVICE_ENVIRONMENT_CONFIG not found in home directory or script directory."
        return 1
    fi
fi

for var in $(grep -vE '^\s*#' "$SERVICE_ENVIRONMENT_CONFIG" | grep -oE '^[A-Za-z_][A-Za-z0-9_]*_DIR'); do
    dir_path=$(grep "^$var=" "$SERVICE_ENVIRONMENT_CONFIG" | cut -d '=' -f 2-)

    if [ -d "$dir_path" ]; then
        echo "Directory $dir_path exists. Size: $(du -sh "$dir_path" | cut -f1)"
    else
        echo "Directory $dir_path does not exist. Creating it."
        mkdir -p "$dir_path"
    fi

    chmod 777 "$dir_path"
done
