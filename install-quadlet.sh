#!/bin/bash
#
# install-quadlet.sh — provision the host and install the Grafana stack as ROOTLESS

set -euo pipefail

print_usage() {
    echo "Usage: $0 [OPTION]"
    echo "Provision the host and install the Grafana stack as rootless Podman Quadlet units"
    echo "under this user's systemd (systemd --user)."
    echo
    echo "Options:"
    echo "  --remove-rootful  Tear down a previous rootful install (sudo), migrate /grafana"
    echo "                    ownership to this user, then install the rootless stack"
    echo "  -h, --help        Show this help and exit"
    echo
    echo "Environment overrides:"
    echo "  BIND_IP=<ip>  Deployment IP to publish ports on (default: from grafana-service.env)"
}

REMOVE_ROOTFUL=0
case "${1:-}" in
    -h|--help|"/?") print_usage; exit 0 ;;
    --remove-rootful) REMOVE_ROOTFUL=1 ;;
    "") ;;
    *) echo "Error: unknown option '$1'." >&2; print_usage; exit 1 ;;
esac

if [[ "$(id -u)" -eq 0 ]]; then
    echo "Error: this is a ROOTLESS deployment — run as the service user, not root." >&2
    exit 1
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
QUADLET_SRC="$SCRIPT_DIR/quadlet"
QUADLET_DEST="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
SYSTEMD_SRC="$SCRIPT_DIR/systemd"
SYSTEMD_DEST="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
ENV_FILE="$SCRIPT_DIR/grafana-service.env"

[[ -f "$ENV_FILE" ]] || { echo "Error: $ENV_FILE not found." >&2; exit 1; }
[[ -d "$QUADLET_SRC" ]] || { echo "Error: $QUADLET_SRC not found." >&2; exit 1; }
[[ -d "$SYSTEMD_SRC" ]] || { echo "Error: $SYSTEMD_SRC not found." >&2; exit 1; }

if ! command -v podman &>/dev/null; then
    echo "Error: podman is not installed. Run: sudo dnf install -y podman" >&2
    exit 1
fi
if [[ ! -e /usr/lib/systemd/user-generators/podman-user-generator ]]; then
    echo "Error: the user Quadlet systemd generator is missing (need podman >= 4.4)." >&2
    exit 1
fi
if ! grep -q "^$(id -un):" /etc/subuid || ! grep -q "^$(id -un):" /etc/subgid; then
    echo "Error: no subuid/subgid range for $(id -un). Fix with:" >&2
    echo "  sudo usermod --add-subuids 362144-427679 --add-subgids 362144-427679 $(id -un)" >&2
    exit 1
fi
echo "podman $(podman --version | awk '{print $3}') with user Quadlet generator present."

VENV="$SCRIPT_DIR/env"
if ! "$VENV/bin/python" -c "import requests, dotenv, urllib3" 2>/dev/null; then
    echo "Setting up Python venv for grafana-ninja backups..."
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    "$VENV/bin/pip" install --quiet requests python-dotenv urllib3
fi

_BIND_IP_OVERRIDE="${BIND_IP:-}"
export USER_ID="$(id -u)"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"; source "$ENV_FILE"
set +a

[[ -n "$_BIND_IP_OVERRIDE" ]] && BIND_IP="$_BIND_IP_OVERRIDE"
export BIND_IP
: "${BIND_IP:?BIND_IP is not set (define it in grafana-service.env or export it)}"
: "${PODMAN_SOCK:?PODMAN_SOCK is not set in grafana-service.env}"

export REPO_DIR="$SCRIPT_DIR"

if [[ "$BIND_IP" != "0.0.0.0" ]] && ! ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "$BIND_IP"; then
    echo "WARNING: BIND_IP=$BIND_IP is not assigned to this host."
    echo "         Containers publishing to it will fail with 'cannot assign requested address'."
    echo "         Re-run as:  BIND_IP=<this-host-ip> $0"
fi

