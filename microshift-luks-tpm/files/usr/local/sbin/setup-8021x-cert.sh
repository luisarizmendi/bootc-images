#!/usr/bin/bash
set -euo pipefail

CERT_DIR="/etc/pki/tls/certs"
KEY_DIR="/etc/pki/tls/private"
BOOTSTRAP_DIR="/etc/pki/tls/bootstrap"
CERT_FILE="$CERT_DIR/8021x.pem"
KEY_FILE="$KEY_DIR/8021x.key"
CA_CERT="/etc/pki/ca-trust/source/anchors/ca.crt"
CA_ALIAS="ipa"

echo "Ensuring certmonger is running..."
systemctl enable --now certmonger

# If no permanent cert yet, request it
if ! getcert list | grep -q "$CERT_FILE"; then
    echo "Requesting permanent 802.1X certificate..."
    getcert request \
        -c "$CA_ALIAS" \
        -f "$CERT_FILE" \
        -k "$KEY_FILE" \
        -N "CN=$(hostname -f)" \
        -C "systemctl reload NetworkManager"
fi

# Wait until cert is ready
timeout=180
while [ $timeout -gt 0 ]; do
    if getcert list | grep -A3 "$CERT_FILE" | grep -q "status: MONITORING"; then
        echo "Permanent certificate obtained!"
        break
    fi
    sleep 5
    timeout=$((timeout - 5))
done

# Replace bootstrap cert references in NetworkManager config
NM_FILE="/etc/NetworkManager/system-connections/8021x.nmconnection"
if grep -q "/etc/pki/tls/bootstrap" "$NM_FILE"; then
    echo "Switching NetworkManager to permanent certificate..."
    sed -i "s|/etc/pki/tls/bootstrap/8021x-bootstrap.pem|$CERT_FILE|" "$NM_FILE"
    sed -i "s|/etc/pki/tls/bootstrap/8021x-bootstrap.key|$KEY_FILE|" "$NM_FILE"
fi

# Reload NM to apply new cert
systemctl reload NetworkManager

touch /var/lib/setup-8021x-cert.done
