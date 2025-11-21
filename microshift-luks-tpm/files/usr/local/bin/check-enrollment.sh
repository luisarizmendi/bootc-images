#!/bin/bash

DATA_DIR="/var/lib/flightctl"
CERT_PATH="$DATA_DIR/certs/agent.crt"
CSR_PATH="$DATA_DIR/certs/agent.csr"

if [ -f "$CERT_PATH" ]; then
    echo "Status: ENROLLED - Device is managed by flightctl"
    exit 0
elif [ -f "$CSR_PATH" ]; then
    echo "Status: PENDING - Enrollment request submitted, waiting for approval"
    exit 2
else
    echo "Status: NOT_ENROLLED - Device has not contacted flightctl service yet"
    exit 1
fi