ROOTFUL_SERVICES=(nginx.service dozzle.service grafana.service graphite.service grafana-network.service)
if [[ "$REMOVE_ROOTFUL" -eq 1 ]]; then
    echo "Removing the rootful stack (sudo)..."
    sudo systemctl disable --now grafana-backup.timer grafana-log-rotate.timer 2>/dev/null || true
    for s in "${ROOTFUL_SERVICES[@]}"; do sudo systemctl stop "$s" 2>/dev/null || true; done
    sudo rm -f /etc/containers/systemd/{grafana.network,graphite.container,grafana.container,nginx.container,dozzle.container}
    sudo rm -f /etc/systemd/system/{grafana-backup,grafana-log-rotate}.{service,timer}
    sudo systemctl daemon-reload
    sudo systemctl reset-failed "${ROOTFUL_SERVICES[@]}" 2>/dev/null || true
    sudo podman secret rm admin_password 2>/dev/null || true
    sudo podman network rm grafana 2>/dev/null || true
    sudo podman rmi \
        "docker.io/graphiteapp/graphite-statsd:${GRAPHITE_VERSION}" \
        "docker.io/grafana/grafana:${GRAFANA_VERSION}" \
        "docker.io/library/nginx:${NGINX_VERSION}" \
        "docker.io/amir20/dozzle:${DOZZLE_VERSION}" 2>/dev/null || true

    sudo systemctl disable --now podman.socket 2>/dev/null || true
    echo "Handing $CONTAINER_HOME_DIR to $(id -un) (container uids are remapped below)..."
    sudo chown -R "$(id -un):$(id -gn)" "$CONTAINER_HOME_DIR"
    echo "Rootful stack removed."
elif [[ -f /etc/containers/systemd/graphite.container ]]; then
    echo "Error: a rootful install is still present in /etc/containers/systemd/." >&2
    echo "Migrate it first:  $0 --remove-rootful" >&2
    exit 1
fi

if [[ "$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null)" != "yes" ]]; then
    echo "Enabling lingering for $(id -un) (user services run without a login session)..."
    sudo loginctl enable-linger "$(id -un)"
fi

for _ in $(seq 1 30); do
    [[ -S "$XDG_RUNTIME_DIR/bus" ]] && break
    sleep 1
done
[[ -S "$XDG_RUNTIME_DIR/bus" ]] || { echo "Error: user manager did not start ($XDG_RUNTIME_DIR/bus missing)." >&2; exit 1; }


CGROUP_CONTROLLERS="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
if ! grep -qw memory "$CGROUP_CONTROLLERS" 2>/dev/null; then
    echo "Delegating cpu/memory cgroup controllers to user managers (sudo)..."
    sudo install -d -m 0755 /etc/systemd/system/user@.service.d
    printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | \
        sudo tee /etc/systemd/system/user@.service.d/delegate.conf >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl restart "user@$(id -u).service"
    sleep 2
    grep -qw memory "$CGROUP_CONTROLLERS" || {
        echo "Error: memory controller still not delegated; container memory limits would fail." >&2
        exit 1
    }
fi

if ! systemctl --user is-active --quiet podman.socket; then
    echo "Enabling user podman.socket..."
    systemctl --user enable --now podman.socket
fi

echo "Creating $CONTAINER_HOME_DIR data/log/cert tree..."
if [[ ! -d "$CONTAINER_HOME_DIR" ]]; then
    sudo install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" "$CONTAINER_HOME_DIR"
elif [[ "$(stat -c '%U' "$CONTAINER_HOME_DIR")" != "$(id -un)" ]]; then
    echo "Error: $CONTAINER_HOME_DIR is not owned by $(id -un)." >&2
    echo "Migrating from a rootful install? Run:  $0 --remove-rootful" >&2
    exit 1
fi

mkdir -p \
    "$GRAPHITE_STORAGE_DIR" \
    "$GRAFANA_DATA_DIR" \
    "$SSL_CERTS_DIR" \
    "$LOGS_DIR" \
    "${BACKUP_DIR:-/grafana/backups}"

podman unshare chown -R 472:472 "$GRAFANA_DATA_DIR"
chmod 0777 "$LOGS_DIR"

if podman secret exists admin_password 2>/dev/null; then
    echo "podman secret 'admin_password' already exists."
else
    if [[ -f "$SCRIPT_DIR/admin_password.txt" ]]; then
        echo "Creating podman secret 'admin_password'..."
        podman secret create admin_password "$SCRIPT_DIR/admin_password.txt"
    else
        echo "WARNING: admin_password.txt not found; skipping secret creation (grafana.service will fail without it)."
    fi
