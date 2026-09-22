text --non-interactive

lang en_US.UTF-8
keyboard us

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
%end

%include /tmp/part-include.ks

zerombr
clearpart --all --initlabel --disklabel=gpt
reqpart --add-boot
part / --grow --fstype xfs

network --bootproto=dhcp --device=link --activate --onboot=on

user --name=admin --password="$6$/7rTITXmb1xpkB52$1L6xl53aTMayMIqhdxh6VxLGguy2CUxxf50oqcJGElUgcyx/8nTIEBKtvP6erLtwwLS5B6ZyCEDkrZMGC8ydN/" --iscrypted --groups=wheel
rootpw --lock

bootc --source-imgref=registry:ghcr.io/luisarizmendi/bootc-kiosk:latest --target-imgref=ghcr.io/luisarizmendi/bootc-kiosk:latest

reboot