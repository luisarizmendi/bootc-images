#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/microshift/config.d"
CONFIG_FILE="${CONFIG_DIR}/99-dyn-values.yaml"

mkdir -p "${CONFIG_DIR}"

HOSTNAME=$(hostname -f)

IP=$(ip -4 route get 1.1.1.1 | awk '/src/ {print $7; exit}')

if [[ -z "$HOSTNAME" || -z "$IP" ]]; then
    echo "Error: Unable to determine hostname or IP" >&2
    exit 1
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

systemctl restart microshift

mkdir -p /root/.kube
cp /var/lib/microshift/resources/kubeadmin/kubeconfig /root/.kube/config