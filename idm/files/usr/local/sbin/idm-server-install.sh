#!/bin/bash
set -e

# Use environment variables from systemd (set in credentials.conf)
IPA_REALM="${IPA_REALM:-BOOTCEXAMPLE.COM}"
IPA_DOMAIN="${IPA_DOMAIN:-bootcexample.com}"
IPA_DS_PASSWORD="${IPA_DS_PASSWORD}"
IPA_ADMIN_PASSWORD="${IPA_ADMIN_PASSWORD}"
ENROLL_USERNAME="${ENROLL_USERNAME}"
ENROLL_PASSWORD="${ENROLL_PASSWORD}"
IPA_HOSTNAME="${IPA_HOSTNAME:-$(hostname -f)}"
IPA_IP="${IPA_IP:-$(hostname -I | awk '{print $1}')}"
DNS_FORWARDER="${DNS_FORWARDER:-8.8.8.8}"
SETUP_DNS="${SETUP_DNS:-yes}"

# Validate required variables
if [ -z "$IPA_DS_PASSWORD" ] || [ -z "$IPA_ADMIN_PASSWORD" ]; then
    echo "ERROR: IPA_DS_PASSWORD and IPA_ADMIN_PASSWORD must be set"
    exit 1
fi

# Pre-flight checks
echo "Running pre-flight checks..."

# Check memory
total_mem=$(free -m | awk '/^Mem:/{print $2}')
if [ "$total_mem" -lt 2000 ]; then
    echo "WARNING: Less than 2GB RAM available. IdM may fail to install."
fi

# Ensure cleanup of previous failed attempts
if [ -d "/var/lib/dirsrv/slapd-BOOTC-EXAMPLE-COM" ]; then
    echo "Cleaning up previous installation attempt..."
    ipa-server-install --uninstall -U || true
    sleep 5
fi

# Set proper SELinux contexts for IPA directories
semanage fcontext -a -t cert_t "/var/lib/ipa(/.*)?"
semanage fcontext -a -t cert_t "/var/lib/ipa/ra-agent.key"
restorecon -Rv /var/lib/ipa

# Ensure hostname is properly set
if [ -n "$IPA_HOSTNAME" ]; then
    hostnamectl set-hostname "$IPA_HOSTNAME"
fi

# Add hostname to /etc/hosts if not present
if ! grep -q "$IPA_HOSTNAME" /etc/hosts; then
    echo "$IPA_IP $IPA_HOSTNAME $(hostname -s)" >> /etc/hosts
fi


# Fix certmonger problems
systemctl restart certmonger
sleep 10


echo "==========================================="
echo "Installing IdM Server"
echo "==========================================="
echo "Realm: $IPA_REALM"
echo "Domain: $IPA_DOMAIN"
echo "Hostname: $IPA_HOSTNAME"
echo "IP: $IPA_IP"
echo "DNS Setup: $SETUP_DNS"
echo "==========================================="

# Install IdM server (unattended)
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

echo "Waiting for Dogtag CA to be ready..."
until curl -sk https://$IPA_HOSTNAME:8443/ca/admin/ca/getStatus | grep -q "running"; do
    echo "  CA not ready yet, retrying in 5s..."
    sleep 5
done
echo "CA subsystem is running."

# --- Fix CA certificate if missing ---
if [ ! -f /etc/ipa/ca.crt ]; then
    echo "Recreating /etc/ipa/ca.crt..."
    if [ -f /etc/pki/pki-tomcat/alias/pwdfile.txt ]; then
        pk12util -o /root/cacert.p12 \
            -n "caSigningCert cert-pki-ca" \
            -d /etc/pki/pki-tomcat/alias \
            -k /etc/pki/pki-tomcat/alias/pwdfile.txt \
            -W "" || echo "WARNING: pk12util failed."
        openssl pkcs12 -in /root/cacert.p12 \
            -clcerts -nokeys \
            -out /etc/ipa/ca.crt \
            -passin pass:
        chmod 644 /etc/ipa/ca.crt
        chown root:root /etc/ipa/ca.crt
        echo "/etc/ipa/ca.crt recreated successfully."
    else
        echo "WARNING: /etc/pki/pki-tomcat/alias/pwdfile.txt missing — cannot rebuild ca.crt automatically."
    fi
else
    echo "/etc/ipa/ca.crt already present."
fi

