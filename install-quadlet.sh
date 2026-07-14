#!/bin/bash

set -euo pipefail

print_usage() {
    echo "Usage: $0 [OPTION]"
    echo "Provision the host and install the Grafana stack as rootless Podman Quadlet units"
    echo "under this user's systemd (systemd --user)."
    echo
    echo "Options:"
    echo "  -h, --help        Show this help and exit"
    echo
    echo "Environment overrides:"
    echo "  BIND_IP=<ip>  Deployment IP to publish ports on (default: from grafana-service.env)"
    echo
    echo "First-time host provisioning (lingering, cgroup delegation, data dir) needs root;"
    echo "that is done via ksu, so run with a valid Kerberos ticket (kinit)."
}

case "${1:-}" in
    -h|--help|"/?") print_usage; exit 0 ;;
    "") ;;
    *) echo "Error: unknown option '$1'." >&2; print_usage; exit 1 ;;
esac

if [[ "$(id -u)" -eq 0 ]]; then
    echo "Error: this is a ROOTLESS deployment — run as the service user, not root." >&2
    exit 1
fi

run_root() {
    if ! klist -s 2>/dev/null; then
        echo "Error: this step needs root via ksu but there is no valid Kerberos ticket." >&2
        echo "       Run kinit, then re-run. Command wanted: $*" >&2
        exit 1
    fi
    script -qec "ksu -q -e $*" /dev/null
}

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
    echo "Error: podman is not installed. Run: ksu -e /usr/bin/dnf install -y podman" >&2
    exit 1
fi
if [[ ! -e /usr/lib/systemd/user-generators/podman-user-generator ]]; then
    echo "Error: the user Quadlet systemd generator is missing (need podman >= 4.4)." >&2
    exit 1
fi

if ! grep -qE "^($(id -un)|$(id -u)):" /etc/subuid || ! grep -qE "^($(id -un)|$(id -u)):" /etc/subgid; then
    echo "Error: no subuid/subgid range for $(id -un). Fix with:" >&2
    echo "  ksu -e /usr/sbin/usermod --add-subuids 362144-427679 --add-subgids 362144-427679 $(id -un)" >&2
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

if [[ "$(loginctl show-user "$(id -un)" --property=Linger --value 2>/dev/null)" != "yes" ]]; then
    echo "Enabling lingering for $(id -un) (user services run without a login session)..."
    run_root /usr/bin/loginctl enable-linger "$(id -un)"
fi

for _ in $(seq 1 30); do
    [[ -S "$XDG_RUNTIME_DIR/bus" ]] && break
    sleep 1
done
[[ -S "$XDG_RUNTIME_DIR/bus" ]] || { echo "Error: user manager did not start ($XDG_RUNTIME_DIR/bus missing)." >&2; exit 1; }


CGROUP_CONTROLLERS="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
if ! grep -qw memory "$CGROUP_CONTROLLERS" 2>/dev/null; then
    echo "Delegating cpu/memory cgroup controllers to user managers (root via ksu)..."
    echo "NOTE: this restarts user@$(id -u).service — all user services stop briefly."
    DELEGATE_TMP="$(mktemp)"
    printf '[Service]\nDelegate=cpu cpuset io memory pids\n' > "$DELEGATE_TMP"
    run_root /usr/bin/install -d -m 0755 /etc/systemd/system/user@.service.d
    run_root /usr/bin/install -m 0644 "$DELEGATE_TMP" /etc/systemd/system/user@.service.d/delegate.conf
    rm -f "$DELEGATE_TMP"
    run_root /usr/bin/systemctl daemon-reload
    run_root /usr/bin/systemctl restart "user@$(id -u).service"
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

STORAGE_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/containers/storage.conf"
WANT_GRAPHROOT="${CONTAINER_HOME_DIR%/}/podman/containers"
CUR_GRAPHROOT="$(sed -n 's/^ *graphroot *= *"\(.*\)"/\1/p' "$STORAGE_CONF" 2>/dev/null || true)"
if [[ "$CUR_GRAPHROOT" != "$WANT_GRAPHROOT" ]]; then
    if [[ -n "$CUR_GRAPHROOT" && -d "$CUR_GRAPHROOT/overlay-containers" ]]; then
        echo "WARNING: $STORAGE_CONF graphroot=$CUR_GRAPHROOT already holds containers;"
        echo "         not repointing it to $WANT_GRAPHROOT automatically."
    else
        echo "Pointing podman graphroot to $WANT_GRAPHROOT (was: ${CUR_GRAPHROOT:-unset})..."
        install -d -m 0755 "$(dirname "$STORAGE_CONF")"
        printf '[storage]\ndriver = "overlay"\ngraphroot = "%s"\n' "$WANT_GRAPHROOT" > "$STORAGE_CONF"
    fi
fi

LEGACY_UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/grafana.service"
if [[ -f "$LEGACY_UNIT" ]] && grep -q "grafana-service-ctrl.sh" "$LEGACY_UNIT"; then
    echo "Removing legacy pre-Quadlet user unit grafana.service..."
    systemctl --user disable --now grafana.service 2>/dev/null || true
    rm -f "$LEGACY_UNIT"
    systemctl --user daemon-reload
fi

echo "Creating $CONTAINER_HOME_DIR data/log/cert tree..."
if [[ ! -d "$CONTAINER_HOME_DIR" ]]; then
    run_root /usr/bin/install -d -m 0755 -o "$(id -un)" -g "$(id -gn)" "$CONTAINER_HOME_DIR"
elif [[ "$(stat -c '%U' "$CONTAINER_HOME_DIR")" != "$(id -un)" ]]; then
    echo "Error: $CONTAINER_HOME_DIR is not owned by $(id -un)." >&2
    echo "Fix with:  ksu -e /usr/bin/chown -R $(id -un):$(id -gn) $CONTAINER_HOME_DIR" >&2
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
TIMERS=(grafana-log-rotate.timer grafana-backup.timer grafana-watchdog.timer)
for f in grafana-log-rotate.service grafana-log-rotate.timer grafana-backup.service grafana-backup.timer grafana-watchdog.service grafana-watchdog.timer; do
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
  Timer units     -> $SYSTEMD_DEST (log rotation hourly, config backup weekly, watchdog every 2 min)

Start the stack with:
    ./grafana-quadlet-ctrl.sh start
or:
    systemctl --user start nginx.service   # pulls in graphite + grafana via dependencies

Boot start is automatic (lingering is enabled; units carry WantedBy=default.target).
EOF
