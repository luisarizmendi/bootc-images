#!/bin/bash
set -e

# Check if already enrolled
if [ -f /etc/ipa/default.conf ]; then
    echo "Already enrolled with IdM"
    exit 0
fi

# Read IdM configuration from environment or config file
IPA_SERVER="${IPA_SERVER:-idm.example.com}"
IPA_DOMAIN="${IPA_DOMAIN:-example.com}"
IPA_REALM="${IPA_REALM:-EXAMPLE.COM}"
ENROLL_PASSWORD="${IPA_ENROLL_PASSWORD}"

# Perform IdM enrollment
if [ -n "$ENROLL_PASSWORD" ]; then
    echo "$ENROLL_PASSWORD" | ipa-client-install \
        --server="$IPA_SERVER" \
        --domain="$IPA_DOMAIN" \
        --realm="$IPA_REALM" \
        --password="$ENROLL_PASSWORD" \
        --unattended \
        --force-join \
        --enable-dns-updates
else
    echo "ERROR: IPA_ENROLL_PASSWORD not set"
    exit 1
fi

# Start certmonger
systemctl enable --now certmonger

# Request 802.1x certificate
ipa-getcert request \
    -K host/$(hostname) \
    -k /etc/pki/tls/private/802.1x-client.key \
    -f /etc/pki/tls/certs/802.1x-client.crt \
    -N "CN=$(hostname)" \
    -D $(hostname) \
    -U id-kp-clientAuth

echo "IdM enrollment and certificate request completed"