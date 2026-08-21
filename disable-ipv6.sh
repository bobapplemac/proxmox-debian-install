#!/bin/bash

# Quick start:
# curl -fsSLO https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/disable-ipv6.sh && bash disable-ipv6.sh

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        disable-ipv6.sh
# Revision:    r3
# Modified:    2026-08-20
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/proxmox-debian-install/blob/main/disable-ipv6.sh
# Description: Disables IPv6 system-wide using persistent sysctl settings and comments the
#              standard Debian IPv6 entries in /etc/hosts.
#
# Requirements:
#              bash
#              procps
#              sed
#
# Output:
#              /etc/sysctl.d/99-disable-ipv6.conf
#              /etc/hosts
#
# Notes:
#              The sysctl configuration file is rewritten on each run, preventing duplicate
#              entries from accumulating. Only active /etc/hosts entries beginning with ::1,
#              ff02::1, or ff02::2 are commented, making the hosts-file change idempotent.
# ------------------------------------------------------------------------------------------

set -euo pipefail

SYSCTL_CONF=/etc/sysctl.d/99-disable-ipv6.conf
HOSTS=/etc/hosts


die() {
    echo "ERROR: $*" >&2
    exit 1
}


# ------------------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------------------

preflight() {
    (( EUID == 0 )) || die "Run this script as root."
    [[ -d /etc/sysctl.d ]] || die "/etc/sysctl.d does not exist."
    [[ -f $HOSTS ]] || die "$HOSTS does not exist."

    local cmd

    for cmd in sed sysctl; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done
}


# ------------------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------------------

configure_ipv6() {
    printf '%s\n' \
        '# IPv6 disabled by disable-ipv6.sh' \
        'net.ipv6.conf.all.disable_ipv6 = 1' \
        'net.ipv6.conf.default.disable_ipv6 = 1' \
        > "$SYSCTL_CONF"

    sysctl -p "$SYSCTL_CONF"
}

comment_ipv6_hosts() {
    sed -E -i \
        '/^[[:space:]]*(::1|ff02::1|ff02::2)([[:space:]]|$)/ s/^([[:space:]]*)/\1# /' \
        "$HOSTS"
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    preflight
    configure_ipv6
    comment_ipv6_hosts

    echo
    echo "IPv6 configuration complete."
    echo
    printf '  all.disable_ipv6:     '
    sysctl -n net.ipv6.conf.all.disable_ipv6
    printf '  default.disable_ipv6: '
    sysctl -n net.ipv6.conf.default.disable_ipv6
}

main "$@"
