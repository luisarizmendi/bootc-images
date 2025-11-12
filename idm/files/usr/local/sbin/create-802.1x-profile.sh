#!/bin/bash
set -e

# Wait for IdM to be fully ready
sleep 10

# Use environment variable from systemd (idm-server-install.conf)
IPA_ADMIN_PASSWORD="${IPA_ADMIN_PASSWORD}"

if [ -z "$IPA_ADMIN_PASSWORD" ]; then
    echo "ERROR: IPA_ADMIN_PASSWORD not set"
    exit 1
fi

# Obtain Kerberos ticket
echo "$IPA_ADMIN_PASSWORD" | kinit admin

echo "Creating 802.1x certificate profile..."

# Check if profile already exists
if ipa certprofile-show 802dot1xClient 2>/dev/null; then
    echo "802.1x certificate profile already exists"
    kdestroy
    exit 0
fi

# Create the certificate profile from template
if [ -f /etc/idm-server/802.1x-profile.cfg ]; then
    ipa certprofile-import 802dot1xClient \
        --desc="Certificate profile for 802.1x client authentication" \
        --file=/etc/idm-server/802.1x-profile.cfg \
        --store=true
    echo "Certificate profile created successfully"
else
    echo "ERROR: 802.1x profile template not found at /etc/idm-server/802.1x-profile.cfg"
    kdestroy
    exit 1
fi

# Create a CA ACL to allow hosts to get certificates with this profile
echo "Creating CA ACL..."
ipa caacl-add 802dot1x_acl --desc="Allow hosts to request 802.1x certificates"
ipa caacl-add-profile 802dot1x_acl --certprofiles=802dot1xClient
ipa caacl-add-host 802dot1x_acl --hosts=$(hostname -f)

# You can also add host groups
# ipa caacl-add-hostgroup 802dot1x_acl --hostgroups=your_hostgroup

echo "802.1x certificate profile and ACL configured successfully"

# Clean up
kdestroy

exit 0