#!/bin/bash

set -euxo pipefail

image=$1
shift

target_user=""
additional_copy_args=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      target_user="$2"
      shift 2
      ;;
    *)
      additional_copy_args="$additional_copy_args $1"
      shift
      ;;
  esac
done

mkdir -p /usr/lib/containers-image-cache
sha=$(echo "$image" | sha256sum | awk '{ print $1 }')
skopeo copy $additional_copy_args --preserve-digests docker://$image dir:/usr/lib/containers-image-cache/$sha
echo "$image,$sha,$target_user" >> /usr/lib/containers-image-cache/mapping.txt