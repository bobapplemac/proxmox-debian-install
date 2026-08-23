#!/bin/bash

# Quick start:
# curl -fsSLO https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/install-pve-part2.sh && bash install-pve-part2.sh

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        install-pve-part2.sh
# Revision:    r6
# Modified:    2026-08-22
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/proxmox-debian-install/blob/main/install-pve-part2.sh
# Description: Performs the second stage of installing Proxmox VE 9 on a supported Debian 13
#              (Trixie) system after rebooting into the Proxmox kernel. Installs the Proxmox VE
#              package set, configures Postfix for local-only delivery, maintains the removable
#              UEFI GRUB fallback loader when present, disables the custom login-banner service,
#              installs ifupdown2, enables Chrony and KSM tuning, disables Proxmox enterprise
#              repositories when present,
#              removes the Debian kernel and os-prober, enables periodic filesystem trimming, creates
#              /mnt/local as a symlink to /var/lib/vz, verifies the installation, and optionally
#              reboots.
#
# Requirements:
#              apt
#              bash
#              coreutils
#              debconf
#              dpkg
#              grep
#              iproute2
#              libc-bin
#              sed
#              systemd
#              util-linux
#
# Input:
#              Proxmox VE stage 1 must already be complete and the system must be running a
#              Proxmox '-pve' kernel.
#
# Output:
#              Proxmox VE packages and services
#              Postfix configured for local-only delivery
#              Chrony enabled
#              ifupdown2 installed
#              ksmtuned enabled and active
#              Removable UEFI GRUB fallback loader maintained when present
#              update-login-banner.service disabled when present
#              Proxmox enterprise repositories disabled when present
#              Debian stock kernel packages removed
#              os-prober removed
#              fstrim.timer enabled
#              /mnt/local -> /var/lib/vz
#
# Notes:
#              This script is intended specifically for Proxmox VE 9 installations on
#              Debian 13 (Trixie). Run install-pve-part1.sh and reboot into the Proxmox
#              kernel before running this script.
# ------------------------------------------------------------------------------------------

set -euo pipefail

PVE_REPO=/etc/apt/sources.list.d/proxmox.sources
PVE_ENTERPRISE_SOURCES=/etc/apt/sources.list.d/pve-enterprise.sources
PVE_ENTERPRISE_LIST=/etc/apt/sources.list.d/pve-enterprise.list
CEPH_SOURCES=/etc/apt/sources.list.d/ceph.sources
CEPH_LIST=/etc/apt/sources.list.d/ceph.list
HOSTS=/etc/hosts
VZ_PATH=/var/lib/vz
LOCAL_LINK=/mnt/local
EFI_REMOVABLE_BOOTLOADER=/boot/efi/EFI/BOOT/BOOTX64.efi

HOST_SHORT=""
HOST_FQDN=""
HOSTS_IPV4=""
POSTFIX_MAILNAME=""
GRUB_REMOVABLE_REINSTALL=0


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

package_installed() {
    dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null |
        grep -Fxq 'install ok installed'
}


# ------------------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------------------

