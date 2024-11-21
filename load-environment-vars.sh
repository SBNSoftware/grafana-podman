#!/bin/bash

SERVICE_NAME='Grafana'

show_usage() {
    echo "Usage: source $0 [OPTION]"
    echo "Set up environment variables for $SERVICE_NAME service."
    echo
    echo "Options:"
    echo "  -h, /?, --help    Display this help message and exit"
    echo
    echo "This script sources the $SERVICE_NAME service environment configuration file."
    echo "It must be sourced, not executed directly."
    return 0
}

if [[ $# -gt 0 && ("$1" == "-h" || "$1" == "/?" || "$1" == "--help") ]]; then
    show_usage
    return 1
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: This script must be sourced. Please use 'source $0' or '. $0'"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

USER_ID=$(id -u)

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

if ! grep -vE '^\s*#' "$SERVICE_ENVIRONMENT_CONFIG" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*\s*='; then
    echo "Error: $SERVICE_ENVIRONMENT_CONFIG is not in the correct env format."
    return 1
fi

if ! env -i bash -c "source $SERVICE_ENVIRONMENT_CONFIG" &> /dev/null; then
    echo "Error: Failed to source $SERVICE_ENVIRONMENT_CONFIG. Please check the file for errors."
    return 1
fi

set -o allexport
source "$SERVICE_ENVIRONMENT_CONFIG"
source "$SERVICE_ENVIRONMENT_CONFIG"
set +o allexport

if [ -n "${BASH_ENVIRONMENT_CHECK}" ]; then
    if [ -x "${BASH_ENVIRONMENT_CHECK}" ]; then
        ${BASH_ENVIRONMENT_CHECK} || return 1
    else
        if [ -x "$SCRIPT_DIR/$(basename "${BASH_ENVIRONMENT_CHECK}")" ]; then
            "$SCRIPT_DIR/$(basename "${BASH_ENVIRONMENT_CHECK}")" || return 1
        else
            echo "Error: BASH_ENVIRONMENT_CHECK script not executable or not found."
            return 1
        fi
    fi
fi

[[ -d $SCRIPT_DIR/env ]] && { export VIRTUAL_ENV=$SCRIPT_DIR/env; export PATH=${VIRTUAL_ENV}/bin:$PATH; }