fi

if [[ -f "$SSL_CERTS_DIR/server.crt" && -f "$SSL_CERTS_DIR/server.key" ]]; then
    echo "TLS server certificate already present in $SSL_CERTS_DIR."
else
    echo "Generating self-signed CA + server certificate into $SSL_CERTS_DIR..."
    SANS="${SSL_DNS_NAMES:-127.0.0.1} $BIND_IP $(hostname)"
    alt=""; i=0
    for n in $SANS; do
        i=$((i+1))
        if [[ "$n" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            alt+=$'\n'"IP.$i = $n"
        else
            alt+=$'\n'"DNS.$i = $n"
        fi
    done
    (
        set -e
        cd "$SSL_CERTS_DIR"
        openssl genrsa -out ca.key 4096
        openssl req -x509 -new -nodes -key ca.key -sha256 -days 1024 -out ca.crt -subj '/CN=Grafana CA'
        openssl genrsa -out server.key 2048
        cat > server.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $(hostname)
[v3]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
[alt]$alt
EOF
        openssl req -new -key server.key -out server.csr -config server.cnf
        openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
            -out server.crt -days 365 -sha256 -extfile server.cnf -extensions v3
        rm -f server.csr server.cnf
        chmod 0644 ca.crt server.crt
        chmod 0640 ca.key server.key
    )
    echo "Certificates generated."
fi


VARS='${BIND_IP} ${GRAPHITE_VERSION} ${GRAPHITE_PORT} ${CARBON_PORT}'
VARS+=' ${GRAPHITE_STORAGE_DIR} ${GRAPHITE_CONFIG_DIR} ${GRAPHITE_MEMORY_LIMIT}'
VARS+=' ${GRAFANA_VERSION} ${GRAFANA_PORT} ${GRAFANA_DATA_DIR} ${GRAFANA_MEMORY_LIMIT}'
VARS+=' ${NGINX_VERSION} ${NGINX_PORT} ${NGINX_CONF_DIR} ${NGINX_CERTS_DIR} ${NGINX_MEMORY_LIMIT}'
VARS+=' ${DOZZLE_VERSION} ${DOZZLE_PORT} ${DOZZLE_MEMORY_LIMIT} ${PODMAN_SOCK}'
VARS+=' ${LOGS_DIR} ${LOG_MAX_SIZE} ${REPO_DIR}'

echo "Rendering container units into $QUADLET_DEST ..."
install -d -m 0755 "$QUADLET_DEST"
for f in grafana.network graphite.container grafana.container nginx.container dozzle.container; do
    [[ -f "$QUADLET_SRC/$f" ]] || { echo "Error: missing template $QUADLET_SRC/$f" >&2; exit 1; }
    envsubst "$VARS" < "$QUADLET_SRC/$f" > "$QUADLET_DEST/$f"
    echo "  installed $f"
done

echo "Rendering timer units into $SYSTEMD_DEST ..."
TIMERS=(grafana-log-rotate.timer grafana-backup.timer)
for f in grafana-log-rotate.service grafana-log-rotate.timer grafana-backup.service grafana-backup.timer; do
    [[ -f "$SYSTEMD_SRC/$f" ]] || { echo "Error: missing template $SYSTEMD_SRC/$f" >&2; exit 1; }
    envsubst "$VARS" < "$SYSTEMD_SRC/$f" > "$SYSTEMD_DEST/$f"
    echo "  installed $f"
done

echo "Reloading user systemd (runs the Quadlet generator)..."
systemctl --user daemon-reload

echo "Enabling timers..."
systemctl --user enable --now "${TIMERS[@]}"

cat <<EOF

Done.
  Container units -> $QUADLET_DEST (generated into user systemd services)
  Timer units     -> $SYSTEMD_DEST (log rotation hourly, config backup daily)

Start the stack with:
    ./grafana-quadlet-ctrl.sh start
or:
    systemctl --user start nginx.service   # pulls in graphite + grafana via dependencies

Boot start is automatic (lingering is enabled; units carry WantedBy=default.target).
EOF
