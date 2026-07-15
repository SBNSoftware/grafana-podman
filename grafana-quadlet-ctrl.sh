#!/bin/bash

set -euo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

SERVICES=(graphite.service grafana.service nginx.service dozzle.service)
CONTAINERS=(graphite grafana nginx dozzle)
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"

show_help() {
    cat <<EOF
Usage: $0 {start|stop|restart|status|health|logs|ps}

  start    Start the stack (systemd resolves dependencies)
  stop     Stop the stack (reverse order)
  restart  Restart all services
  status   systemctl --user status for each service
  health   podman health/status for each container
  ps       podman ps for the stack containers
  logs     Tail journald logs for a chosen service (or all)

Boot start is automatic: lingering is enabled for this user and the units carry
[Install] WantedBy=default.target, which the Quadlet generator wires in on
daemon-reload (generated container services can't be 'systemctl enable'd).
EOF
}

require_units() {
    if [[ ! -f "$QUADLET_DIR/graphite.container" ]]; then
        echo "Error: units not installed. Run ./install-quadlet.sh first." >&2
        exit 1
    fi
}

case "${1:-}" in
    start)
        require_units
        echo "Starting stack..."
        systemctl --user start "${SERVICES[@]}"
        systemctl --user --no-pager --output=short is-active "${SERVICES[@]}" || true
        ;;
    stop)
        echo "Stopping stack..."
        # reverse order
        for ((i=${#SERVICES[@]}-1; i>=0; i--)); do
            systemctl --user stop "${SERVICES[$i]}" || true
        done
        ;;
    restart)
        require_units
        echo "Restarting stack..."
        systemctl --user restart "${SERVICES[@]}"
        ;;
    status)
        for s in "${SERVICES[@]}"; do
            echo "===== $s ====="
            systemctl --user status --no-pager "$s" || true
            echo
        done
        ;;
    health)
        echo "Container health:"
        podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" \
            --filter "name=$(IFS='|'; echo "${CONTAINERS[*]}")" 2>/dev/null || \
        podman ps -a --format "table {{.Names}}\t{{.Status}}"
        ;;
    ps)
        podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        ;;
    logs)
        svc="${2:-}"
        if [[ -z "$svc" ]]; then
            echo "Services: ${SERVICES[*]}"
            read -rp "Which service (default: nginx.service)? " svc || true
            svc="${svc:-nginx.service}"
        fi
        [[ "$svc" == *.service ]] || svc="${svc}.service"
        journalctl --user -u "$svc" --no-pager -n 200
        ;;
    -h|--help|"/?"|"")
        show_help
        ;;
    *)
        echo "Error: unknown command '$1'." >&2
        show_help
        exit 1
        ;;
esac
