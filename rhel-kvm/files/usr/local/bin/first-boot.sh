#!/bin/bash
set -euo pipefail

###############################################################
## HOSTNAME ###################################################
echo "Configuring hostname..."
/usr/local/bin/set-hostname-from-mac.sh


###############################################################
## GET FILES
echo "Getting files..."
until /usr/local/bin/get-files.sh; do
  echo "Script /usr/local/bin/get-files.sh failed, retrying..."
  sleep 5
done

###############################################################
## COCKPIT
if [ -f /tmp/my-cockpit.te ]; then
    checkmodule -M -m -o /tmp/my-cockpit.mod /tmp/my-cockpit.te && \
    semodule_package -o /tmp/my-cockpit.pp -m /tmp/my-cockpit.mod && \
    semodule -i /tmp/my-cockpit.pp && \
    restorecon -Rv /usr && \
    rm -f /tmp/my-cockpit.{te,mod,pp}
fi

###############################################################
## LIBVIRT
echo "Configuring libvirt..."
export LIBVIRT_DEFAULT_URI=qemu:///system

# Check if network exists
if virsh net-info default >/dev/null 2>&1; then
    # Is it persistent?
    if virsh net-info default | grep -q "Persistent: yes"; then
        echo "Undefining persistent network 'default'"
        virsh net-destroy default 2>/dev/null || true
        virsh net-undefine default 2>/dev/null || true
    else
        echo "Destroying transient network 'default'"
        virsh net-destroy default 2>/dev/null || true
        # Cannot undefine transient networks
    fi
fi


echo "Ensuring old default network is fully removed..."
if virsh net-info default >/dev/null 2>&1; then
    echo "Force removing leftover 'default' network..."
    virsh net-destroy default 2>/dev/null || true
    virsh net-undefine default 2>/dev/null || true
fi

# Now define the persistent one cleanly
echo "Defining new persistent default network"
virsh net-define /etc/libvirt/network/default.xml
virsh net-start default
virsh net-autostart default

# storage
mkdir -p /var/lib/libvirt/cloud-init

POOL_NAME="cloud-init"
POOL_PATH="/etc/libvirt/cloud-init/cloudinitisos"

echo "Preparing pool ${POOL_NAME}..."

chmod 755 /var/lib/libvirt/images

# STEP 1: Destroy if running
if virsh pool-info "${POOL_NAME}" >/dev/null 2>&1; then
    echo "Pool '${POOL_NAME}' exists — destroying..."
    virsh pool-destroy "${POOL_NAME}" 2>/dev/null || true
fi

# STEP 2: Undefine if still persistent
if virsh pool-info "${POOL_NAME}" >/dev/null 2>&1; then
    if virsh pool-info "${POOL_NAME}" | grep -q "Persistent: yes"; then
        echo "Undefining persistent pool '${POOL_NAME}'..."
        virsh pool-undefine "${POOL_NAME}" 2>/dev/null || true
    fi
fi

# STEP 2b: FIX — ensure NO leftover definition remains
if virsh pool-info "${POOL_NAME}" >/dev/null 2>&1; then
    echo "Force removing leftover pool '${POOL_NAME}' (race-condition cleanup)..."
    virsh pool-destroy "${POOL_NAME}" 2>/dev/null || true
    virsh pool-undefine "${POOL_NAME}" 2>/dev/null || true
fi

# Allow libvirt to refresh (prevents UUID conflicts)
sleep 1

# STEP 3: recreate directory
mkdir -p "${POOL_PATH}"

# STEP 4: define pool
echo "Defining new pool '${POOL_NAME}'..."
virsh pool-define-as \
  --name "${POOL_NAME}" \
  --type dir \
  --target "${POOL_PATH}"

# STEP 5: start and autostart
virsh pool-start "${POOL_NAME}"
virsh pool-autostart "${POOL_NAME}"

echo "Pool '${POOL_NAME}' ready."

for i in $(ls /etc/libvirt/qemu/vms/*.xml); do
    virsh define "$i"
done

for i in $(virsh list --all --name); do
    systemctl start libvirt-vm@"${i}".service && systemctl enable libvirt-vm@"${i}".service
    virsh autostart "$i"
done

touch /var/lib/firstboot.done
