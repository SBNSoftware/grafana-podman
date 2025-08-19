#!/bin/bash
set -euo pipefail

show_help() {
    echo "Usage: $0 {start|stop|restart|health|fresh|status|podman|unused|logs}"
    echo
    echo "This script manages Podman containers and provides various utilities:"
    echo "  start    - Starts the container stack defined in podman-compose.yml"
    echo "  stop     - Stops all running containers in the stack"
    echo "  restart  - Restarts the entire container stack"
    echo "  health   - Checks the health status of all containers"
    echo "  fresh    - Performs a complete cleanup and fresh start of the stack"
    echo "  status   - Displays detailed status of running containers"
    echo "  podman   - Shows Podman-specific status information"
    echo "  unused   - Lists unused Podman resources for potential cleanup"
    echo "  logs     - Displays logs for a selected container"
}

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "Error: This script should be executed, not sourced."
    show_help
    exit 1
fi

if [ $# -eq 0 ]; then
    echo "Error: No arguments provided."
    show_help
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOADENV_BASH="$SCRIPT_DIR/load-environment-vars.sh"

if [ -r "$LOADENV_BASH" ]; then
    source "$LOADENV_BASH"
else
    echo "Error: $LOADENV_BASH not found."
    exit 1
fi

if [ -z "$COMPOSE_FILE" ] || [ ! -r "$COMPOSE_FILE" ]; then
    COMPOSE_FILE="$SCRIPT_DIR/podman-compose.yml"
    if [ ! -r "$COMPOSE_FILE" ]; then
        echo "Error: $COMPOSE_FILE is not readable or does not exist."
        exit 1
    fi
fi

if ! podman-compose -f "$COMPOSE_FILE" ps > /dev/null 2>&1; then
    echo "Error: $COMPOSE_FILE is not a valid Podman Compose file."
    exit 1
fi

podman_status() {
    echo "Podman Version:"
    podman version
    echo "-------------------------"
    echo "Podman Compose Version:"
    podman-compose version
    echo "-------------------------"
    echo "Podman Service Status:"
    systemctl --user is-active --quiet podman.service && systemctl --user status --no-pager podman.service || echo "Podman service is not active"
    echo "-------------------------"
    echo "Podman Socket Status:"
    systemctl --user is-active --quiet podman.socket && systemctl --user status --no-pager podman.socket || echo "Podman socket is not active"
    echo "-------------------------"
    echo "Podman Uptime:"
    systemctl --user show podman.service --property=ActiveEnterTimestamp
    echo "-------------------------"
    echo "Podman Networking Configuration:"
    podman network inspect podman 2>/dev/null || echo "Default podman network not found"
    echo "-------------------------"
    echo "Podman Data Location:"
    podman info --format '{{.Store.GraphRoot}}'
}

show_status() {
    echo "Container Status Summary:"
    echo "-------------------------"
    podman ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}" | \
    awk 'NR==1{print $0" CPU% MEM USAGE / LIMIT"} NR>1{printf "%-87s", $0; system("podman stats --no-stream --format \"{{.CPUPerc}} {{.MemUsage}}\" "$1)}'
    echo "-------------------------"
    echo "Detailed Resource Usage:"
    podman stats --no-stream
    echo "-------------------------"
    echo "Mapped Volumes:"
    podman ps -q | xargs -r -I {} podman inspect -f '{{.Name}}:{{range .Mounts}}{{printf "\n\t%s -> %s" .Source .Destination}}{{end}}' {}
}

show_unused() {
    echo "Unused Podman Resources:"
    echo "------------------------"
    echo "Unused Images:"
    podman images --format "{{.ID}} {{.Repository}}:{{.Tag}}" | grep "<none>" || echo "No unused images found"
    echo "------------------------"
    echo "Stopped Containers:"
    podman ps -a --filter status=exited --format "{{.ID}} {{.Names}}" || echo "No stopped containers found"
    echo "------------------------"
    echo "Unused Volumes:"
    podman volume ls --filter dangling=true --format "{{.Name}}" || echo "No unused volumes found"
    echo "------------------------"
    echo "Unused Networks:"
    podman network ls --filter dangling=true --format "{{.Name}}" || echo "No unused networks found"
    echo "------------------------"
    echo "To prune these resources, use:"
    echo "podman system prune"
    echo "podman volume prune"
    echo "podman network prune"
}

show_log() {
    containers=$(podman ps --format "{{.ID}}")
    count=$(echo "$containers" | sed '/^$/d' | wc -l | xargs)
    if [ "$count" -eq 1 ]; then
        podman logs "$containers"
    elif [ "$count" -gt 1 ]; then
        echo "Running containers:"
        podman ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
        last_container=$(podman ps -l --format "{{.ID}}")
        echo "Enter the container ID to view logs (default: $last_container):"
        read -r container_id
        container_id=${container_id:-$last_container}
        podman logs "$container_id"
    else
        echo "No running containers found."
    fi
}

