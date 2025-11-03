#!/bin/bash
set -euo pipefail

KEEP_PASSPHRASE_FILE="/etc/microshift/keep_passphrase"
PASSPHRASE_FILE="/etc/microshift/pasphrase"
PASSPHRASE_DEFAULT="redhat"

if [[ -f "$PASSPHRASE_FILE" ]]; then
  PASSPHRASE=$(cat "$PASSPHRASE_FILE")
elif [[ -n "${MICROSHIFT_PASSPHRASE:-}" ]]; then
  PASSPHRASE="$MICROSHIFT_PASSPHRASE"
else
  PASSPHRASE="$PASSPHRASE_DEFAULT"
fi

echo "[microshift-luks-bind] using passphrase: ${PASSPHRASE:0:4}..."

LUKS_DEVS=$(blkid -t TYPE="crypto_LUKS" -o device | sort -u || true)
[[ -z "$LUKS_DEVS" ]] && { echo "No LUKS devices found."; exit 0; }

SWAP_UUID=$(lsblk -f -n | grep '\[SWAP\]' | grep 'luks-' | awk '{print $2}' | sed -n 's/^luks-//p' || true)

mkdir -p /etc/microshift/state
BIND_LOG="/etc/microshift/state/luks_bound.list"
> "$BIND_LOG"

for dev in $LUKS_DEVS; do
  UUID=$(blkid -s UUID -o value "$dev" || true)
  [[ -z "$UUID" ]] && continue
  [[ "$UUID" == "$SWAP_UUID" ]] && { echo "Skipping swap LUKS device $dev"; continue; }

  if cryptsetup luksDump "$dev" 2>/dev/null | grep -qi 'Clevis'; then
    echo "Already TPM2-bound: $dev"
  else
    echo "Binding $dev to TPM2..."
    if echo -n "$PASSPHRASE" | clevis luks bind -y -k - -d "$dev" tpm2 '{"hash":"sha256","key":"rsa"}'; then
      echo "$dev" >> "$BIND_LOG"
    else
      echo "Warning: TPM2 binding failed for $dev"
    fi
  fi
done

# Clean-up
if [[ ! -f "$KEEP_PASSPHRASE_FILE" ]]; then
  echo "[microshift-cleanup] Removing passphrases from TPM2-bound LUKS devices..."
  for dev in $(blkid -t TYPE="crypto_LUKS" -o device || true); do
    echo -n "$PASSPHRASE" | cryptsetup luksRemoveKey "$dev" || true
  done
else
  echo "[microshift-cleanup] KEEP_PASSPHRASE set; not removing passphrases."
fi

# Add to /etc/crypttab for persistence
for part in $(lsblk -rno NAME,FSTYPE | awk '$2=="crypto_LUKS"{print $1}'); do
  uuid=$(blkid -s UUID -o value /dev/$part || true)
  [[ -n "$uuid" ]] && \
    grep -q "$uuid" /etc/crypttab 2>/dev/null || \
    echo "luks-$uuid UUID=$uuid none discard" >> /etc/crypttab
done


echo "microshift-luks-bind done."
