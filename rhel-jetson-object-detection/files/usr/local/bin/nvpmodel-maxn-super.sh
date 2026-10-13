#!/bin/bash
set -euo pipefail
SUPER_CONF=/etc/nvpmodel/nvpmodel_p3767_0003_super.conf

# Point the default config at the super variant
ln -sf "${SUPER_CONF}" /etc/nvpmodel.conf

# Look up the MAXN_SUPER ID by name instead of hardcoding it
ID=$(sed -n 's/.*POWER_MODEL ID=\([0-9]*\) NAME=MAXN_SUPER.*/\1/p' "${SUPER_CONF}")
[ -n "${ID}" ] || { echo "MAXN_SUPER not found in ${SUPER_CONF}" >&2; exit 1; }

/usr/sbin/nvpmodel -m "${ID}"
/usr/sbin/nvpmodel -q