#!/bin/bash

# Default interface - can be overridden by environment variable
INTERFACE="${HOSTNAME_INTERFACE:-enP8p1s0}"
LOG_TAG="set-hostname-from-mac"

# Function to log messages
log_message() {
    echo "$(date): $1" | systemd-cat -t "$LOG_TAG"
}

# Check if interface exists
if ! ip link show "$INTERFACE" &>/dev/null; then
    log_message "ERROR: Network interface $INTERFACE not found"
    # Try to find the first available ethernet interface
    INTERFACE=$(ip link show | grep -E '^[0-9]+: en' | head -1 | cut -d: -f2 | tr -d ' ')
    if [ -z "$INTERFACE" ]; then
        log_message "ERROR: No ethernet interface found"
        exit 1
    fi
    log_message "INFO: Using alternative interface: $INTERFACE"
fi

# Get MAC address and remove colons
MAC_ADDRESS=$(ip link show "$INTERFACE" | awk '/ether/ {print $2}' | tr -d ':' | tr '[:lower:]' '[:upper:]')

if [ -z "$MAC_ADDRESS" ]; then
    log_message "ERROR: Could not retrieve MAC address for interface $INTERFACE"
    exit 1
fi

# Get current hostname
CURRENT_HOSTNAME=$(hostname)

# Set new hostname if different
if [ "$CURRENT_HOSTNAME" != "$MAC_ADDRESS" ]; then
    log_message "INFO: Changing hostname from $CURRENT_HOSTNAME to $MAC_ADDRESS"
    
    # Set runtime hostname
    if hostnamectl set-hostname "$MAC_ADDRESS"; then
        log_message "INFO: Successfully changed hostname to $MAC_ADDRESS"
    else
        log_message "ERROR: Failed to set hostname"
        exit 1
    fi
else
    log_message "INFO: Hostname already set to MAC address: $MAC_ADDRESS"
fi

exit 0