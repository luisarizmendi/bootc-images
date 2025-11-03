#!/bin/bash

LOG_TAG="set-hostname-from-mac"

# Function to log messages
log_message() {
    echo "$(date): $1" | systemd-cat -t "$LOG_TAG"
}

# Determine interface
if [ -z "$HOSTNAME_INTERFACE" ]; then
    INTERFACE=$(ip -o link show | awk -F': ' '!/ lo:/ {print $2; exit}')
    if [ -z "$INTERFACE" ]; then
        log_message "ERROR: No valid network interface found"
        exit 1
    fi
    log_message "INFO: Using first available interface: $INTERFACE"
else
    INTERFACE="$HOSTNAME_INTERFACE"
    if ! ip link show "$INTERFACE" &>/dev/null; then
        log_message "ERROR: Specified interface $INTERFACE not found"
        exit 1
    fi
    log_message "INFO: Using specified interface: $INTERFACE"
fi

# Get MAC address and normalize
MAC_ADDRESS=$(ip link show "$INTERFACE" | awk '/ether/ {print $2}' | tr -d ':' | tr '[:lower:]' '[:upper:]')
if [ -z "$MAC_ADDRESS" ]; then
    log_message "ERROR: Could not retrieve MAC address for $INTERFACE"
    exit 1
fi

# Compare and update hostname
CURRENT_HOSTNAME=$(hostname)
if [ "$CURRENT_HOSTNAME" != "$MAC_ADDRESS" ]; then
    log_message "INFO: Changing hostname from $CURRENT_HOSTNAME to $MAC_ADDRESS"
    if hostnamectl set-hostname "$MAC_ADDRESS"; then
        log_message "INFO: Successfully changed hostname to $MAC_ADDRESS"
    else
        log_message "ERROR: Failed to set hostname"
        exit 1
    fi
else
    log_message "INFO: Hostname already set to $MAC_ADDRESS"
fi

exit 0
