#!/bin/bash
export LIBVIRT_DEFAULT_URI=qemu:///system
virsh  net-undefine default
virsh net-define /etc/libvirt/network/default.xml
virsh net-start default
virsh net-autostart default
for i in $(ls /etc/libvirt/qemu/*.xml); do virsh define $i ;done

