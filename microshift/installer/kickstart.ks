text --non-interactive
lang en_US.UTF-8
keyboard us
timezone UTC --utc

network --bootproto=dhcp --device=link --activate --onboot=on

user --name=admin --password="$6$/7rTITXmb1xpkB52$1L6xl53aTMayMIqhdxh6VxLGguy2CUxxf50oqcJGElUgcyx/8nTIEBKtvP6erLtwwLS5B6ZyCEDkrZMGC8ydN/" --iscrypted --groups=wheel
rootpw --lock

bootc --source-imgref=registry:ghcr.io/luisarizmendi/bootc-microshift:v1 --target-imgref=ghcr.io/luisarizmendi/bootc-microshift:v1

%pre --interpreter=/bin/bash
exec > /tmp/pre.log 2>&1
set -ex

# First non-removable physical disk (name only, e.g. "vda")
DISK=$(lsblk -ndo NAME,TYPE,RO,RM | awk '$2=="disk" && $3==0 && $4==0 && $1 !~ /^zram/ && $1 !~ /^loop/ {print $1; exit}')

# 30% of the disk goes to the LVMS volume group (floor = the PV's minimum size)
TOTAL=$(blockdev --getsize64 "/dev/${DISK}")
LVMS_SIZE_MIB=$(( TOTAL * 30 / 100 / 1048576 ))
if [ "$LVMS_SIZE_MIB" -lt 10000 ]; then
    LVMS_SIZE_MIB=10000
fi
echo "Disk: ${DISK}, LVMS PV max size: ${LVMS_SIZE_MIB} MiB"

cat <<EOF > /tmp/dynamic-partition.ks
zerombr
clearpart --all --initlabel --disklabel=gpt --drives=${DISK}
reqpart --add-boot
part swap --size=2048 --ondisk=${DISK}
part pv.01 --size=10000 --grow --maxsize=${LVMS_SIZE_MIB} --ondisk=${DISK}
part / --size=1000 --grow --fstype xfs --ondisk=${DISK}
# VG name "microshift" is the default MicroShift looks for; leave it without LVs
# so LVMS gets all of the free space.
volgroup microshift pv.01
EOF
%end

%include /tmp/dynamic-partition.ks

# No %post needed: MicroShift 4.22 auto-detects the VG "microshift" when
# /etc/microshift/lvmd.yaml is absent.

reboot --eject