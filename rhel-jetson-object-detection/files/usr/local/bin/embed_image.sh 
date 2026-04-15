#!/bin/bash
set -euxo pipefail
image=$1
mkdir -p /usr/lib/containers-image-cache
sha=$(echo "$image" | sha256sum | awk '{ print $1 }')
skopeo copy --preserve-digests docker://$image dir:/usr/lib/containers-image-cache/$sha
echo "$image,$sha" >> /usr/lib/containers-image-cache/mapping.txt