check_requirements() {
    local cmd

    (( EUID == 0 )) || die "Run this script as root."
    [[ -t 0 ]] || die "This script requires an interactive terminal."

    for cmd in \
        apt-get awk debconf-set-selections debconf-show dpkg-query findmnt getent grep hostname \
        ip ln mkdir readlink sed sort systemctl uname update-grub
    do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    [[ -f $HOSTS ]] || die "$HOSTS does not exist."
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

check_pve_kernel() {
    local kernel

    kernel=$(uname -r)

    [[ $kernel == *-pve ]] || {
        echo
        die "The running kernel is '$kernel', not a Proxmox '-pve' kernel. Reboot after stage 1 before continuing."
    }

    echo "Running kernel: $kernel"
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
    local local_ipv4

    HOST_SHORT=$(hostname --short 2>/dev/null || true)
    HOST_FQDN=$(hostname --fqdn 2>/dev/null || true)

    [[ -n $HOST_SHORT ]] || die "Unable to determine the system hostname."
    [[ -n $HOST_FQDN ]] || die "Unable to determine the system FQDN."
    [[ $HOST_FQDN == *.* ]] ||
        die "Hostname '$HOST_FQDN' is not a fully qualified domain name."

    if hosts_has_loopback_hostname; then
        die "$HOST_SHORT/$HOST_FQDN is mapped to a loopback IPv4 address in $HOSTS."
    fi

    HOSTS_IPV4=$(find_hosts_ipv4)

    [[ -n $HOSTS_IPV4 ]] ||
        die "$HOSTS does not contain an active non-loopback IPv4 entry containing both '$HOST_FQDN' and '$HOST_SHORT'."

    local_ipv4=$(ip -4 -o addr show scope global | awk '
        {
            split($4, address, "/")
            print address[1]
        }
    ')

    grep -Fxq "$HOSTS_IPV4" <<< "$local_ipv4" ||
        die "$HOSTS maps $HOST_FQDN to $HOSTS_IPV4, but that address is not assigned locally."

    resolved_ipv4=$(getent ahostsv4 "$HOST_FQDN" 2>/dev/null | awk '{ print $1 }' | sort -u || true)

    grep -Fxq "$HOSTS_IPV4" <<< "$resolved_ipv4" ||
        die "$HOST_FQDN does not resolve to its configured local IPv4 address $HOSTS_IPV4."

    echo
    echo "Network/hostname preflight passed:"
    echo
    printf '  Hostname:   %s\n' "$HOST_SHORT"
    printf '  FQDN:       %s\n' "$HOST_FQDN"
    printf '  IPv4:       %s\n' "$HOSTS_IPV4"
    printf '  Hosts map:  %s  %s %s\n' "$HOSTS_IPV4" "$HOST_FQDN" "$HOST_SHORT"
}

check_repository() {
    [[ -f $PVE_REPO ]] ||
        die "$PVE_REPO was not found. Run install-pve-part1.sh before this script."

    grep -Eq '^Suites:[[:space:]]+trixie([[:space:]]|$)' "$PVE_REPO" ||
        die "$PVE_REPO does not contain the expected Trixie suite."

    grep -Eq '^Components:[[:space:]].*\bpve-no-subscription\b' "$PVE_REPO" ||
        die "$PVE_REPO does not contain the expected pve-no-subscription component."

    echo
    echo "Proxmox repository: $PVE_REPO"
}

check_preflight() {
    check_requirements
    check_platform
    check_pve_kernel
    check_network_and_hostname
    check_repository
}


# ------------------------------------------------------------------------------------------
# Local system and bootloader preparation
# ------------------------------------------------------------------------------------------

disable_login_banner_service() {
    echo

    if systemctl list-unit-files update-login-banner.service --no-legend 2>/dev/null |
        awk '$1 == "update-login-banner.service" { found = 1 } END { exit !found }'
    then
        echo "Disabling and stopping update-login-banner.service..."
        systemctl disable --now update-login-banner.service
    else
        echo "update-login-banner.service was not found; nothing to disable."
    fi

    if [[ -e /run/issue.d/50-network.issue ]]; then
        echo "Removing generated login banner..."
        rm -f /run/issue.d/50-network.issue
    fi
}

grub_removable_updates_enabled() {
    debconf-show --db configdb grub-efi-amd64 grub-pc 2>/dev/null |
        grep -Eq 'grub2/force_efi_extra_removable:[[:space:]]+true$'
}

prepare_grub_removable_bootloader() {
    echo

    if [[ ! -d /sys/firmware/efi ]]; then
        echo "System is not running in UEFI mode; no removable EFI bootloader handling is required."
        return 0
    fi

    if [[ ! -f $EFI_REMOVABLE_BOOTLOADER ]]; then
        echo "No removable EFI bootloader was found; nothing to configure."
        return 0
    fi

    findmnt -rn -M /boot/efi >/dev/null 2>&1 ||
        die "$EFI_REMOVABLE_BOOTLOADER exists, but /boot/efi is not a mounted filesystem."

    package_installed grub-efi-amd64 ||
        die "$EFI_REMOVABLE_BOOTLOADER exists, but grub-efi-amd64 is not installed. Repair GRUB before continuing."

    if grub_removable_updates_enabled; then
        echo "GRUB is already configured to maintain the removable EFI bootloader."
        return 0
    fi

    echo "Configuring GRUB to maintain the removable EFI bootloader:"
    echo "  $EFI_REMOVABLE_BOOTLOADER"

    printf '%s\n' \
        'grub-efi-amd64 grub2/force_efi_extra_removable boolean true' \
        | debconf-set-selections -v -u

    GRUB_REMOVABLE_REINSTALL=1
}

refresh_grub_removable_bootloader() {
    (( GRUB_REMOVABLE_REINSTALL )) || return 0

    echo
    echo "Reinstalling grub-efi-amd64 to refresh the removable EFI bootloader..."

    DEBIAN_FRONTEND=noninteractive \
        apt-get install --reinstall -y grub-efi-amd64

    grub_removable_updates_enabled ||
        die "GRUB removable-bootloader maintenance is not enabled after reinstalling grub-efi-amd64."

    [[ -f $EFI_REMOVABLE_BOOTLOADER ]] ||
        die "Expected removable EFI bootloader $EFI_REMOVABLE_BOOTLOADER was not found after reinstalling GRUB."

    echo "GRUB removable EFI bootloader maintenance is enabled."
}


# ------------------------------------------------------------------------------------------
# Proxmox VE package installation
# ------------------------------------------------------------------------------------------

determine_postfix_mailname() {
    if [[ -s /etc/mailname ]]; then
        POSTFIX_MAILNAME=$(awk 'NF { print; exit }' /etc/mailname)
    else
        POSTFIX_MAILNAME=$HOST_FQDN
    fi

    [[ -n $POSTFIX_MAILNAME ]] ||
        die "Unable to determine the Postfix system mail name."
}

preseed_postfix() {
    determine_postfix_mailname

    echo
    echo "Preconfiguring Postfix:"
    echo
    echo "  Configuration:    Local only"
    printf '  System mail name: %s\n' "$POSTFIX_MAILNAME"

    printf '%s\n' \
        'postfix postfix/main_mailer_type select Local only' \
        "postfix postfix/mailname string $POSTFIX_MAILNAME" \
        | debconf-set-selections
}

install_proxmox_ve() {
    echo
    echo "Updating package indexes..."
    apt-get update

    preseed_postfix

    echo
    echo "Installing Proxmox VE packages..."

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y \
            proxmox-ve \
            postfix \
            open-iscsi \
            chrony \
            openvswitch-switch \
            ifupdown2 \
            ksmtuned

    package_installed proxmox-ve ||
        die "proxmox-ve does not appear to be installed successfully."

    package_installed ifupdown2 ||
        die "ifupdown2 does not appear to be installed successfully."

    package_installed ksmtuned ||
        die "ksmtuned does not appear to be installed successfully."

    command -v pveversion >/dev/null 2>&1 ||
        die "pveversion was not found after installing proxmox-ve."

    echo
    echo "Proxmox VE packages installed successfully."
    pveversion
}


# ------------------------------------------------------------------------------------------
# Repository and time-service configuration
# ------------------------------------------------------------------------------------------

disable_deb822_enterprise_source() {
    local file=$1
    local description=$2

    [[ -f $file ]] || return 0

    if ! grep -Eq '^[[:space:]]*URIs:[[:space:]]*https?://enterprise\.proxmox\.com/' "$file"; then
        echo "$description does not reference the Proxmox enterprise repository; leaving it unchanged."
        return 0
    fi

    if grep -Eq '^[[:space:]]*Enabled:' "$file"; then
        sed -E -i 's/^[[:space:]]*Enabled:.*/Enabled: no/' "$file"
    else
        printf '%s\n' 'Enabled: no' >> "$file"
    fi

    echo "Disabled $description: $file"
}

disable_legacy_enterprise_source() {
    local file=$1
    local description=$2

    [[ -f $file ]] || return 0

    if grep -Eq '^[[:space:]]*deb[[:space:]].*enterprise\.proxmox\.com/' "$file"; then
        sed -E -i \
            's|^([[:space:]]*)(deb[[:space:]].*enterprise\.proxmox\.com/.*)$|\1# \2|' \
            "$file"
        echo "Disabled $description: $file"
    fi
}

disable_enterprise_repositories() {
    echo
    echo "Disabling Proxmox enterprise repositories when present..."

    disable_deb822_enterprise_source "$PVE_ENTERPRISE_SOURCES" "PVE enterprise repository"
    disable_legacy_enterprise_source "$PVE_ENTERPRISE_LIST" "legacy PVE enterprise repository"

    # PVE 9 may also install a default Ceph enterprise source. Leave the file available for
    # later Proxmox storage configuration, but disable the subscription-only stanza for now.
    disable_deb822_enterprise_source "$CEPH_SOURCES" "Ceph enterprise repository"
    disable_legacy_enterprise_source "$CEPH_LIST" "legacy Ceph enterprise repository"

    echo
    echo "Refreshing package indexes with the resulting repository configuration..."
    apt-get update
}

configure_time_service() {
    echo
    echo "Configuring time synchronization..."

    if systemctl list-unit-files systemd-timesyncd.service --no-legend 2>/dev/null |
        awk '$1 == "systemd-timesyncd.service" { found = 1 } END { exit !found }'
    then
        if systemctl is-enabled --quiet systemd-timesyncd.service 2>/dev/null ||
           systemctl is-active --quiet systemd-timesyncd.service 2>/dev/null
        then
            echo "Disabling systemd-timesyncd.service..."
            systemctl disable --now systemd-timesyncd.service
        else
            echo "systemd-timesyncd.service is already disabled/inactive."
        fi
    else
        echo "systemd-timesyncd.service was not found; nothing to disable."
    fi

    systemctl enable --now chrony.service
    systemctl is-active --quiet chrony.service ||
        die "chrony.service is not active after enabling it."

    echo "chrony.service is enabled and active."
}


enable_ksmtuned() {
    echo
    echo "Enabling Kernel Samepage Merging tuning..."

    package_installed ksmtuned ||
        die "ksmtuned is not installed."

    systemctl enable --now ksmtuned.service

    systemctl is-enabled --quiet ksmtuned.service ||
        die "ksmtuned.service is not enabled."

    systemctl is-active --quiet ksmtuned.service ||
        die "ksmtuned.service is not active."

    echo "ksmtuned.service is enabled and active."
}


# ------------------------------------------------------------------------------------------
# Debian kernel cleanup
# ------------------------------------------------------------------------------------------

find_debian_kernel_packages() {
    dpkg-query -W -f='${binary:Package} ${db:Status-Abbrev}\n' 'linux-image-*' 2>/dev/null |
        awk '
            $2 ~ /^ii/ &&
            ($1 == "linux-image-amd64" || $1 ~ /^linux-image-6\.12/) {
                print $1
            }
        ' || true
}

remove_debian_kernel() {
    local -a packages=()
    local simulation

    mapfile -t packages < <(find_debian_kernel_packages)

    echo

    if (( ${#packages[@]} == 0 )); then
        echo "No installed Debian linux-image-amd64 or linux-image-6.12* packages were found."
    else
        echo "Debian kernel packages selected for removal:"
        echo
        printf '  %s\n' "${packages[@]}"

        simulation=$(apt-get -s remove "${packages[@]}")

        if grep -Eq '^Remv (proxmox-ve|proxmox-default-kernel|proxmox-kernel-|pve-kernel-)' <<< "$simulation"; then
            echo
            printf '%s\n' "$simulation"
            echo
            die "APT simulation indicates that Proxmox VE or a Proxmox kernel would be removed."
        fi

        echo
        echo "Removing Debian kernel packages..."
        DEBIAN_FRONTEND=noninteractive apt-get remove -y "${packages[@]}"
    fi

    echo
    echo "Updating bootloader configuration..."
    update-grub
}

remove_os_prober() {
    echo

    if package_installed os-prober; then
        echo "Removing os-prober..."
        DEBIAN_FRONTEND=noninteractive apt-get remove -y os-prober
    else
        echo "os-prober is not installed."
    fi
}


# ------------------------------------------------------------------------------------------
# Final host configuration
# ------------------------------------------------------------------------------------------

enable_fstrim() {
    echo
    echo "Enabling periodic filesystem trimming..."
    systemctl enable --now fstrim.timer

    systemctl is-enabled --quiet fstrim.timer ||
        die "fstrim.timer is not enabled."
}

configure_local_symlink() {
    local target

    echo
    echo "Configuring $LOCAL_LINK -> $VZ_PATH..."

    [[ -d $VZ_PATH ]] ||
        die "$VZ_PATH does not exist after Proxmox VE installation."

    mkdir -p /mnt

    if [[ -L $LOCAL_LINK ]]; then
        target=$(readlink -f "$LOCAL_LINK" 2>/dev/null || true)

        [[ $target == "$VZ_PATH" ]] ||
            die "$LOCAL_LINK already points to '$target' instead of '$VZ_PATH'."

        echo "$LOCAL_LINK already points to $VZ_PATH."
        return 0
    fi

    [[ ! -e $LOCAL_LINK ]] ||
        die "$LOCAL_LINK already exists and is not the expected symlink."

    ln -s "$VZ_PATH" "$LOCAL_LINK"
    echo "Created $LOCAL_LINK -> $VZ_PATH."
}

verify_installation() {
    local kernel
    local link_target

    kernel=$(uname -r)
    link_target=$(readlink -f "$LOCAL_LINK" 2>/dev/null || true)

    [[ $kernel == *-pve ]] ||
        die "Verification failed: running kernel '$kernel' is not a PVE kernel."

    package_installed proxmox-ve ||
        die "Verification failed: proxmox-ve is not installed."

    package_installed ifupdown2 ||
        die "Verification failed: ifupdown2 is not installed."

    package_installed ksmtuned ||
        die "Verification failed: ksmtuned is not installed."

    systemctl is-active --quiet chrony.service ||
        die "Verification failed: chrony.service is not active."

    systemctl is-enabled --quiet ksmtuned.service ||
        die "Verification failed: ksmtuned.service is not enabled."

    systemctl is-active --quiet ksmtuned.service ||
        die "Verification failed: ksmtuned.service is not active."

    systemctl is-enabled --quiet fstrim.timer ||
        die "Verification failed: fstrim.timer is not enabled."

    [[ $link_target == "$VZ_PATH" ]] ||
        die "Verification failed: $LOCAL_LINK does not resolve to $VZ_PATH."

    echo
    echo "Proxmox VE installation verification:"
    echo
    printf '  Kernel:      %s\n' "$kernel"
    printf '  Version:     %s\n' "$(pveversion)"
    printf '  Chrony:      %s\n' "$(systemctl is-active chrony.service)"
    printf '  ifupdown2:   installed\n'
    printf '  KSM tuning:  %s\n' "$(systemctl is-active ksmtuned.service)"
    printf '  fstrim:      %s\n' "$(systemctl is-enabled fstrim.timer)"
    printf '  Local link:  %s -> %s\n' "$LOCAL_LINK" "$link_target"
    printf '  Web UI:      https://%s:8006\n' "$HOSTS_IPV4"
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    check_preflight
    disable_login_banner_service
    prepare_grub_removable_bootloader
    install_proxmox_ve
    disable_enterprise_repositories
    refresh_grub_removable_bootloader
    configure_time_service
    enable_ksmtuned
    remove_debian_kernel
    remove_os_prober
    enable_fstrim
    configure_local_symlink
    verify_installation

    echo
    echo "Proxmox VE installation stage 2 is complete."
    echo
    echo "A final reboot is recommended before putting this host into service."
    echo

    if yesno "Reboot now?" Y; then
        systemctl reboot
    else
        echo
        echo "Reboot the system when convenient to complete the installation."
    fi
}

main "$@"
