#text --non-interactive
text

lang en_US.UTF-8
keyboard us

network --bootproto=dhcp --device=link --activate --onboot=on

user --name=admin --password="$6$/7rTITXmb1xpkB52$1L6xl53aTMayMIqhdxh6VxLGguy2CUxxf50oqcJGElUgcyx/8nTIEBKtvP6erLtwwLS5B6ZyCEDkrZMGC8ydN/" --iscrypted --groups=wheel
rootpw --lock

bootc --source-imgref containers-storage:ghcr.io/luisarizmendi/bootc-kiosk:latest --target-imgref ghcr.io/luisarizmendi/bootc-kiosk:latest
