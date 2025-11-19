#!/bin/bash
virsh pool-define /etc/libvirt/storage/default.xml
virsh pool-autostart default
virsh pool-start default
