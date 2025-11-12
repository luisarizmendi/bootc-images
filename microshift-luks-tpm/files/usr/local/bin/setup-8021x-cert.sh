#!/usr/bin/bash
set -euo pipefail

# === CONFIGURATION FROM ENVIRONMENT ===
# These should be set via EnvironmentFile in systemd
: "${IPA_SERVER:?IPA_SERVER must be set}"
: "${IPA_DOMAIN:?IPA_DOMAIN must be set}"
: "${INTERFACE:?INTERFACE must be set}"
: "${NM_PROFILE:=8021x}"
: "${CERT_DIR:=/etc/pki/tls/certs}"
: "${KEY_DIR:=/etc/pki/tls/private}"
: "${BOOTSTRAP_DIR:=/etc/pki/tls/bootstrap}"
: "${CA_ANCHOR:=/etc/pki/ca-trust/source/anchors/ca.crt}"
: "${CA_ALIAS:=IPA}"

# Authentication options (at least one must be set)
# IPA_ENROLL_PASSWORD - admin password
# IPA_ENROLL_PRINCIPAL - Kerberos principal (requires password or keytab)
# IPA_ENROLL_KEYTAB - path to keytab file
# IPA_ENROLL_OTP - One-Time Password for host enrollment

CERT_FILE="$CERT_DIR/8021x.pem"
KEY_FILE="$KEY_DIR/8021x.key"
NM_FILE="/etc/NetworkManager/system-connections/${NM_PROFILE}.nmconnection"

echo "[+] Starting 802.1X client preparation for IdM integration..."

# === Ensure hostname is FQDN ===
CURRENT_HOSTNAME=$(hostname)
if [[ ! "$CURRENT_HOSTNAME" =~ \. ]]; then
    echo "[!] Current hostname '$CURRENT_HOSTNAME' is not fully qualified."
    
    if [ -n "${IPA_HOSTNAME:-}" ]; then
        echo "[+] Setting hostname to: $IPA_HOSTNAME"
        hostnamectl set-hostname "$IPA_HOSTNAME"
    else
        # Try to construct FQDN
        FQDN="${CURRENT_HOSTNAME}.${IPA_DOMAIN}"
        echo "[+] Setting hostname to: $FQDN"
        hostnamectl set-hostname "$FQDN"
    fi
    
    # Verify
    NEW_HOSTNAME=$(hostname -f)
    echo "[+] New FQDN: $NEW_HOSTNAME"
else
    echo "[=] Hostname is already FQDN: $CURRENT_HOSTNAME"
fi

# === Configure Kerberos before enrollment (needed for principal auth) ===
if [ ! -f /etc/krb5.conf ] || ! grep -q "$IPA_DOMAIN" /etc/krb5.conf; then
    echo "[+] Pre-configuring Kerberos client for enrollment..."
    
    # Convert domain to uppercase for realm
    IPA_REALM=$(echo "$IPA_DOMAIN" | tr '[:lower:]' '[:upper:]')
    
    cat > /etc/krb5.conf <<EOF
[libdefaults]
  default_realm = ${IPA_REALM}
  dns_lookup_realm = false
  dns_lookup_kdc = false
  rdns = false
  dns_canonicalize_hostname = false
  ticket_lifetime = 24h
  forwardable = true
  udp_preference_limit = 0

[realms]
  ${IPA_REALM} = {
    kdc = ${IPA_SERVER}
    master_kdc = ${IPA_SERVER}
    admin_server = ${IPA_SERVER}
    default_domain = ${IPA_DOMAIN}
  }

[domain_realm]
  .${IPA_DOMAIN} = ${IPA_REALM}
  ${IPA_DOMAIN} = ${IPA_REALM}
EOF

    echo "[✔] Kerberos configuration created for realm ${IPA_REALM}."
    
    # Test Kerberos connectivity if using principal auth
    if [ -n "${IPA_ENROLL_PRINCIPAL:-}" ] && [ -n "${IPA_ENROLL_PASSWORD:-}" ]; then
        echo "[+] Testing Kerberos authentication..."
        if echo "$IPA_ENROLL_PASSWORD" | kinit "$IPA_ENROLL_PRINCIPAL" 2>/dev/null; then
            echo "[✔] Kerberos authentication successful."
            kdestroy
        else
            echo "[!] WARNING: Kerberos authentication test failed."
            echo "    This may cause enrollment issues. Verify:"
            echo "    - IPA_ENROLL_PRINCIPAL is correct: $IPA_ENROLL_PRINCIPAL"
            echo "    - Password is correct"
            echo "    - Network connectivity to $IPA_SERVER:88 (Kerberos)"
        fi
    fi
