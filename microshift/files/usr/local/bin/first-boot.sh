#!/bin/bash

## HOSTNAME
echo "Configuring hostname..."
bash /usr/local/bin/set-hostname-from-mac.sh

## MICROSHIFT
echo "Configuring Microshift conf file..."
bash /usr/local/bin/create-microshift-dynamic-conf.sh

## GET FILES
echo "Getting files..."
until bash /usr/local/bin/get-files.sh; do
  echo "Script /usr/local/bin/get-files.sh failed, retrying..."
  sleep 5
done

## COCKPIT
echo "Configuring SELinux for Cockpit..."
#cd /root
#ausearch -c 'cockpit-session' --raw | audit2allow -M my-cockpitsession
#semodule -X 300 -i my-cockpitsession.pp

## LIBVIRT
echo "Configuring libvirt..."
export LIBVIRT_DEFAULT_URI=qemu:///system
virsh  net-undefine default
virsh net-define /etc/libvirt/network/default.xml
virsh net-start default
virsh net-autostart default
for i in $(ls /etc/libvirt/qemu/*.xml); do virsh define $i ;done
for i in $(virsh list --all --name); do systemctl start libvirt-vm@${i}.service && systemctl enable libvirt-vm@${i}.service ; virsh autostart $i ; done


exit 0