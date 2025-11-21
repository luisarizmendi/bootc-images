#!/bin/bash
set -euo pipefail

###############################################################
## HOSTNAME ###################################################
echo "Configuring hostname..."
/usr/local/bin/set-hostname-from-mac.sh

###############################################################
## MICROSHIFT
echo "Configuring Microshift conf file..."
set +e
/usr/local/bin/create-microshift-dynamic-conf.sh
set -e

###############################################################
## GET FILES
echo "Getting files..."
until /usr/local/bin/get-files.sh; do
  echo "Script /usr/local/bin/get-files.sh failed, retrying..."
  sleep 5
done