# --- Firewall setup ---
echo "Configuring firewall..."
systemctl restart firewalld
firewall-cmd --permanent --add-service=freeipa-ldap || true
firewall-cmd --permanent --add-service=freeipa-ldaps || true
firewall-cmd --permanent --add-service=freeipa-replication || true
firewall-cmd --permanent --add-service=dns || true
firewall-cmd --permanent --add-service=ntp || true
firewall-cmd --permanent --add-service=http || true
firewall-cmd --permanent --add-service=https || true
firewall-cmd --permanent --add-port=88/tcp || true
firewall-cmd --permanent --add-port=88/udp || true
firewall-cmd --permanent --add-port=464/tcp || true
firewall-cmd --permanent --add-port=464/udp || true
firewall-cmd --reload || true

# --- Restart and check IPA service ---
echo "Restarting IPA services..."
if systemctl list-unit-files | grep -q '^ipa\.service'; then
    systemctl enable ipa.service
    systemctl restart ipa.service || true
else
    echo "ipa.service not found — skipping enable/start."
fi

# --- Validate installation ---
if ipactl status >/dev/null 2>&1; then
    echo "IPA installation verified successfully."
else
    echo "WARNING: ipa-server-install may have failed to complete."
    echo "Check /var/log/ipaserver-install.log for details."
fi







echo "=========================================="
echo "IPA Enrollment User Setup"
echo "=========================================="
echo ""

# Check if IPA is installed
if ! command -v ipa &>/dev/null; then
    echo "[✖] ERROR: IPA command not found. Is this an IPA server?"
    exit 1
fi

# Get admin credentials
if ! klist &>/dev/null 2>&1; then
    echo "[+] Authenticating as admin..."
    
    if [ -n "$IPA_ADMIN_PASSWORD" ]; then
        echo "$IPA_ADMIN_PASSWORD" | kinit admin
    else
        echo "Please enter the IPA admin password:"
        kinit admin
    fi
    
    if ! klist &>/dev/null 2>&1; then
        echo "[✖] Failed to obtain Kerberos credentials"
        exit 1
    fi
    echo "[✔] Authenticated successfully"
else
    echo "[=] Already authenticated"
    klist | head -n 3
fi

echo ""

# Check if enrollment user already exists
if ipa user-show "$ENROLL_USERNAME" &>/dev/null; then
    echo "[!] User '$ENROLL_USERNAME' already exists"
    read -p "Do you want to reset the password? (y/N): " -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "[+] Resetting password for $ENROLL_USERNAME..."
        echo "$ENROLL_PASSWORD" | ipa user-mod "$ENROLL_USERNAME" --password
        echo "[✔] Password reset"
    else
        echo "[=] Keeping existing user"
    fi
else
    # Create enrollment user
    echo "[+] Creating enrollment user: $ENROLL_USERNAME"
    
    # Use expect-style input or printf for password
    printf "%s\n%s\n" "$ENROLL_PASSWORD" "$ENROLL_PASSWORD" | \
        ipa user-add "$ENROLL_USERNAME" \
        --first=Enrollment \
        --last=User \
        --password
    
    if [ $? -eq 0 ]; then
        echo "[✔] Enrollment user created successfully"
    else
        echo "[✖] Failed to create enrollment user"
        exit 1
    fi
fi

echo ""

# Grant enrollment permissions
echo "[+] Granting 'Enrollment Administrator' role..."

if ipa role-add-member "Enrollment Administrator" --users="$ENROLL_USERNAME" 2>&1 | grep -q "member.*already a member"; then
    echo "[=] User already has Enrollment Administrator role"
elif ipa role-show "Enrollment Administrator" --users 2>&1 | grep -q "$ENROLL_USERNAME"; then
    echo "[=] User already has Enrollment Administrator role"
else
    ipa role-add-member "Enrollment Administrator" --users="$ENROLL_USERNAME"
    echo "[✔] Role granted successfully"
fi

echo ""



# Verify setup
echo "[+] Verifying enrollment user configuration..."
echo ""
ipa user-show "$ENROLL_USERNAME"

echo ""
echo "=========================================="
echo "[✔] Setup Complete!"
echo "=========================================="
echo ""
echo "Enrollment user details:"
echo "  Username: $ENROLL_USERNAME"
echo "  Password: $ENROLL_PASSWORD"
echo "  Role: Enrollment Administrator"
echo ""
echo "Use on clients with these environment variables:"
echo ""
echo "  Environment=\"IPA_ENROLL_PRINCIPAL=$ENROLL_USERNAME\""
echo "  Environment=\"IPA_ENROLL_PASSWORD=$ENROLL_PASSWORD\""
echo ""
echo "⚠️  SECURITY NOTE:"
echo "  - Store this password securely"
echo "  - Consider using a keytab for production"
echo "  - Rotate password regularly"
echo ""


exit 0
