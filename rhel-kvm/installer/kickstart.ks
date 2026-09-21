text --non-interactive
lang en_US.UTF-8
keyboard us
timezone UTC --utc

zerombr
clearpart --all --initlabel --disklabel=gpt
reqpart --add-boot
part / --grow --fstype xfs

network --bootproto=dhcp --device=link --activate --onboot=on

user --name=admin --password="$6$/7rTITXmb1xpkB52$1L6xl53aTMayMIqhdxh6VxLGguy2CUxxf50oqcJGElUgcyx/8nTIEBKtvP6erLtwwLS5B6ZyCEDkrZMGC8ydN/" --iscrypted --groups=wheel
rootpw --lock

bootc --source-imgref=registry:ghcr.io/luisarizmendi/bootc-rhel-kvm:latest --target-imgref=ghcr.io/luisarizmendi/bootc-rhel-kvm:latest

reboot
