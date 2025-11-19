#!/bin/bash

## HOSTNAME
bash /usr/local/bin/set-hostname-from-mac.sh

## MICROSHIFT
bash /usr/local/bin/create-microshift-dynamic-conf.sh

## GET FILES
until bash /usr/local/bin/get-files.sh; do
  echo "Script /usr/local/bin/get-files.sh failed, retrying..."
  sleep 5
done

## COCKPIT
ausearch -c 'cockpit-session' --raw | audit2allow -M my-cockpitsession
semodule -X 300 -i my-cockpitsession.pp

## LIBVIRT
export LIBVIRT_DEFAULT_URI=qemu:///system
virsh  net-undefine default
virsh net-define /etc/libvirt/network/default.xml
virsh net-start default
virsh net-autostart default
for i in $(ls /etc/libvirt/qemu/*.xml); do virsh define $i ;done
for i in $(virsh list --all --name); do systemctl start libvirt-vm@${i}.service && do systemctl enable libvirt-vm@${i}.service; done


exit 0