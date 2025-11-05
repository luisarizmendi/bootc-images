#!/bin/bash
# Hook script called by certmonger after certificate renewal

CERT_FILE="$1"
KEY_FILE="$2"

# Restart NetworkManager to use new certificate
if [ -n "$CERT_FILE" ] && [ -f "$CERT_FILE" ]; then
    echo "Certificate renewed: $CERT_FILE"
    systemctl reload NetworkManager
fi