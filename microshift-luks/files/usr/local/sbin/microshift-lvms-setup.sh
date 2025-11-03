#!/bin/bash
set -euo pipefail


# First-boot script to bind LUKS devices to TPM2, create microshift VG and write /etc/microshift/lvms.yaml

PASSPHRASE_FILE="/etc/microshift/pasphrase"
PASSPHRASE_DEFAULT="redhat"
KEEP_PASSPHRASE_FILE="/etc/microshift/keep_passphrase"


# Determine passphrase (fall back to the original installer passphrase)
if [[ -f "$PASSPHRASE_FILE" ]]; then
PASSPHRASE=$(cat "$PASSPHRASE_FILE")
elif [[ -n "${MICROSHIFT_PASSPHRASE:-}" ]]; then
PASSPHRASE="$MICROSHIFT_PASSPHRASE"
else
PASSPHRASE="$PASSPHRASE_DEFAULT"
fi


echo "[microshift-lvms-setup] using passphrase: ${PASSPHRASE:0:4}..."


# Find swap UUID (if present in /proc/swaps or lsblk)
SWAP_UUID=""
if grep -q '\[SWAP\]' <(lsblk -f -n 2>/dev/null); then
SWAP_UUID=$(lsblk -f -n | grep '\[SWAP\]' | grep 'luks-' || true)
SWAP_UUID=$(echo "$SWAP_UUID" | awk '{print $2}' | sed -n 's/^luks-//p' || true)
fi


LVMS_PART=""


# Iterate LUKS devices and bind with clevis if not already bound
LUKS_DEVS=$(blkid -t TYPE="crypto_LUKS" -o device | sort -u || true)


if [[ -z "$LUKS_DEVS" ]]; then
echo "No LUKS devices found. Nothing to do."
exit 0
fi


for dev in $LUKS_DEVS; do
echo "Processing device: $dev"
UUID=$(blkid -s UUID -o value "$dev" || true)
[[ -z "$UUID" ]] && continue
MAPPER="/dev/mapper/luks-$UUID"


# Skip swap LUKS device (if we detected swap mapper UUID)
if [[ -n "$SWAP_UUID" && "$UUID" == "$SWAP_UUID" ]]; then
echo "Skipping swap LUKS device: $dev"
continue
fi


# If device already has a clevis binding, skip
if cryptsetup luksDump "$dev" 2>/dev/null | grep -qi 'Clevis'; then
echo "Device $dev already has a Clevis binding."
else
echo "Binding $dev to TPM2 via clevis..."
if echo -n "$PASSPHRASE" | clevis luks bind -y -k - -d "$dev" tpm2 '{"hash":"sha256","key":"rsa"}' 2>/dev/null; then
echo "Clevis bind succeeded for $dev"
else
echo "Clevis bind failed for $dev (continuing)"
fi
fi


# If this device is intended for LVMS (heuristic: large pv or not mounted), try to create PV/VG
if [[ -e "$MAPPER" && ! $(findmnt -n -o SOURCE | grep -q "$MAPPER"; echo $?) -eq 0 ]]; then
echo "Found unmapped mapper $MAPPER — preparing as PV for microshift if needed"


# avoid clobbering if it already contains LVM metadata
if pvdisplay "$MAPPER" >/dev/null 2>&1; then
echo "$MAPPER already a PV"
else
echo "Wiping signatures on $MAPPER (if any)"
wipefs -a "$MAPPER" || true
echo "Creating PV and VG microshift on $MAPPER"
pvcreate -ff -y "$MAPPER" || true
if ! vgdisplay microshift >/dev/null 2>&1; then
vgcreate microshift "$MAPPER" || true
fi
vgchange -ay microshift || true
fi


# Write lvms config
mkdir -p /etc/microshift || true
cat > /etc/microshift/lvms.yaml <<'EOF'
socket-name: /run/lvm/lvmpolld.socket
device-classes:
- name: default
volume-group: microshift
spare-gb: 0
default: true
EOF


fi


# Optionally remove passphrase from device (if binding succeeded and user doesn't want to keep it)
if [[ ! -f "$KEEP_PASSPHRASE_FILE" ]]; then
echo "Attempting to remove passphrase from $dev"
echo -n "$PASSPHRASE" | cryptsetup luksRemoveKey "$dev" || true
else
echo "KEEP_PASSPHRASE set; not removing key from $dev"
fi


done


# Ensure /etc/crypttab has entries for all LUKS devices
for part in $(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print $1}'); do
uuid=$(blkid -s UUID -o value /dev/$part || true)
if [[ -n "$uuid" ]]; then
name="luks-$uuid"
if ! grep -q "$uuid" /etc/crypttab 2>/dev/null; then
echo "$name UUID=$uuid none discard" >> /etc/crypttab || true
echo "Added $name to /etc/crypttab"
fi
fi
done


# Done
echo "microshift-lvms-setup finished"


# Disable this service if systemd is available (so it doesn't re-run forever)
if command -v systemctl >/dev/null 2>&1; then
systemctl disable --now microshift-lvms-setup.service || true
fi


exit 0