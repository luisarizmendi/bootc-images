text --non-interactive
lang en_US.UTF-8
keyboard us
timezone UTC --utc

zerombr
clearpart --all --initlabel --disklabel=gpt
reqpart --add-boot
part / --grow --fstype xfs

network --bootproto=dhcp --device=link --activate --onboot=on

# bootc-generic-iso does its customization through this file, not through
# config.toml/--blueprint. Move the admin user here (same hash you already
# have in ./config.toml's [[customizations.user]] block) instead of relying
# on the blueprint being applied for this image type.
user --name=admin --password=REPLACE_WITH_HASH_FROM_CONFIG_TOML --iscrypted --groups=wheel
rootpw --lock

# --bootc-installer-payload-ref copies this exact ref into local container
# storage inside the ISO, so the install itself is offline. target-imgref
# is what the device will pull from on every future "bootc upgrade", so it
# must be the real registry ref, not the local one.
bootc --source-imgref containers-storage:ghcr.io/luisarizmendi/bootc-rhel:latest-amd64 --target-imgref ghcr.io/luisarizmendi/bootc-rhel:latest-amd64

reboot
