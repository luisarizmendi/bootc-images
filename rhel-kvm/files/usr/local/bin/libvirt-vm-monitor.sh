#!/bin/bash
# Monitor script for libvirt VM

VM_NAME="$1"

if [ -z "$VM_NAME" ]; then
    echo "Usage: $0 <vm-name>"
    exit 1
fi

# Start the VM if not running
if ! /usr/bin/virsh list --name | grep -q "^${VM_NAME}$"; then
    echo "Starting VM: $VM_NAME"
    /usr/bin/virsh start "$VM_NAME" || exit 1
fi

# Notify systemd we're ready
if command -v systemd-notify &> /dev/null; then
    systemd-notify --ready
fi

# Monitor loop - check every 10 seconds
while true; do
    if ! /usr/bin/virsh list --name | grep -q "^${VM_NAME}$"; then
        echo "VM $VM_NAME is no longer running"
        exit 1
    fi
    sleep 10
done