#!/bin/bash

print_help() {
    echo "Usage: $0 [OPTION]"
    echo "Generate SSL certificates for Grafana service."
    echo ""
    echo "Options:"
    echo "  -h, /?, --help    Display this help message and exit"
    echo ""
    echo "This script generates a Certificate Authority (CA) and server certificates"
    echo "for use with Grafana. It uses settings from grafana-service.env file and"
    echo "creates certificates in the directory specified by SSL_CERTS_DIR."
    echo ""
    echo "To avoid browser security warnings, add the $SSL_CERTS_DIR/ca.crt certificate"
    echo "to the browser's certificate trust store."
}

if [[ $# -gt 0 && ("$1" == "-h" || "$1" == "/?" || "$1" == "--help") ]]; then
    print_help
    exit 0
fi

if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "This script is being sourced. Please run it instead."
    return 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
LOADENV_BASH="$SCRIPT_DIR/load-environment-vars.sh"

if [ -f "$LOADENV_BASH" ]; then
    source "$LOADENV_BASH"
else
    echo "Error: $LOADENV_BASH not found."
    exit 1
fi

if [ -z "${SSL_CERTS_DIR:-}" ]; then
    echo "Error: SSL_CERTS_DIR is not set."
    exit 1
fi

if [ ! -d "$SSL_CERTS_DIR" ]; then
    echo "Error: SSL_CERTS_DIR does not exist or is not a directory."
    exit 1
fi

CA_KEY="$SSL_CERTS_DIR/ca.key"
CA_CERT="$SSL_CERTS_DIR/ca.crt"
SERVER_KEY="$SSL_CERTS_DIR/server.key"
SERVER_CSR="$SSL_CERTS_DIR/server.csr"
SERVER_CERT="$SSL_CERTS_DIR/server.crt"

if [ -z "${CA_KEY_PASS:-}" ] || [ ${#CA_KEY_PASS} -lt 32 ]; then
    echo "Error: CA_KEY_PASS is not set or shorter than 32 characters."
    read -p "Do you want to use the initially given CA key pass or regenerate a new one? (use/regenerate): " choice
    if [ "$choice" = "use" ]; then
        read -s -p "Enter the initial CA key pass: " CA_KEY_PASS
        echo
    else
        CA_KEY_PASS=$(openssl rand -base64 32)
        echo "New CA key pass generated: $CA_KEY_PASS"
    fi
fi

if [ ! -f "$CA_KEY" ] || [ ! -f "$CA_CERT" ]; then
    echo "Generating Certificate Authority..."
    openssl genrsa -aes256 -passout pass:"$CA_KEY_PASS" -out "$CA_KEY" 4096
    openssl req -x509 -new -nodes -key "$CA_KEY" -passin pass:"$CA_KEY_PASS" -sha256 -days 1024 -out "$CA_CERT" -subj "/CN=Grafana CA"
    echo "Certificate Authority created."
    echo "CA key pass: $CA_KEY_PASS"
else
    echo "Certificate Authority already exists."
fi

if ! openssl rsa -in "$CA_KEY" -passin pass:"$CA_KEY_PASS" -check -noout > /dev/null 2>&1; then
    echo "Error: CA key is invalid or passphrase is incorrect."
    exit 1
fi

if [ "$(ls -A "$SSL_CERTS_DIR")" ]; then
    echo; echo
    echo "Warning: SSL_CERTS_DIR is not empty. Existing server certificates will be overwritten."
    if [ -f "$SERVER_CERT" ]; then
        expiration_date=$(openssl x509 -enddate -noout -in "$SERVER_CERT" | sed -e 's/notAfter=//')
        echo "Current server certificate expires on: $expiration_date";echo
    fi
fi

if [ -z "${SSL_DNS_NAMES:-}" ]; then
    echo "Error: SSL_DNS_NAMES is not set."
    exit 1
fi

IFS=' ' read -ra DNS_ARRAY <<< "$SSL_DNS_NAMES"
for dns in "${DNS_ARRAY[@]}"; do
    if ! [[ "$dns" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && ! [[ "$dns" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Error: Invalid DNS name or IP address in SSL_DNS_NAMES: $dns"
        exit 1
    fi
done

echo "Generating server key and certificate signing request..."
openssl genrsa -out "$SERVER_KEY" 2048

cat > "$SSL_CERTS_DIR/server.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $(hostname)
[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
EOF

IFS=' ' read -ra DNS_ARRAY <<< "$SSL_DNS_NAMES"
for i in "${!DNS_ARRAY[@]}"; do
    echo "DNS.$((i+1)) = ${DNS_ARRAY[$i]}" >> "$SSL_CERTS_DIR/server.cnf"
done

openssl req -new -key "$SERVER_KEY" -out "$SERVER_CSR" -config "$SSL_CERTS_DIR/server.cnf"

echo "Signing server certificate with CA..."
openssl x509 -req -in "$SERVER_CSR" -CA "$CA_CERT" -CAkey "$CA_KEY" -passin pass:"$CA_KEY_PASS" -CAcreateserial -out "$SERVER_CERT" -days 365 -sha256 -extfile "$SSL_CERTS_DIR/server.cnf" -extensions v3_req

# Clean up temporary configuration file
rm "$SSL_CERTS_DIR/server.cnf"

echo "New SSL certificates have been generated and signed by the CA."

if openssl x509 -noout -modulus -in "$SERVER_CERT" | openssl md5 | cut -d' ' -f2 > cert_md5 &&
   openssl rsa -noout -modulus -in "$SERVER_KEY" | openssl md5 | cut -d' ' -f2 > key_md5 &&
   cmp -s cert_md5 key_md5; then
    echo "Server key matches the certificate."
else
    echo "Error: Server key does not match the certificate."
    exit 1
fi
rm cert_md5 key_md5

if ! openssl x509 -in "$SERVER_CERT" -noout -pubkey |
   openssl rsa -pubin -outform pem -in /dev/stdin -noout > /dev/null 2>&1; then
    echo "Error: Generated certificate has an invalid key."
    exit 1
fi

echo; echo;echo
echo "Please restart your Podman services to apply the changes."

if [ -f "$SERVER_CERT" ]; then
    echo "Server Certificate Details:"
    echo "Validity:"
    openssl x509 -in "$SERVER_CERT" -noout -dates
    echo "Common Name (CN):"
    openssl x509 -in "$SERVER_CERT" -noout -subject | sed -n '/CN/s/.*CN = //p'
    echo "Subject Alternative Names (SANs):"
    openssl x509 -in "$SERVER_CERT" -noout -ext subjectAltName | sed -n '/DNS:/s/.*://p'
fi
