text

lang en_US.UTF-8
keyboard us
timezone Europe/Madrid --utc

xconfig --startxonboot

%pre
#!/bin/bash
best=""
best_size=0
while read -r name size type rm; do
    [ "$type" = "disk" ] || continue
    [ "$rm" = "0" ] || continue
    if [ "$size" -gt "$best_size" ]; then
        best_size=$size
        best=$name
    fi
done < <(lsblk -dbn -o NAME,SIZE,TYPE,RM)
if [ -z "$best" ]; then
    echo "" > /tmp/part-include.ks
else
    echo "ignoredisk --only-use=$best" > /tmp/part-include.ks
fi



##################################################################################
# Configure Wi-Fi for the installer.
mkdir -p /etc/NetworkManager/system-connections

cat > /etc/NetworkManager/system-connections/redhat.nmconnection <<'EOF'
[connection]
id=redhat
type=wifi
interface-name=w1P1p1s0
autoconnect=true

[wifi]
mode=infrastructure
ssid=redhat

[wifi-security]
key-mgmt=wpa-psk
psk=redhatrules

[ipv4]
method=auto

[ipv6]
method=auto
EOF

chmod 600 /etc/NetworkManager/system-connections/redhat.nmconnection

# Reload NetworkManager so the installer can see the connection.
nmcli connection reload
##################################################################################


%end

%include /tmp/part-include.ks

zerombr
clearpart --all --initlabel --disklabel=gpt
reqpart --add-boot
part / --grow --fstype xfs

network --bootproto=dhcp --device=link --activate --onboot=on

user --name=admin --password="$6$/7rTITXmb1xpkB52$1L6xl53aTMayMIqhdxh6VxLGguy2CUxxf50oqcJGElUgcyx/8nTIEBKtvP6erLtwwLS5B6ZyCEDkrZMGC8ydN/" --iscrypted --groups=wheel
rootpw --lock

#bootc --source-imgref=containers-storage:ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection-custom:latest-arm64 --target-imgref=ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection-custom:latest
bootc --source-imgref=registry:ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection-custom:latest --target-imgref=ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection-custom:latest


reboot