else
    echo "[=] Kerberos already configured."
fi


# === Check if system is already enrolled ===
if ! grep -q "server" /etc/ipa/default.conf 2>/dev/null; then
    echo "[+] Enrolling system into IdM domain $IPA_DOMAIN..."
    
    # Build enrollment command base
    ENROLL_ARGS=(
        "ipa-client-install"
        "--mkhomedir"
        "--domain=$IPA_DOMAIN"
        "--server=$IPA_SERVER"
        "--force-join"
        "-U"
    )
    
    if [ -n "${IPA_ENROLL_OTP:-}" ]; then
        echo "[+] Using One-Time Password for enrollment..."
        ENROLL_ARGS+=("--password=$IPA_ENROLL_OTP")
        
    elif [ -n "${IPA_ENROLL_KEYTAB:-}" ]; then
        echo "[+] Using keytab file for enrollment..."
        ENROLL_ARGS+=("--keytab=$IPA_ENROLL_KEYTAB")
        
    elif [ -n "${IPA_ENROLL_PRINCIPAL:-}" ] && [ -n "${IPA_ENROLL_PASSWORD:-}" ]; then
        echo "[+] Using principal and password for enrollment..."
        ENROLL_ARGS+=("--principal=$IPA_ENROLL_PRINCIPAL" "--password=$IPA_ENROLL_PASSWORD")
        
    elif [ -n "${IPA_ENROLL_PASSWORD:-}" ]; then
        echo "[+] Using admin password for enrollment..."
        ENROLL_ARGS+=("--principal=admin" "--password=$IPA_ENROLL_PASSWORD")
        
    else
        echo "[✖] ERROR: No authentication method provided for IPA enrollment."
        echo "    Set one of: IPA_ENROLL_OTP, IPA_ENROLL_KEYTAB, IPA_ENROLL_PASSWORD, or IPA_ENROLL_PRINCIPAL+IPA_ENROLL_PASSWORD"
        exit 1
    fi
    
    # Debug: show the command being executed (sanitize password)
    SAFE_ARGS=("${ENROLL_ARGS[@]}")
    for i in "${!SAFE_ARGS[@]}"; do
        if [[ "${SAFE_ARGS[$i]}" == --password=* ]]; then
            SAFE_ARGS[$i]="--password=***REDACTED***"
        fi
    done
    echo "[DEBUG] Executing: ${SAFE_ARGS[*]}"
    
    # Execute enrollment using array expansion
    if ! "${ENROLL_ARGS[@]}"; then
        echo "[✖] IPA client enrollment failed. Check /var/log/ipaclient-install.log"
        echo ""
        echo "Common causes:"
        echo "  - OTP token already used or invalid (generate a new one)"
        echo "  - Wrong password"
        echo "  - Principal lacks enrollment permissions (check 'Enrollment Administrator' role)"
        echo "  - Host already exists in IPA (delete it first)"
        echo "  - Network connectivity issues to IPA server"
        echo ""
        echo "To troubleshoot:"
        echo "  1. Check the log: cat /var/log/ipaclient-install.log"
        echo "  2. Test connectivity: ping $IPA_SERVER"
        echo "  3. Test authentication: kinit ${IPA_ENROLL_PRINCIPAL:-admin}"
        echo "  4. For OTP: Generate new token on IPA server:"
        echo "     ipa host-del $(hostname -f) --updatedns  # if host exists"
        echo "     ipa host-add $(hostname -f) --random"
        echo "  5. Check principal permissions:"
        echo "     ipa user-show ${IPA_ENROLL_PRINCIPAL:-admin}"
        exit 1
    fi
else
    echo "[=] System already enrolled in IdM."
fi

# === Ensure certmonger is enabled and running ===
echo "[+] Enabling and starting certmonger..."
systemctl enable --now certmonger

# === Verify CA registration ===
if ! getcert list-cas | grep -q "CA 'IPA'"; then
    echo "[!] IPA CA not found in certmonger. Restarting certmonger..."
    systemctl restart certmonger
    sleep 5
    getcert list-cas | grep -q "CA 'IPA'" || {
        echo "[✖] IPA CA still not visible — check enrollment or connectivity."
        exit 1
    }
fi
echo "[✔] IPA CA detected in certmonger."

# === Prepare directories for bootstrap certs ===
echo "[+] Preparing certificate directories..."
mkdir -p "$CERT_DIR" "$KEY_DIR" "$BOOTSTRAP_DIR"
chmod 700 "$KEY_DIR"

# ===  Generate temporary bootstrap certificate if missing ===
BOOTSTRAP_CERT="$BOOTSTRAP_DIR/8021x-bootstrap.pem"
BOOTSTRAP_KEY="$BOOTSTRAP_DIR/8021x-bootstrap.key"

