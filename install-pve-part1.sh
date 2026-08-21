#!/bin/bash

# Quick start:
# curl -fsSLO https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/install-pve-part1.sh && bash install-pve-part1.sh

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        install-pve-part1.sh
# Revision:    r3
# Modified:    2026-08-21
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/proxmox-debian-install/blob/main/install-pve-part1.sh
# Description: Performs the first stage of installing Proxmox VE 9 on a supported Debian 13
#              (Trixie) system. Verifies the platform, static IPv4/hostname configuration,
#              installs the Proxmox repository key and pve-no-subscription repository,
#              upgrades Debian, installs the Proxmox default kernel, and optionally reboots.
#
# Requirements:
#              apt
#              bash
#              coreutils
#              dpkg
#              findutils
#              grep
#              iproute2
#              libc-bin
#              systemd
#              wget
#
# Output:
#              /usr/share/keyrings/proxmox-archive-keyring.gpg
#              /etc/apt/sources.list.d/proxmox.sources
#              Proxmox default kernel packages
#
# Notes:
#              This script is intended specifically for Proxmox VE 9 installations on
#              Debian 13 (Trixie). The host must already have a persistent static IPv4
#              configuration and a correct non-loopback hostname mapping in /etc/hosts.
#
#              A reboot into the Proxmox kernel is required before running installation
#              stage 2.
# ------------------------------------------------------------------------------------------

set -euo pipefail

PVE_REPO=/etc/apt/sources.list.d/proxmox.sources
KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg
KEY_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
KEY_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45
INTERFACES=/etc/network/interfaces
HOSTS=/etc/hosts

DEFAULT_IFACE=""
LOCAL_IPV4=""
HOST_SHORT=""
HOST_FQDN=""
HOSTS_IPV4=""
KEY_TMP=""


die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

yesno() {
    local prompt=$1
    local default=${2:-N}
    local answer

    if [[ $default == Y ]]; then
        read -r -p "$prompt [Y/n] " answer
        [[ -z $answer || $answer =~ ^[Yy]$ ]]
    else
        read -r -p "$prompt [y/N] " answer
        [[ $answer =~ ^[Yy]$ ]]
    fi
}

cleanup() {
    if [[ -n $KEY_TMP && -e $KEY_TMP ]]; then
        rm -f "$KEY_TMP"
    fi
}

trap cleanup EXIT


# ------------------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------------------

check_requirements() {
    local cmd

    (( EUID == 0 )) || die "Run this script as root."
    [[ -t 0 ]] || die "This script requires an interactive terminal."

    for cmd in \
        apt-get awk dpkg-query find getent grep hostname install ip mktemp rm sed sha256sum \
        sort systemctl uname wget
    do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    [[ -f $HOSTS ]] || die "$HOSTS does not exist."
    [[ -f $INTERFACES ]] || die "$INTERFACES does not exist."
}

check_platform() {
    [[ -r /etc/os-release ]] || die "/etc/os-release was not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ ${ID:-} == debian ]] ||
        die "This script requires Debian 13 (Trixie); detected ID='${ID:-unknown}'."

    [[ ${VERSION_ID:-} == 13 ]] ||
        die "This script requires Debian 13 (Trixie); detected VERSION_ID='${VERSION_ID:-unknown}'."

    [[ ${VERSION_CODENAME:-} == trixie ]] ||
        die "This script requires Debian 13 (Trixie); detected codename='${VERSION_CODENAME:-unknown}'."

    echo "Platform: Debian 13 (Trixie)"
}

interface_has_static_config() {
    local iface=$1
    local -a files=("$INTERFACES")
    local file

    if [[ -d /etc/network/interfaces.d ]]; then
        while IFS= read -r file; do
            files+=("$file")
        done < <(
            find /etc/network/interfaces.d -maxdepth 1 \
                \( -type f -o -type l \) -print 2>/dev/null | sort
        )
    fi

    awk -v iface="$iface" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        $1 == "iface" && $2 == iface && $3 == "inet" && $4 == "static" { found = 1 }
        END { exit !found }
    ' "${files[@]}"
}

hosts_has_loopback_hostname() {
    awk -v short="$HOST_SHORT" -v fqdn="$HOST_FQDN" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        $1 ~ /^127\./ {
            for (i = 2; i <= NF; i++) {
                if ($i == short || $i == fqdn) {
                    found = 1
                }
            }
        }
        END { exit !found }
    ' "$HOSTS"
}

find_hosts_ipv4() {
    awk -v short="$HOST_SHORT" -v fqdn="$HOST_FQDN" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $1 !~ /^127\./ {
            have_short = 0
            have_fqdn = 0

            for (i = 2; i <= NF; i++) {
                if ($i == short) have_short = 1
                if ($i == fqdn) have_fqdn = 1
            }

            if (have_short && have_fqdn) {
                print $1
                exit
            }
        }
    ' "$HOSTS"
}

