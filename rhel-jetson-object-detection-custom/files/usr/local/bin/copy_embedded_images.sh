#!/bin/bash

set -euxo pipefail

while IFS="," read -r image sha target_user
do
  if [[ -n "$target_user" ]]; then
    runuser -l "$target_user" -c \
      "skopeo copy --preserve-digests \
        dir:/usr/lib/containers-image-cache/$sha \
        containers-storage:$image"
  else
    skopeo copy --preserve-digests \
      dir:/usr/lib/containers-image-cache/$sha \
      containers-storage:$image
  fi
done < /usr/lib/containers-image-cache/mapping.txt