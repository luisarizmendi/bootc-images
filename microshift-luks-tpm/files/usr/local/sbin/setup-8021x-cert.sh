#!/usr/bin/bash
set -euo pipefail

CERT_DIR="/etc/pki/tls/certs"
KEY_DIR="/etc/pki/tls/private"
CERT_FILE="$CERT_DIR/8021x.pem"
KEY_FILE="$KEY_DIR/8021x.key"
CA_CERT="/etc/pki/ca-trust/source/anchors/ca.crt"
CA_ALIAS="ipa"   # Change if you use SCEP or a custom CA

# Wait until network is up (for contacting CA)
echo "Waiting for network..."
until ping -c1 -W1 ipa-ca.example.com &>/dev/null; do
    sleep 3
done

echo "Starting certmonger..."
systemctl enable --now certmonger

# Request certificate if it doesn't exist yet
if ! getcert list | grep -q "$CERT_FILE"; then
    echo "Requesting 802.1X certificate from $CA_ALIAS..."
    getcert request \
        -c "$CA_ALIAS" \
        -f "$CERT_FILE" \
        -k "$KEY_FILE" \
        -N "CN=$(hostname -f)" \
        -C "systemctl reload NetworkManager"

    echo "Certificate request submitted. Waiting for issuance..."
    # Wait for certmonger to obtain the certificate
    timeout=180
    while [ $timeout -gt 0 ]; do
        if getcert list | grep -A3 "$CERT_FILE" | grep -q "status: MONITORING"; then
            echo "Certificate obtained successfully!"
            break
        fi
        sleep 5
        timeout=$((timeout - 5))
    done
fi

# Reload NetworkManager to pick up the cert
echo "Reloading NetworkManager to apply new certificate..."
systemctl reload NetworkManager

# Mark setup complete
touch /var/lib/setup-8021x-cert.done