start_stack() {
    echo "Starting the container stack..."
    if ! podman-compose up -d; then
        echo "Error: Failed to start the container stack."
        echo "Suggestion: Check the podman-compose.yml file for errors or conflicts."
        echo "You can also try 'podman-compose logs' for more details."
        return 1
    fi
    echo "Container stack started successfully."
}

clean_graphite_pid_files() {
  if [[ -z "${GRAPHITE_STORAGE_DIR}" ]]; then
    echo "Error: GRAPHITE_STORAGE_DIR is not set." >&2
    return 1
  fi

  if [[ ! -d "${GRAPHITE_STORAGE_DIR}" ]]; then
    echo "Error: Directory '${GRAPHITE_STORAGE_DIR}' does not exist." >&2
    return 1
  fi

  local pid_file
  for pid_file in "${GRAPHITE_STORAGE_DIR}"/*.pid; do
    if [[ -f "${pid_file}" ]]; then
      if rm -- "${pid_file}"; then
        echo "Deleted: ${pid_file}"
      else
        echo "Error: Failed to delete '${pid_file}'." >&2
        return 1
      fi
    fi
  done
}

stop_stack() {
    echo "Stopping the container stack..."
    if ! podman-compose down; then
        echo "Error: Failed to stop the container stack."
        echo "Suggestion: Try stopping containers individually with 'podman stop <container_id>'."
        echo "If issues persist, consider using 'podman-compose down --timeout 30' to force stop."
        return 1
    fi
    echo "Listing all containers:"
    podman ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"

    echo "Removing all containers..."
    podman rm -f $(podman ps -aq) 2>/dev/null || echo "No containers to remove."

    echo "Listing all volumes:"
    podman volume ls --format "table {{.Name}}\t{{.Driver}}"

    echo "Removing all volumes..."
    podman volume rm $(podman volume ls -q) 2>/dev/null || echo "No volumes to remove."

    clean_graphite_pid_files

    echo "Container stack stopped successfully."
}

restart_stack() {
    echo "Restarting the container stack..."
    if ! podman-compose down; then
        echo "Error: Failed to stop the container stack for restart."
        echo "Suggestion: Try stopping containers manually before restarting."
        return 1
    fi
    if ! podman-compose up -d; then
        echo "Error: Failed to start the container stack after stopping."
        echo "Suggestion: Check for any changes in network or volume configurations."
        echo "Review recent changes to podman-compose.yml file."
        return 1
    fi
    echo "Container stack restarted successfully."
}

check_health() {
    echo "Checking health of containers..."
    if ! podman-compose ps; then
        echo "Error: Failed to retrieve container status."
        echo "Suggestion: Ensure podman daemon is running with 'systemctl status podman'."
        echo "Check if containers are accessible with 'podman ps'."
        return 1
    fi
    echo "Health check completed. Review the output above for container statuses."
}

fresh_init() {
    echo "Using compose file: $COMPOSE_FILE"
    podman-compose down --volumes >/dev/null 2>&1
    podman ps -q | xargs -r podman stop >/dev/null 2>&1
    podman ps -qa | xargs -r podman rm -f >/dev/null 2>&1
    if ! podman system prune -af; then
        echo "Error during system prune"
    elif [ "$(podman system df --format '{{.Total}}')" = "0" ]; then
        echo "Nothing left to prune in system"
    fi
    if ! podman volume prune -f; then
        echo "Error during volume prune"
    elif [ "$(podman volume ls -q | wc -l)" = "0" ]; then
        echo "No volumes left to prune"
    fi
    if ! podman network prune -f; then
        echo "Error during network prune"
    elif [ "$(podman network ls --format '{{.Name}}' | grep -v 'podman' | wc -l)" = "0" ]; then
        echo "No custom networks left to prune"
    fi
    if ! podman image prune -af; then
        echo "Error during image prune"
    elif [ "$(podman image ls -q | wc -l)" = "0" ]; then
        echo "No images left to prune"
    fi
    podman-compose pull
    podman images
}

case "$1" in
    start)
        start_stack
        ;;
    stop)
        stop_stack
        ;;
    restart)
        restart_stack
        ;;
    health)
        check_health
        ;;
    fresh)
        fresh_init
        ;;
    status)
        show_status
        ;;
    podman)
        podman_status
        ;;
    unused)
        show_unused
        ;;
    logs)
        show_log
        ;;
    -h|--help|/?)
        show_help
        ;;
    *)
        echo "Error: Invalid option."
        show_help
        exit 1
        ;;
esac

exit 0
