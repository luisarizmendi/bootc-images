#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/microshift/config.d"
CONFIG_FILE="${CONFIG_DIR}/99-dyn-values.yaml"
IP_CACHE_FILE="/var/run/microshift-ip-cache"

mkdir -p "${CONFIG_DIR}"

HOSTNAME=$(hostname -f)
IP=$(ip -4 route get 1.1.1.1 | awk '/src/ {print $7; exit}')

if [[ -z "$HOSTNAME" || -z "$IP" ]]; then
    echo "Error: Unable to determine hostname or IP" >&2
    exit 1
fi

# Check if IP has changed
if [[ -f "$IP_CACHE_FILE" ]]; then
    CACHED_IP=$(cat "$IP_CACHE_FILE")
    if [[ "$CACHED_IP" == "$IP" ]]; then
        echo "IP unchanged ($IP), skipping configuration update"
        exit 0
    fi
    echo "IP changed from $CACHED_IP to $IP, updating configuration"
else
    echo "First run, configuring with IP=$IP"
fi

# Write the YAML config
cat > "${CONFIG_FILE}" <<EOF
apiServer:
  subjectAltNames:
    - microshift.lablocal
    - ${HOSTNAME}
dns:
  baseDomain: ${IP}.nip.io
EOF

chmod 644 "${CONFIG_FILE}"
echo "Created ${CONFIG_FILE} with hostname=${HOSTNAME}, IP=${IP}"

# Cache the current IP
echo "$IP" > "$IP_CACHE_FILE"

# Restart microshift service
systemctl restart microshift

# Update kubeconfig
mkdir -p /root/.kube
cp /var/lib/microshift/resources/kubeadmin/kubeconfig /root/.kube/config

echo "Configuration updated successfully"