#!/bin/bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        setup-swapfile.sh
# Revision:    r2
# Modified:    2026-08-20
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Description: Creates and enables a swap file on a Debian system that does not already have
#              swap configured. Prompts for the desired swap size, defaults to 8 GiB, adds the
#              swap file to /etc/fstab, and configures vm.swappiness=10 persistently.
#
# Requirements:
#              bash
#              coreutils
#              grep
#              procps
#              util-linux
#
# Supported Filesystems:
#              ext4
#              xfs
#
# Output:
#              /swapfile
#              /etc/fstab
#              /etc/sysctl.d/99-swappiness.conf
#
# Notes:
#              The script refuses to continue if active swap, a configured swap entry in
#              /etc/fstab, or an existing /swapfile is detected.
# ------------------------------------------------------------------------------------------

set -euo pipefail

SWAPFILE=/swapfile
FSTAB=/etc/fstab
SWAPPINESS_CONF=/etc/sysctl.d/99-swappiness.conf
DEFAULT_SWAP_GIB=8
SWAPPINESS=10


die() {
    echo "ERROR: $*" >&2
    exit 1
}


# ------------------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------------------

preflight() {
    (( EUID == 0 )) || die "Run this script as root."
    [[ -t 0 ]] || die "This script requires an interactive terminal."
    [[ -f $FSTAB ]] || die "$FSTAB does not exist."

    local cmd

    for cmd in \
        awk chmod fallocate findmnt grep mkswap swapon sysctl
    do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    check_existing_swap
    check_root_filesystem
}

check_existing_swap() {
    if swapon --show --noheadings | grep -q .; then
        echo
        echo "Active swap is already configured:"
        echo
        swapon --show
        echo
        die "Existing active swap was detected."
    fi

    if awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        $3 == "swap" { found = 1 }
        END { exit !found }
    ' "$FSTAB"
    then
        die "$FSTAB already contains a swap configuration."
    fi

    [[ ! -e $SWAPFILE ]] || die "$SWAPFILE already exists."
}

check_root_filesystem() {
    local root_fs

    root_fs=$(findmnt -n -o FSTYPE /)

    case "$root_fs" in
        ext4|xfs)
            ;;
        *)
            die "Unsupported root filesystem for automatic swapfile creation: $root_fs"
            ;;
    esac
}


# ------------------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------------------

prompt_swap_size() {
    local input

    while true; do
        read -r -p "Swap size in GiB [$DEFAULT_SWAP_GIB]: " input
        input=${input:-$DEFAULT_SWAP_GIB}

        if [[ $input =~ ^[1-9][0-9]*$ ]]; then
            SWAP_GIB=$input
            return 0
        fi

        echo "Enter a positive whole number of GiB."
    done
}

create_swapfile() {
    echo
    echo "Creating ${SWAP_GIB} GiB swap file at $SWAPFILE..."

    fallocate -l "${SWAP_GIB}G" "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"
}

configure_fstab() {
    printf '%s\n' \
        '' \
        '# swapfile' \
        '/swapfile none swap sw 0 0' \
        >> "$FSTAB"
}

configure_swappiness() {
    printf '%s\n' "vm.swappiness=$SWAPPINESS" > "$SWAPPINESS_CONF"
    sysctl "vm.swappiness=$SWAPPINESS"
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    preflight
    prompt_swap_size

    create_swapfile
    configure_fstab
    configure_swappiness

    echo
    echo "Swap configuration complete."
    echo

    swapon --show

    echo
    free -h

    echo
    printf 'Swappiness: '
    sysctl -n vm.swappiness
}

main "$@"
