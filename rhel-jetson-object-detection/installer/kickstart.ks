text
lang en_US.UTF-8
keyboard us
timezone Europe/Madrid --utc
xconfig --startxonboot

%pre --log=/tmp/pre.log
#!/bin/bash

##################################################################################
# Select the largest non-removable disk
##################################################################################
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
# Configure Wi-Fi for the installer
##################################################################################
WIFI_DEV="wlP1p1s0"
WIFI_CON="wifi"

mkdir -p /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/${WIFI_CON}.nmconnection <<EOF
[connection]
id=${WIFI_CON}
type=wifi
interface-name=${WIFI_DEV}
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
chmod 600 /etc/NetworkManager/system-connections/${WIFI_CON}.nmconnection

# Retry until the Wi-Fi comes up (skipped if Ethernet is already connected)
rfkill unblock wifi 2>/dev/null
for i in $(seq 1 30); do
    if nmcli -t -f TYPE,STATE device | grep -q '^ethernet:connected$'; then
        echo "Ethernet already connected, skipping Wi-Fi retries"
        break
    fi
    nmcli connection reload
    nmcli radio wifi on
    nmcli device set ${WIFI_DEV} managed yes 2>/dev/null
    nmcli device wifi rescan ifname ${WIFI_DEV} 2>/dev/null
    sleep 2
    if nmcli connection up ${WIFI_CON} ifname ${WIFI_DEV}; then
        echo "Wi-Fi up after $i attempt(s)"
        break
    fi
    sleep 3
done

##################################################################################
# Watchdog: keep Wi-Fi connected during the install if nothing else is up
# (covers the case where Anaconda resets the network after %pre)
##################################################################################
cat > /tmp/wifi-watchdog.sh <<'EOF'
#!/bin/bash
WIFI_DEV="wlP1p1s0"
WIFI_CON="redhat"
for i in $(seq 1 720); do
    if ! nmcli -t -f TYPE,STATE device | grep -Eq '^(ethernet|wifi):connected$'; then
        nmcli radio wifi on
        nmcli device wifi rescan ifname ${WIFI_DEV} 2>/dev/null
        nmcli connection up ${WIFI_CON} ifname ${WIFI_DEV}
    fi
    sleep 5
done
EOF
chmod +x /tmp/wifi-watchdog.sh
setsid /tmp/wifi-watchdog.sh >/tmp/wifi-watchdog.log 2>&1 </dev/null &
%end

%include /tmp/part-include.ks

zerombr
clearpart --all --initlabel --disklabel=gpt
reqpart --add-boot
part / --grow --fstype xfs

network --bootproto=dhcp --device=link --activate --onboot=on

user --name=admin --password="$6$/7rTITXmb1xpkB52$1L6xl53aTMayMIqhdxh6VxLGguy2CUxxf50oqcJGElUgcyx/8nTIEBKtvP6erLtwwLS5B6ZyCEDkrZMGC8ydN/" --iscrypted --groups=wheel
rootpw --lock

#bootc --source-imgref=containers-storage:ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection:latest-arm64 --target-imgref=ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection:latest
bootc --source-imgref=registry:ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection:latest --target-imgref=ghcr.io/luisarizmendi/bootc-rhel-jetson-object-detection:latest

reboot