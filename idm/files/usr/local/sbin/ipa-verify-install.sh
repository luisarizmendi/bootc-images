#!/bin/bash
set -euo pipefail

echo "==========================================="
echo " FreeIPA Installation Verification"
echo "==========================================="

check_service_active() {
    local svc="$1"
    if systemctl is-active --quiet "$svc"; then
        echo "[OK] $svc is active"
    else
        echo "[ERROR] $svc is NOT active"
        systemctl status "$svc" --no-pager || true
    fi
}

# --- 1. Basic sanity checks ---
echo "→ Checking core configuration files..."
for f in /etc/ipa/default.conf /etc/ipa/ca.crt /etc/sssd/sssd.conf; do
    if [ -f "$f" ]; then
        echo "[OK] Found $f"
    else
        echo "[ERROR] Missing $f"
    fi
done

echo
echo "→ Checking SELinux context on /var/lib/ipa..."
if command -v matchpathcon >/dev/null 2>&1; then
    matchpathcon -V /var/lib/ipa >/dev/null 2>&1 || {
        echo "[WARN] SELinux context mismatch detected in /var/lib/ipa"
        echo "You can fix it with: restorecon -Rv /var/lib/ipa"
    }
else
    echo "[SKIP] matchpathcon not available."
fi

echo
echo "→ Checking IPA services..."
check_service_active "ipa.service"
check_service_active "dirsrv@$(hostname -f | tr 'a-z.' 'A-Z-').service" || true
check_service_active "pki-tomcatd@pki-tomcat.service"
check_service_active "krb5kdc.service"
check_service_active "kadmin.service"
check_service_active "named-pkcs11.service"
check_service_active "httpd.service"
check_service_active "sssd.service"

echo
echo "→ Checking if IPA CLI works..."
if ipa ping -q >/dev/null 2>&1; then
    echo "[OK] ipa ping succeeded"
else
    echo "[ERROR] ipa ping failed"
fi

echo
echo "→ Checking Kerberos authentication..."
if echo "$IPA_ADMIN_PASSWORD" | kinit admin >/dev/null 2>&1; then
    echo "[OK] kinit admin succeeded"
else
    echo "[ERROR] kinit admin failed"
fi

if klist >/dev/null 2>&1; then
    echo "[OK] Kerberos ticket cache available"
    klist
else
    echo "[ERROR] Kerberos cache not found"
fi

echo
echo "→ Checking DNS resolution for self..."
hostname_fqdn=$(hostname -f)
if dig +short "$hostname_fqdn" | grep -q "$(hostname -I | awk '{print $1}')"; then
    echo "[OK] DNS resolves $hostname_fqdn correctly"
else
    echo "[WARN] DNS resolution for $hostname_fqdn may not match local IP"
fi

echo
echo "→ Checking LDAP connectivity..."
if ldapsearch -x -H ldap://localhost -b "cn=accounts,$(awk -F= '/basedn/ {print $2}' /etc/ipa/default.conf 2>/dev/null)" >/dev/null 2>&1; then
    echo "[OK] LDAP connectivity working"
else
    echo "[ERROR] LDAP connectivity failed"
fi

echo
echo "→ Checking firewall rules..."
for svc in freeipa-ldap freeipa-ldaps freeipa-replication dns ntp http https; do
    if firewall-cmd --list-services | grep -qw "$svc"; then
        echo "[OK] Firewall allows $svc"
    else
        echo "[WARN] Firewall missing $svc"
    fi
done

echo
echo "→ Checking web UI accessibility..."
if curl -sk "https://$hostname_fqdn/ipa/ui/" | grep -q "FreeIPA"; then
    echo "[OK] Web UI reachable at https://$hostname_fqdn/ipa/ui/"
else
    echo "[WARN] Web UI not reachable — check httpd and certificates"
fi

echo
echo "==========================================="
echo "Verification complete."
echo "If any [ERROR] appeared, check /var/log/ipaserver-install.log"
echo "==========================================="
