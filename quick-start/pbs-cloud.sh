#!/bin/bash

# Quick start:
# curl -fsSL https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/quick-start/pbs-cloud.sh | bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        pbs-cloud.sh
# Revision:    r2
# Modified:    2026-11-02
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/proxmox-debian-install
# Description: Downloads an ordered working set of the canonical helper scripts for the Proxmox Backup Server Debian cloud-image installation workflow.
#              Downloaded working copies receive numeric prefixes reflecting the recommended
#              execution order. A persistent runbook records the recommended workflow.
# ------------------------------------------------------------------------------------------

set -euo pipefail

BASE_URL=https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main
DEST_DIR=proxmox-pbs-cloud

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v curl >/dev/null 2>&1 || die "Required command 'curl' was not found."

if [[ -e $DEST_DIR && ! -d $DEST_DIR ]]; then
    die "$DEST_DIR already exists and is not a directory."
fi

mkdir -p "$DEST_DIR"
cd "$DEST_DIR"

echo "Downloading workflow scripts to:"
echo "  $(pwd)"
echo
curl -fsSL "$BASE_URL/setup-ifupdown.sh" -o 10-setup-ifupdown.sh
curl -fsSL "$BASE_URL/setup-nics.sh" -o 20-setup-nics.sh
curl -fsSL "$BASE_URL/setup-static-ip.sh" -o 30-setup-static-ip.sh
curl -fsSL "$BASE_URL/disable-ipv6.sh" -o 40-disable-ipv6.sh
curl -fsSL "$BASE_URL/setup-swapfile.sh" -o 50-setup-swapfile.sh
curl -fsSL "$BASE_URL/setup-xfs-storage.sh" -o 60-setup-xfs-storage.sh
curl -fsSL "$BASE_URL/install-pbs.sh" -o 90-install-pbs.sh

chmod +x ./*.sh

cat > RUNBOOK.txt <<'EOF'
Download complete.

Recommended workflow:
  10-setup-ifupdown.sh
      -> reboot

  20-setup-nics.sh            optional if Netplan interface mapping was preserved
      -> reboot if run

  30-setup-static-ip.sh       optional if converted Netplan was already static
      -> reboot if run

  40-disable-ipv6.sh          optional
  50-setup-swapfile.sh        optional; recommended if no swap exists
  60-setup-xfs-storage.sh     optional; as needed

  90-install-pbs.sh
      -> reboot
EOF

echo
cat RUNBOOK.txt
echo
echo "Workflow instructions saved to: $(pwd)/RUNBOOK.txt"
