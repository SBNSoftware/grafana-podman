#!/bin/bash

check_podman_socket() {
    local service_status=$(systemctl --user --no-pager status podman.socket 2>/dev/null)
    
    if echo "$service_status" | grep -q "Active: active (running)"; then
        local uptime=$(echo "$service_status" | grep -oP '(?<=since )(.*?)(?= ago)')
        echo "podman.socket is active (running) since $uptime"
    else
        echo "podman.socket is not active"
    fi
}

check_grafana_service() {
    local service_status=$(systemctl --user --no-pager status grafana.service 2>/dev/null)
    
    if echo "$service_status" | grep -q "Active: active" && \
       echo "$service_status" | grep -q "Container stack started successfully"; then
        local uptime=$(echo "$service_status" | grep -oP '(?<=since )(.*?)(?= ago)')
        echo "grafana.service is active, Container stack started successfully since $uptime"
    else
        echo "grafana.service is not active or did not start successfully"
    fi
}

display_directory_usage() {
    local directory="$1"
    local size

    if [ -d "$directory" ]; then
        size=$(du -hs "$directory" 2>/dev/null | awk '{print $1}')
        echo "Directory $directory usage: $size"
    else
        echo "Directory $directory not found"
    fi
}

check_port_services() {
    local port="$1"
    local service_name="$2"
    local output=$(netstat -lpnt4 2>/dev/null | grep ":$port ")

    if [ -n "$output" ]; then
        echo "$service_name is running on port $port:"
        echo "$output"
    else
        echo "$service_name is not running on port $port"
    fi
}

display_podman_containers() {
    echo "Podman containers summary (Name | Status):"
    podman ps --format "table {{.Names}}\t{{.Status}}" | awk 'NR==1 || NR>1 {print}'
}

echo "Checking service statuses..."
check_podman_socket
check_grafana_service
echo

echo "Checking directory usage..."
display_directory_usage "/grafana/podman/"
display_directory_usage "/grafana/data"
display_directory_usage "/grafana/logs"
echo

echo "Checking services on specified ports..."
check_port_services 10443 "Nginx"
check_port_services 10080 "Grafana"
check_port_services 10081 "Graphite"
check_port_services 10085 "Dozzle"
check_port_services 2004 "Graphite Pickle"
echo

display_podman_containers

