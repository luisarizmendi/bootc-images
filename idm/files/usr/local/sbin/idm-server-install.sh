#!/bin/bash
set -e

# Check if already installed
if [ -f /etc/ipa/default.conf ]; then
    echo "IdM server already installed"
    exit 0
fi

# Use environment variables from systemd (set in credentials.conf)
IPA_REALM="${IPA_REALM:-BOOTCEXAMPLE.COM}"
IPA_DOMAIN="${IPA_DOMAIN:-bootcexample.com}"
IPA_DS_PASSWORD="${IPA_DS_PASSWORD}"
IPA_ADMIN_PASSWORD="${IPA_ADMIN_PASSWORD}"
IPA_HOSTNAME="${IPA_HOSTNAME:-$(hostname -f)}"
IPA_IP="${IPA_IP:-$(hostname -I | awk '{print $1}')}"

# DNS configuration
DNS_FORWARDER="${DNS_FORWARDER:-8.8.8.8}"
SETUP_DNS="${SETUP_DNS:-yes}"

# Validate required variables
if [ -z "$IPA_DS_PASSWORD" ] || [ -z "$IPA_ADMIN_PASSWORD" ]; then
    echo "ERROR: IPA_DS_PASSWORD and IPA_ADMIN_PASSWORD must be set"
    exit 1
fi

# Ensure hostname is properly set
if [ -n "$IPA_HOSTNAME" ]; then
    hostnamectl set-hostname "$IPA_HOSTNAME"
fi

# Add hostname to /etc/hosts if not present
if ! grep -q "$IPA_HOSTNAME" /etc/hosts; then
    echo "$IPA_IP $IPA_HOSTNAME $(hostname -s)" >> /etc/hosts
fi

echo "==========================================="
echo "Installing IdM Server"
echo "==========================================="
echo "Realm: $IPA_REALM"
echo "Domain: $IPA_DOMAIN"
echo "Hostname: $IPA_HOSTNAME"
echo "IP: $IPA_IP"
echo "DNS Setup: $SETUP_DNS"
echo "==========================================="

# Install IdM server with DNS and self-signed certificates
if [ "$SETUP_DNS" = "yes" ]; then
    ipa-server-install \
        --realm="$IPA_REALM" \
        --domain="$IPA_DOMAIN" \
        --ds-password="$IPA_DS_PASSWORD" \
        --admin-password="$IPA_ADMIN_PASSWORD" \
        --hostname="$IPA_HOSTNAME" \
        --ip-address="$IPA_IP" \
        --setup-dns \
        --forwarder="$DNS_FORWARDER" \
        --auto-reverse \
        --no-ntp \
        --unattended \
        --no-host-dns \
        --no-dnssec-validation
else
    ipa-server-install \
        --realm="$IPA_REALM" \
        --domain="$IPA_DOMAIN" \
        --ds-password="$IPA_DS_PASSWORD" \
        --admin-password="$IPA_ADMIN_PASSWORD" \
        --hostname="$IPA_HOSTNAME" \
        --ip-address="$IPA_IP" \
        --no-ntp \
        --unattended
fi

# Configure firewall for IdM services
echo "Configuring firewall..."
firewall-cmd --permanent --add-service=freeipa-ldap
firewall-cmd --permanent --add-service=freeipa-ldaps
firewall-cmd --permanent --add-service=freeipa-replication
firewall-cmd --permanent --add-service=dns
firewall-cmd --permanent --add-service=ntp
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload

echo "IdM server installation completed successfully"

# Trigger 802.1x profile creation
if [ -x /usr/local/sbin/create-802.1x-profile.sh ]; then
    /usr/local/sbin/create-802.1x-profile.sh
fi


if systemctl list-unit-files | grep -q '^ipa\.service'; then
    echo "Enabling and starting ipa.service..."
    systemctl enable ipa.service
    systemctl start ipa.service
else
    echo "ipa.service not found — skipping enable/start."
fi

exit 0