check_network_and_hostname() {
    local resolved_ipv4

    DEFAULT_IFACE=$(ip -4 route show default | awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ')

    [[ -n $DEFAULT_IFACE ]] || die "No IPv4 default-route interface was detected."

    LOCAL_IPV4=$(ip -4 -o addr show dev "$DEFAULT_IFACE" scope global | awk '
        NR == 1 {
            split($4, address, "/")
            print address[1]
        }
    ')

    [[ -n $LOCAL_IPV4 ]] ||
        die "No global IPv4 address is assigned to $DEFAULT_IFACE."

    interface_has_static_config "$DEFAULT_IFACE" ||
        die "$DEFAULT_IFACE is not configured with an 'inet static' stanza in /etc/network/interfaces or /etc/network/interfaces.d/."

    HOST_SHORT=$(hostname --short 2>/dev/null || true)
    HOST_FQDN=$(hostname --fqdn 2>/dev/null || true)

    [[ -n $HOST_SHORT ]] || die "Unable to determine the system hostname."
    [[ -n $HOST_FQDN ]] || die "Unable to determine the system FQDN."
    [[ $HOST_FQDN == *.* ]] ||
        die "Hostname '$HOST_FQDN' is not a fully qualified domain name."

    if hosts_has_loopback_hostname; then
        die "$HOST_SHORT/$HOST_FQDN is still mapped to a loopback IPv4 address in $HOSTS."
    fi

    HOSTS_IPV4=$(find_hosts_ipv4)

    [[ -n $HOSTS_IPV4 ]] ||
        die "$HOSTS does not contain an active non-loopback IPv4 entry containing both '$HOST_FQDN' and '$HOST_SHORT'."

    [[ $HOSTS_IPV4 == "$LOCAL_IPV4" ]] ||
        die "$HOSTS maps $HOST_FQDN to $HOSTS_IPV4, but $DEFAULT_IFACE is using $LOCAL_IPV4."

    resolved_ipv4=$(getent ahostsv4 "$HOST_FQDN" 2>/dev/null | awk '{ print $1 }' | sort -u || true)

    grep -Fxq "$HOSTS_IPV4" <<< "$resolved_ipv4" ||
        die "$HOST_FQDN does not resolve to its configured local IPv4 address $HOSTS_IPV4."

    echo
    echo "Network/hostname preflight passed:"
    echo
    printf '  Hostname:   %s\n' "$HOST_SHORT"
    printf '  FQDN:       %s\n' "$HOST_FQDN"
    printf '  Interface:  %s\n' "$DEFAULT_IFACE"
    printf '  IPv4:       %s\n' "$LOCAL_IPV4"
    printf '  Hosts map:  %s  %s %s\n' "$HOSTS_IPV4" "$HOST_FQDN" "$HOST_SHORT"
}

check_preflight() {
    check_requirements
    check_platform
    check_network_and_hostname
}


# ------------------------------------------------------------------------------------------
# Proxmox repository
# ------------------------------------------------------------------------------------------

proxmox_keyring_package_installed() {
    dpkg-query -W -f='${Status}\n' proxmox-archive-keyring 2>/dev/null |
        grep -Fxq 'install ok installed'
}

install_proxmox_keyring() {
    local actual_sha256

    echo

    if proxmox_keyring_package_installed; then
        [[ -f $KEYRING ]] ||
            die "proxmox-archive-keyring is installed, but $KEYRING is missing."

        echo "Proxmox archive keyring is already managed by the proxmox-archive-keyring package."
        echo "Leaving the existing keyring unchanged."
        return 0
    fi

    KEY_TMP=$(mktemp)

    echo "Downloading Proxmox archive keyring..."
    wget -q "$KEY_URL" -O "$KEY_TMP" ||
        die "Failed to download the Proxmox archive keyring."

    actual_sha256=$(sha256sum "$KEY_TMP" | awk '{ print $1 }')

    if [[ $actual_sha256 != "$KEY_SHA256" ]]; then
        die "Proxmox archive keyring SHA256 verification failed. Expected $KEY_SHA256, got $actual_sha256."
    fi

    echo "Proxmox archive keyring SHA256 verification passed."

    install -m 0644 "$KEY_TMP" "$KEYRING"
    rm -f "$KEY_TMP"
    KEY_TMP=""
}

configure_proxmox_repository() {
    echo
    echo "Configuring Proxmox VE no-subscription repository..."

    printf '%s\n' \
        'Types: deb' \
        'URIs: http://download.proxmox.com/debian/pve' \
        'Suites: trixie' \
        'Components: pve-no-subscription' \
        'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
        > "$PVE_REPO"

    echo
    echo "$PVE_REPO:"
    echo
    sed 's/^/  /' "$PVE_REPO"
}


# ------------------------------------------------------------------------------------------
# Package installation
# ------------------------------------------------------------------------------------------

install_pve_kernel() {
    echo
    echo "Updating package indexes..."
    apt-get update

    echo
    echo "Upgrading Debian packages..."
    apt-get -y dist-upgrade

    echo
    echo "Installing Proxmox default kernel..."
    apt-get install -y proxmox-default-kernel

    if ! dpkg-query -W -f='${Status}\n' proxmox-default-kernel 2>/dev/null |
        grep -Fxq 'install ok installed'
    then
        die "proxmox-default-kernel does not appear to be installed successfully."
    fi

    echo
    echo "Proxmox default kernel installed successfully."
    printf 'Currently running kernel: %s\n' "$(uname -r)"
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    check_preflight
    install_proxmox_keyring
    configure_proxmox_repository
    install_pve_kernel

    echo
    echo "Proxmox VE installation stage 1 is complete."
    echo
    echo "A reboot is required to start the Proxmox kernel before running stage 2."
    echo

    if yesno "Reboot now?" Y; then
        systemctl reboot
    else
        echo
        echo "Reboot the system before running install-pve-part2.sh."
    fi
}

main "$@"
