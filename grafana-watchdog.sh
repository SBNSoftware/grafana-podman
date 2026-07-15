#!/bin/bash
set -uo pipefail

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

SERVICES=(graphite grafana nginx dozzle)
DOWN_THRESHOLD_SECS="${WATCHDOG_DOWN_THRESHOLD_SECS:-600}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$XDG_RUNTIME_DIR/grafana-watchdog}"

mkdir -p "$STATE_DIR"

is_healthy() {
    local name="$1" health
    systemctl --user is-active --quiet "$name.service" || return 1
    health=$(podman inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null) || return 1
    [[ -z "$health" || "$health" == "healthy" || "$health" == "starting" ]]
}

now=$(date +%s)
for svc in "${SERVICES[@]}"; do
    state_file="$STATE_DIR/$svc.down_since"

    if is_healthy "$svc"; then
        if [[ -f "$state_file" ]]; then
            echo "$svc recovered on its own; clearing down marker."
            rm -f "$state_file"
        fi
        continue
    fi

    if [[ ! -f "$state_file" ]]; then
        echo "$now" > "$state_file"
        echo "$svc is down/unhealthy; will restart if still down after ${DOWN_THRESHOLD_SECS}s."
        continue
    fi

    down_since=$(<"$state_file")
    age=$(( now - down_since ))
    if (( age >= DOWN_THRESHOLD_SECS )); then
        echo "$svc down/unhealthy for ${age}s (threshold ${DOWN_THRESHOLD_SECS}s) — restarting $svc.service"
        if systemctl --user restart "$svc.service"; then
            echo "$svc.service restarted."
            rm -f "$state_file"
        else
            echo "restart of $svc.service FAILED; will retry next run." >&2
        fi
    else
        echo "$svc still down/unhealthy (${age}s of ${DOWN_THRESHOLD_SECS}s before restart)."
    fi
done
