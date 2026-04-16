#!/bin/bash
set -euxo pipefail

# created with tmpfile
#mkdir -p /var/lib/shared/overlay-images \
#         /var/lib/shared/overlay-layers \
#         /var/lib/shared/vfs-images \
#         /var/lib/shared/vfs-layers

#touch /var/lib/shared/libpod/container_api.sqlite 2>/dev/null || true

while IFS="," read -r image sha
do
    skopeo copy \
        --preserve-digests \
        dir:/usr/lib/containers-image-cache/$sha \
        containers-storage:[overlay@/var/lib/shared+/run/containers/storage]$image
done < /usr/lib/containers-image-cache/mapping.txt

# Make the shared store readable by the cstore group
chown -R root:cstore /var/lib/shared/
find /var/lib/shared/ -type f -exec chmod 640 {} \;
find /var/lib/shared/ -type d -exec chmod 750 {} \;