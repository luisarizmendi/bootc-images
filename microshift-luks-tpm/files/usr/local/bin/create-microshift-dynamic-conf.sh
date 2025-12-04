#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/microshift/config.d"
CONFIG_FILE="${CONFIG_DIR}/99-dyn-values.yaml"
IP_CACHE_FILE="/var/run/microshift-ip-cache"

mkdir -p "${CONFIG_DIR}"

#############################################
# Wait for network to be ready
#############################################
echo "Waiting for network..."

for i in {1..30}; do
    if ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
        echo "Network is ready"
        break
    fi
    echo "Network not ready yet, retrying... ($i)"
    sleep 2
done

if ! ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
    echo "Error: Network not ready after retries" >&2
    exit 1
fi

#############################################
# Get hostname and IP
#############################################
HOSTNAME=$(hostname -f)
IP=$(ip -4 route get 1.1.1.1 | awk '/src/ {print $7; exit}')

if [[ -z "$HOSTNAME" || -z "$IP" ]]; then
    echo "Error: Unable to determine hostname or IP" >&2
    exit 1
fi

#############################################
# Check if IP has changed
#############################################
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

#############################################
# Write MicroShift config file
#############################################
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

#############################################
# Cache IP
#############################################
echo "$IP" > "$IP_CACHE_FILE"

#############################################
# Update kubeconfig
#############################################
mkdir -p /root/.kube

while [ ! -f "/var/lib/microshift/resources/kubeadmin/kubeconfig" ]; do
    sleep 1
done

echo "Creating root kubeconfig"
ln -sfn /var/lib/microshift/resources/kubeadmin/kubeconfig /root/.kube/config


#############################################
# Restart MicroShift
#############################################
systemctl restart microshift

echo "Configuration updated successfully"



