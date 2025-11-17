#!/bin/bash

YAML="$1"

echo "[INFO] Detected changes in $YAML. Re-applying..."

# Optional: clean old stack
podman kube down "$YAML" --force 2>/dev/null

# Apply new definition
podman kube play "$YAML"

echo "[INFO] Podman play completed."
