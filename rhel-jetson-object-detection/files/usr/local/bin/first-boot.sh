#!/bin/bash
set -euo pipefail

###############################################################
## HOSTNAME ###################################################
echo "Configuring hostname..."
/usr/local/bin/set-hostname-from-mac.sh


###############################################################
## GET FILES
echo "Getting files..."
until /usr/local/bin/get-files.sh; do
  echo "Script /usr/local/bin/get-files.sh failed, retrying..."
  sleep 5
done

###############################################################
## 

