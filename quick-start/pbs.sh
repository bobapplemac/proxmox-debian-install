#!/bin/bash

# Quick start:
# curl -fsSL https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/quick-start/pbs.sh | bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        pbs.sh
# Revision:    r1
# Modified:    2026-08-21
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/proxmox-debian-install
# Description: Downloads an ordered working set of the canonical helper scripts for the Proxmox Backup Server standard Debian installation workflow.
#              Downloaded working copies receive numeric prefixes reflecting the recommended
#              execution order. This script only downloads files and marks them executable.
# ------------------------------------------------------------------------------------------

set -euo pipefail

BASE_URL=https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main
DEST_DIR=proxmox-pbs

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
curl -fsSL "$BASE_URL/setup-nics.sh" -o 20-setup-nics.sh
curl -fsSL "$BASE_URL/setup-static-ip.sh" -o 30-setup-static-ip.sh
curl -fsSL "$BASE_URL/disable-ipv6.sh" -o 40-disable-ipv6.sh
curl -fsSL "$BASE_URL/setup-swapfile.sh" -o 50-setup-swapfile.sh
curl -fsSL "$BASE_URL/setup-xfs-storage.sh" -o 60-setup-xfs-storage.sh
curl -fsSL "$BASE_URL/install-pbs.sh" -o 90-install-pbs.sh

chmod +x ./*.sh

echo
echo "Download complete."
echo
echo "Recommended workflow:"
echo "  20-setup-nics.sh"
echo "      -> reboot"
echo
echo "  30-setup-static-ip.sh"
echo "      -> reboot"
echo
echo "  40-disable-ipv6.sh          optional"
echo "  50-setup-swapfile.sh        optional; recommended if no swap exists"
echo "  60-setup-xfs-storage.sh     optional; as needed"
echo
echo "  90-install-pbs.sh"
echo "      -> reboot"
