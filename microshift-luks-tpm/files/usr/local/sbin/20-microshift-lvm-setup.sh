#!/bin/bash
set -euo pipefail

VG_NAME="microshift"

MAPPERS=$(ls /dev/mapper/luks-* 2>/dev/null || true)
[[ -z "$MAPPERS" ]] && { echo "No LUKS mappers found."; exit 0; }

for MAPPER in $MAPPERS; do
  if ! findmnt -n -o SOURCE | grep -q "$MAPPER"; then
    echo "Preparing $MAPPER as LVM PV for $VG_NAME"
    if ! pvdisplay "$MAPPER" >/dev/null 2>&1; then
      wipefs -a "$MAPPER" || true
      pvcreate -ff -y "$MAPPER"
      if ! vgdisplay "$VG_NAME" >/dev/null 2>&1; then
        vgcreate "$VG_NAME" "$MAPPER"
      else
        vgextend "$VG_NAME" "$MAPPER" || true
      fi
      vgchange -ay "$VG_NAME"
    fi
  fi
done


echo "microshift-lvm-setup done."


# Create config file if it does not exist

mkdir -p /etc/microshift

if [[ -f /etc/microshift/lvms.yaml ]]; then
  echo "[microshift-lvms-config] lvms.yaml already exists; skipping."
  exit 0
fi

cat > /etc/microshift/lvms.yaml <<'EOF'
socket-name: /run/lvm/lvmpolld.socket
device-classes:
- name: default
  volume-group: microshift
  spare-gb: 0
  default: true
EOF

echo "[microshift-lvms-config] created /etc/microshift/lvms.yaml"