if [ ! -f "$BOOTSTRAP_CERT" ] || [ ! -f "$BOOTSTRAP_KEY" ]; then
    echo "[+] Generating temporary bootstrap certificate..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$BOOTSTRAP_KEY" \
        -out "$BOOTSTRAP_CERT" \
        -subj "/CN=$(hostname -f)" \
        -days 7
else
    echo "[=] Bootstrap certificate already exists."
fi

# === Ensure IdM CA certificate is trusted ===
if [ ! -f "$CA_ANCHOR" ]; then
    echo "[!] IPA CA anchor not found at $CA_ANCHOR."
    echo "    You can copy it from the IdM server: scp root@$IPA_SERVER:/etc/ipa/ca.crt $CA_ANCHOR"
    echo "    Then run: update-ca-trust extract"
    exit 1
else
    update-ca-trust extract
fi

# === Create a basic NetworkManager 802.1X profile ===
if [ ! -f "$NM_FILE" ]; then
    echo "[+] Creating NetworkManager 802.1X connection profile..."
    cat > "$NM_FILE" <<EOF
[connection]
id=${NM_PROFILE}
type=ethernet
interface-name=${INTERFACE}

[802-1x]
eap=tls;
identity=host/$(hostname -f)
ca-cert=${CA_ANCHOR}
client-cert=${BOOTSTRAP_CERT}
private-key=${BOOTSTRAP_KEY}
private-key-password-flags=0

[ipv4]
method=auto
EOF
    chmod 600 "$NM_FILE"
else
    echo "[=] NetworkManager profile ${NM_FILE} already exists."
fi

# === Reload NetworkManager to apply ===
echo "[+] Reloading NetworkManager configuration..."
systemctl reload NetworkManager

echo "[✔] Client preparation complete."

# Check if already tracking this cert
if ! getcert list | grep -q "$CERT_FILE"; then
    echo "[+] Requesting new 802.1X certificate from IPA CA..."
    getcert request \
        -c "$CA_ALIAS" \
        -f "$CERT_FILE" \
        -k "$KEY_FILE" \
        -N "CN=$(hostname -f)" \
        -K host/$(hostname -f) \
        -U id-kp-clientAuth \
        -D "$(hostname -f)" \
        -r \
        -w \
        -C "systemctl reload NetworkManager"
else
    echo "[=] Certmonger already tracking $CERT_FILE"
fi

# Wait until cert is ready
echo "[+] Waiting for certmonger to obtain the certificate..."
timeout=180
while [ $timeout -gt 0 ]; do
    if getcert list | grep -A5 "$CERT_FILE" | grep -q "status: MONITORING"; then
        echo "[✔] Certificate successfully issued and being monitored!"
        break
    fi
    sleep 5
    timeout=$((timeout - 5))
done

if [ $timeout -le 0 ]; then
    echo "[!] Timeout waiting for certificate issuance."
    echo "    Check: getcert list"
    exit 1
fi

# Replace bootstrap references in NM config
if [ -f "$NM_FILE" ] && grep -q "$BOOTSTRAP_DIR" "$NM_FILE"; then
    echo "[+] Updating NetworkManager config to use permanent certificate..."
    sed -i "s|$BOOTSTRAP_DIR/8021x-bootstrap.pem|$CERT_FILE|" "$NM_FILE"
    sed -i "s|$BOOTSTRAP_DIR/8021x-bootstrap.key|$KEY_FILE|" "$NM_FILE"
fi

# Reload NM to apply certs
echo "[+] Reloading NetworkManager..."
systemctl reload NetworkManager

touch /var/lib/setup-8021x-cert.done
echo "[✔] 802.1X certificate setup complete."

# Final checks
echo ""
echo "[+] Running final verification checks..."
CHECKS_PASSED=true

if ipa ping >/dev/null 2>&1; then
    echo "[✓] IPA connectivity: OK"
else
    echo "[✖] IPA connectivity: FAILED"
    CHECKS_PASSED=false
fi

if systemctl is-active --quiet certmonger; then
    echo "[✓] Certmonger service: Running"
else
    echo "[✖] Certmonger service: Not running"
    CHECKS_PASSED=false
fi

if getcert list | grep -q "status: MONITORING"; then
    echo "[✓] Certificate status: Monitoring"
else
    echo "[✖] Certificate status: Not monitoring"
    CHECKS_PASSED=false
fi

echo ""
if [ "$CHECKS_PASSED" = true ]; then
    echo "✅ 802.1X + IPA setup successful."
else
    echo "❌ Some checks failed. Review output above."
    exit 1
fi