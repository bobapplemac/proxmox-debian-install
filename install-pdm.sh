#!/bin/bash

# Quick start:
# curl -fsSLO https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/install-pdm.sh && bash install-pdm.sh

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        install-pdm.sh
# Revision:    r7
# Modified:    2026-08-21
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/proxmox-debian-install/blob/main/install-pdm.sh
# Description: Installs Proxmox Datacenter Manager 1 on a supported Debian 13 (Trixie) system.
#              The script validates that the host already has a persistent static IPv4
#              configuration in /etc/network/interfaces and that /etc/hosts maps both the
#              system FQDN and short hostname to that static address.
#
#              Containers are not supported. Virtual machines receive the minimal proxmox-datacenter-manager-container-meta package and
#              retain the Debian kernel. Bare-metal systems receive proxmox-datacenter-manager-meta,
#              which includes the Proxmox kernel and ZFS support.
#
#              The pdm-no-subscription repository is configured using Debian deb822 syntax and
#              the Proxmox Trixie archive key is verified by SHA256 and MD5 before installation. Any PDM
#              enterprise repository created by the packages is disabled after installation.
#
#              This script does not assign or repair the static network configuration. If those
#              prerequisites are not satisfied, use the accompanying ifupdown conversion and/or
#              static-IP setup helpers before running this installer again. During installation,
#              classic ifupdown is intentionally replaced with Proxmox-recommended ifupdown2.
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
#              Proxmox Datacenter Manager packages
#
# Notes:
#              This script is intended for fresh Proxmox Datacenter Manager 1 installations on
#              Debian 13 (Trixie). It intentionally does not convert Netplan, assign a static IP,
#              alter /etc/hosts, install VM guest tools, or configure managed remotes.
#
#              Current Proxmox Datacenter Manager packages recommend ifupdown2. A system beginning with
#              classic Debian ifupdown is intentionally upgraded to ifupdown2 after the static
#              configuration has been validated. The package transition is simulated first and
#              /etc/network/interfaces is verified unchanged after the transition.
#
#              On bare-metal PDM installations, the full Proxmox package set installs the Proxmox
#              kernel. UEFI systems are normalized to the standard grub-efi-amd64 package when
#              necessary, then the removable EFI fallback path is explicitly refreshed with
#              grub-install --removable and verified. The Debian linux-image-amd64 meta-package and
#              os-prober are removed, GRUB is regenerated, and the currently running versioned
#              Debian kernel is deliberately retained until after the first successful -pve boot.
#
#              Normal VM mode installs the container-meta package and retains the Debian kernel. It
#              does not perform GRUB preparation, GRUB installation, kernel cleanup, update-grub,
#              or /boot/EFI verification. --force-bare-metal selects the exact same bare-metal path
#              used on physical hardware so that path can be tested inside a VM.
#
#              For testing, --force-bare-metal or FORCE_BARE_METAL=1 forces the full
#              bare-metal package/kernel/GRUB path even when a virtual machine is detected.
#              OS containers are still rejected.
# ------------------------------------------------------------------------------------------

set -euo pipefail

PDM_REPO=/etc/apt/sources.list.d/proxmox.sources
PDM_ENTERPRISE_SOURCES=/etc/apt/sources.list.d/pdm-enterprise.sources
PDM_ENTERPRISE_LIST=/etc/apt/sources.list.d/pdm-enterprise.list

KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg
KEY_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
KEY_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45
KEY_MD5=77c8b1166d15ce8350102ab1bca2fcbf

INTERFACES=/etc/network/interfaces
INTERFACES_D=/etc/network/interfaces.d
HOSTS=/etc/hosts
EFI_REMOVABLE_BOOTLOADER=/boot/efi/EFI/BOOT/BOOTX64.efi
EFI_REMOVABLE_GRUB=/boot/efi/EFI/BOOT/grubx64.efi
EFI_REMOVABLE_CONFIG=/boot/efi/EFI/BOOT/grub.cfg
EFI_VENDOR_CONFIG=/boot/efi/EFI/debian/grub.cfg

INSTALL_PACKAGE=""
VIRT_TYPE=""
SYSTEM_TYPE=""
SOURCE_NETWORK_STACK=""
DETECTED_SYSTEM_TYPE=""
FORCE_BARE_METAL_REQUESTED=false

DEFAULT_IFACE=""
DEFAULT_GATEWAY=""
LOCAL_ADDRESS=""
LOCAL_IPV4=""
CONFIG_ADDRESS=""
CONFIG_GATEWAY=""
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

usage() {
    printf '%s\n' \
        "Usage: ${0##*/} [--force-bare-metal]" \
        '' \
        'Options:' \
        '  --force-bare-metal  Run the bare-metal package/kernel/GRUB path even when a VM is detected.' \
        '  -h, --help          Show this help text.' \
        '' \
        'Environment:' \
        '  FORCE_BARE_METAL=1  Equivalent to --force-bare-metal.'
}

parse_args() {
    local force_env=${FORCE_BARE_METAL:-}

    case "${force_env,,}" in
        ''|0|false|no|off)
            ;;
        1|true|yes|on)
            FORCE_BARE_METAL_REQUESTED=true
            ;;
        *)
            die "Invalid FORCE_BARE_METAL value '$force_env'. Use 1/true/yes/on or 0/false/no/off."
            ;;
    esac

    while (( $# )); do
        case "$1" in
            --force-bare-metal)
                FORCE_BARE_METAL_REQUESTED=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument '$1'. Use --help for usage."
                ;;
        esac
        shift
    done
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null |
        grep -qx 'install ok installed'
}

cleanup() {
    if [[ -n $KEY_TMP && -e $KEY_TMP ]]; then
        rm -f -- "$KEY_TMP"
    fi
}

trap cleanup EXIT


# ------------------------------------------------------------------------------------------
# Preflight helpers
# ------------------------------------------------------------------------------------------

network_stack_error() {
    echo "ERROR: $*" >&2
    echo >&2
    echo "Proxmox Datacenter Manager installation requires persistent networking to be" >&2
    echo "configured in /etc/network/interfaces before installation." >&2
    echo >&2
    echo "If this is a Netplan/cloud-image system, run the accompanying ifupdown" >&2
    echo "conversion helper first. Then configure and verify a static IPv4 address" >&2
    echo "before running this installer again." >&2
    echo >&2
    echo "Classic ifupdown is acceptable at this stage; this installer will replace" >&2
    echo "it with ifupdown2 as part of the Proxmox Datacenter Manager installation." >&2
    exit 1
}

static_network_error() {
    echo "ERROR: $*" >&2
    echo >&2
    echo "Proxmox Datacenter Manager requires a correctly configured static IPv4 address." >&2
    echo >&2
    echo "The primary network interface must use a static configuration in" >&2
    echo "/etc/network/interfaces, and /etc/hosts must map the system FQDN and" >&2
    echo "short hostname to that same static IPv4 address." >&2
    echo >&2
    echo "Configure the system's static network settings first. If you are using" >&2
    echo "the accompanying Debian setup scripts, run the static-IP setup helper" >&2
    echo "before installing Proxmox Datacenter Manager." >&2
    exit 1
}

check_requirements() {
    local cmd

    (( EUID == 0 )) || die "Run this script as root."
    [[ -t 0 ]] || die "This script requires an interactive terminal."

    for cmd in \
        apt-get awk dpkg dpkg-query find getent grep hostname install \
        ip md5sum mktemp rm sed sha256sum sort systemctl systemd-detect-virt uname wget
    do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    [[ -f $HOSTS ]] || die "$HOSTS does not exist."
}

check_platform() {
    local arch

    [[ -r /etc/os-release ]] || die "/etc/os-release was not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ ${ID:-} == debian ]] ||
        die "This script requires Debian 13 (Trixie); detected ID='${ID:-unknown}'."

    [[ ${VERSION_ID:-} == 13 ]] ||
        die "This script requires Debian 13 (Trixie); detected VERSION_ID='${VERSION_ID:-unknown}'."

    [[ ${VERSION_CODENAME:-} == trixie ]] ||
        die "This script requires Debian 13 (Trixie); detected codename='${VERSION_CODENAME:-unknown}'."

    arch=$(dpkg --print-architecture)
    [[ $arch == amd64 ]] ||
        die "This script requires amd64; detected architecture '$arch'."

    echo "Platform: Debian 13 (Trixie), amd64"
}

check_fresh_install() {
    if package_installed proxmox-datacenter-manager ||
       package_installed proxmox-datacenter-manager-container-meta ||
       package_installed proxmox-datacenter-manager-meta
    then
        die "Proxmox Datacenter Manager packages are already installed. This script is intended for a fresh Debian installation."
    fi
}

check_network_stack() {
    local active_netplan=false
    local have_ifupdown=false
    local have_ifupdown2=false

    [[ -f $INTERFACES ]] ||
        network_stack_error "$INTERFACES does not exist."

    package_installed ifupdown && have_ifupdown=true
    package_installed ifupdown2 && have_ifupdown2=true

    if $have_ifupdown && $have_ifupdown2; then
        network_stack_error "Both ifupdown and ifupdown2 are installed; the networking stack is ambiguous."
    fi

    if ! $have_ifupdown && ! $have_ifupdown2; then
        network_stack_error "Neither ifupdown nor ifupdown2 is installed."
    fi

    if $have_ifupdown2; then
        SOURCE_NETWORK_STACK=ifupdown2
    else
        SOURCE_NETWORK_STACK=ifupdown
    fi

    systemctl is-enabled --quiet networking.service 2>/dev/null ||
        network_stack_error "networking.service is not enabled."

    if systemctl is-enabled --quiet systemd-networkd.service 2>/dev/null; then
        network_stack_error "systemd-networkd.service is still enabled."
    fi

    if systemctl is-active --quiet systemd-networkd.service 2>/dev/null; then
        network_stack_error "systemd-networkd.service is still active. Reboot after completing the ifupdown conversion before installing PDM."
    fi

    if package_installed netplan.io || package_installed netplan-generator; then
        network_stack_error "Netplan runtime packages are still installed."
    fi

    if compgen -G '/etc/netplan/*.yaml' >/dev/null; then
        active_netplan=true
    fi

    if $active_netplan; then
        network_stack_error "Active Netplan YAML configuration still exists under /etc/netplan."
    fi
}

network_config_files() {
    local file

    printf '%s\n' "$INTERFACES"

    if [[ -d $INTERFACES_D ]]; then
        while IFS= read -r file; do
            printf '%s\n' "$file"
        done < <(
            find "$INTERFACES_D" -maxdepth 1 \( -type f -o -type l \) -print 2>/dev/null |
                sort
        )
    fi
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
            }
        }
    ' "$HOSTS" | sort -u
}

check_static_network_and_hostname() {
    local -a default_routes=()
    local -a live_addresses=()
    local -a config_files=()
    local -a config_methods=()
    local -a config_addresses=()
    local -a config_gateways=()
    local -a hosts_addresses=()
    local configured_ipv4
    local resolved_ipv4
    local route

    mapfile -t default_routes < <(ip -4 route show default)

    (( ${#default_routes[@]} == 1 )) ||
        static_network_error "Expected exactly one IPv4 default route; found ${#default_routes[@]}."

    route=${default_routes[0]}

    DEFAULT_IFACE=$(awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' <<< "$route")

    DEFAULT_GATEWAY=$(awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "via" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' <<< "$route")

    [[ -n $DEFAULT_IFACE ]] ||
        static_network_error "The IPv4 default route does not identify an interface."

    [[ -n $DEFAULT_GATEWAY ]] ||
        static_network_error "The IPv4 default route does not identify a gateway."

    mapfile -t live_addresses < <(
        ip -4 -o addr show dev "$DEFAULT_IFACE" scope global 2>/dev/null |
            awk '{ print $4 }'
    )

    (( ${#live_addresses[@]} == 1 )) ||
        static_network_error "Expected exactly one global IPv4 address on $DEFAULT_IFACE; found ${#live_addresses[@]}."

    LOCAL_ADDRESS=${live_addresses[0]}
    LOCAL_IPV4=${LOCAL_ADDRESS%/*}

    mapfile -t config_files < <(network_config_files)

    mapfile -t config_methods < <(
        awk -v iface="$DEFAULT_IFACE" '
            FNR == 1 { selected = 0 }
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            $1 == "iface" {
                selected = ($2 == iface && $3 == "inet")
                if (selected) print $4
                next
            }
        ' "${config_files[@]}"
    )

    (( ${#config_methods[@]} == 1 )) ||
        static_network_error "Expected exactly one IPv4 stanza for $DEFAULT_IFACE in the ifupdown configuration; found ${#config_methods[@]}."

    [[ ${config_methods[0]} == static ]] ||
        static_network_error "$DEFAULT_IFACE is configured as '${config_methods[0]}' instead of 'static'."

    mapfile -t config_addresses < <(
        awk -v iface="$DEFAULT_IFACE" '
            FNR == 1 { selected = 0 }
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            $1 == "iface" {
                selected = ($2 == iface && $3 == "inet")
                next
            }
            selected && $1 == "address" { print $2 }
        ' "${config_files[@]}"
    )

    (( ${#config_addresses[@]} == 1 )) ||
        static_network_error "Expected exactly one static 'address' directive for $DEFAULT_IFACE; found ${#config_addresses[@]}."

    CONFIG_ADDRESS=${config_addresses[0]}
    configured_ipv4=${CONFIG_ADDRESS%/*}

    [[ $configured_ipv4 == "$LOCAL_IPV4" ]] ||
        static_network_error "$DEFAULT_IFACE is configured for $CONFIG_ADDRESS but is currently using $LOCAL_ADDRESS."

    mapfile -t config_gateways < <(
        awk -v iface="$DEFAULT_IFACE" '
            FNR == 1 { selected = 0 }
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            $1 == "iface" {
                selected = ($2 == iface && $3 == "inet")
                next
            }
            selected && $1 == "gateway" { print $2 }
        ' "${config_files[@]}"
    )

    (( ${#config_gateways[@]} == 1 )) ||
        static_network_error "Expected exactly one static 'gateway' directive for $DEFAULT_IFACE; found ${#config_gateways[@]}."

    CONFIG_GATEWAY=${config_gateways[0]}

    [[ $CONFIG_GATEWAY == "$DEFAULT_GATEWAY" ]] ||
        static_network_error "$DEFAULT_IFACE is configured with gateway $CONFIG_GATEWAY but the live default gateway is $DEFAULT_GATEWAY."

    HOST_SHORT=$(hostname --short 2>/dev/null || true)
    HOST_FQDN=$(hostname --fqdn 2>/dev/null || true)

    [[ -n $HOST_SHORT ]] ||
        static_network_error "Unable to determine the system short hostname."

    [[ -n $HOST_FQDN ]] ||
        static_network_error "Unable to determine the system FQDN."

    [[ $HOST_FQDN == *.* ]] ||
        static_network_error "Hostname '$HOST_FQDN' is not a fully qualified domain name."

    if hosts_has_loopback_hostname; then
        static_network_error "$HOST_SHORT/$HOST_FQDN is still mapped to a loopback IPv4 address in $HOSTS."
    fi

    mapfile -t hosts_addresses < <(find_hosts_ipv4)

    (( ${#hosts_addresses[@]} == 1 )) ||
        static_network_error "$HOSTS must contain exactly one active non-loopback IPv4 mapping containing both '$HOST_FQDN' and '$HOST_SHORT'; found ${#hosts_addresses[@]}."

    HOSTS_IPV4=${hosts_addresses[0]}

    [[ $HOSTS_IPV4 == "$LOCAL_IPV4" ]] ||
        static_network_error "$HOSTS maps $HOST_FQDN/$HOST_SHORT to $HOSTS_IPV4, but $DEFAULT_IFACE is using $LOCAL_IPV4."

    resolved_ipv4=$(getent ahostsv4 "$HOST_FQDN" 2>/dev/null | awk '{ print $1 }' | sort -u || true)
    grep -Fxq "$LOCAL_IPV4" <<< "$resolved_ipv4" ||
        static_network_error "$HOST_FQDN does not resolve to its configured local IPv4 address $LOCAL_IPV4."

    resolved_ipv4=$(getent ahostsv4 "$HOST_SHORT" 2>/dev/null | awk '{ print $1 }' | sort -u || true)
    grep -Fxq "$LOCAL_IPV4" <<< "$resolved_ipv4" ||
        static_network_error "$HOST_SHORT does not resolve to its configured local IPv4 address $LOCAL_IPV4."

    echo
    echo "Network prerequisite validation:"
    echo
    if [[ $SOURCE_NETWORK_STACK == ifupdown ]]; then
        printf '  %-20s %s\n' "Network stack:" "ifupdown (will upgrade to ifupdown2)"
    else
        printf '  %-20s %s\n' "Network stack:" "ifupdown2"
    fi
    printf '  %-20s %s\n' "Interface:" "$DEFAULT_IFACE"
    printf '  %-20s %s\n' "Static IPv4:" "$LOCAL_ADDRESS"
    printf '  %-20s %s\n' "Default gateway:" "$DEFAULT_GATEWAY"
    printf '  %-20s %s\n' "Hostname:" "$HOST_SHORT"
    printf '  %-20s %s\n' "FQDN:" "$HOST_FQDN"
    printf '  %-20s %s  %s %s\n' "/etc/hosts mapping:" "$HOSTS_IPV4" "$HOST_FQDN" "$HOST_SHORT"
    echo
    echo "Static network configuration validated successfully."
}

check_virtualization() {
    local detected

    if detected=$(systemd-detect-virt --container 2>/dev/null); then
        die "Container virtualization ('$detected') was detected. This installer supports virtual machines or bare metal, not OS containers."
    fi

    if detected=$(systemd-detect-virt --vm 2>/dev/null); then
        VIRT_TYPE=$detected
        DETECTED_SYSTEM_TYPE="virtual machine"
    else
        VIRT_TYPE=none
        DETECTED_SYSTEM_TYPE="bare metal"
    fi

    if $FORCE_BARE_METAL_REQUESTED; then
        SYSTEM_TYPE="bare metal"
        INSTALL_PACKAGE=proxmox-datacenter-manager-meta
    elif [[ $DETECTED_SYSTEM_TYPE == "virtual machine" ]]; then
        SYSTEM_TYPE="virtual machine"
        INSTALL_PACKAGE=proxmox-datacenter-manager-container-meta
    else
        SYSTEM_TYPE="bare metal"
        INSTALL_PACKAGE=proxmox-datacenter-manager-meta
    fi

    echo
    echo "Installation target:"
    echo
    printf '  %-20s %s\n' "Detected system:" "$DETECTED_SYSTEM_TYPE"
    printf '  %-20s %s\n' "Virtualization:" "$VIRT_TYPE"

    if $FORCE_BARE_METAL_REQUESTED; then
        printf '  %-20s %s\n' "Install mode:" "bare metal (forced)"
    else
        printf '  %-20s %s\n' "Install mode:" "$SYSTEM_TYPE"
    fi

    printf '  %-20s %s\n' "PDM package:" "$INSTALL_PACKAGE"

    if [[ $SYSTEM_TYPE == "virtual machine" ]]; then
        printf '  %-20s %s\n' "Kernel policy:" "retain Debian kernel"
    else
        printf '  %-20s %s\n' "Kernel policy:" "install Proxmox kernel with ZFS support"
    fi

    if $FORCE_BARE_METAL_REQUESTED && [[ $DETECTED_SYSTEM_TYPE == "virtual machine" ]]; then
        echo
        warn "Bare-metal installation mode was forced while VM virtualization '$VIRT_TYPE' was detected."
        warn "The full Proxmox kernel, GRUB, and bare-metal cleanup path will run inside this VM."
    fi
}

check_bare_metal_boot_requirements() {
    [[ $SYSTEM_TYPE == "bare metal" ]] || return 0

    command -v update-grub >/dev/null 2>&1 ||
        die "Required bare-metal bootloader command 'update-grub' was not found."

    if [[ -d /sys/firmware/efi ]]; then
        local cmd

        for cmd in findmnt grub-install; do
            command -v "$cmd" >/dev/null 2>&1 ||
                die "Required UEFI bootloader command '$cmd' was not found."
        done

        findmnt -rn -M /boot/efi >/dev/null 2>&1 ||
            die "System is running in UEFI mode, but /boot/efi is not a mounted filesystem."

        if package_installed grub-cloud-amd64 && package_installed grub-efi-amd64; then
            die "Both grub-cloud-amd64 and grub-efi-amd64 are installed; the active UEFI GRUB layout is ambiguous."
        fi

        if ! package_installed grub-cloud-amd64 && ! package_installed grub-efi-amd64; then
            die "System is running in UEFI mode, but neither grub-cloud-amd64 nor grub-efi-amd64 is installed. Repair GRUB before continuing."
        fi
    fi
}

validate_cloud_grub_setup() {
    local package

    for package in \
        grub-cloud-amd64 \
        grub-efi-amd64-bin \
        grub-efi-amd64-signed \
        grub-pc-bin \
        grub2-common \
        shim-signed
    do
        package_installed "$package" ||
            die "Cloud-image GRUB setup is incomplete: required package '$package' is not installed."
    done

    [[ -f $EFI_REMOVABLE_BOOTLOADER ]] ||
        die "Cloud-image GRUB setup is missing removable EFI loader $EFI_REMOVABLE_BOOTLOADER."

    [[ -f $EFI_REMOVABLE_GRUB ]] ||
        die "Cloud-image GRUB setup is missing removable EFI GRUB image $EFI_REMOVABLE_GRUB."
}

prepare_bare_metal_grub_for_install() {
    [[ $SYSTEM_TYPE == "bare metal" ]] || return 0

    echo

    if [[ ! -d /sys/firmware/efi ]]; then
        echo "System is not running in UEFI mode; no UEFI GRUB preparation is required."
        return 0
    fi

    if package_installed grub-cloud-amd64; then
        local simulation
        local unexpected

        validate_cloud_grub_setup

        echo "Debian cloud-image GRUB configuration detected."
        echo "Normalizing to the standard grub-efi-amd64 package before installing the Proxmox kernel stack."
        echo
        echo "Simulating installation of grub-efi-amd64..."

        simulation=$(apt-get -s install grub-efi-amd64 2>&1) || {
            printf '%s\n' "$simulation" >&2
            die "APT could not simulate installation of grub-efi-amd64."
        }

        printf '%s\n' "$simulation" |
            awk '/^(Inst|Remv|Purg) / { print "  " $0 }'

        if grep -Eq '^Inst grub-pc([[:space:]]|$)' <<< "$simulation"; then
            echo
            die "APT would install grub-pc while normalizing a UEFI system."
        fi

        unexpected=$(printf '%s\n' "$simulation" |
            awk '/^(Remv|Purg) / && $2 != "grub-cloud-amd64" && $2 != "grub-pc" { print $2 }' |
            sort -u)

        if [[ -n $unexpected ]]; then
            echo
            warn "Installing grub-efi-amd64 would remove unexpected packages:"
            printf '  %s\n' $unexpected
            echo
            die "Refusing UEFI GRUB normalization because APT proposed unexpected removals."
        fi

        DEBIAN_FRONTEND=noninteractive apt-get install -y grub-efi-amd64

        package_installed grub-efi-amd64 ||
            die "grub-efi-amd64 was not installed successfully."

        ! package_installed grub-pc ||
            die "grub-pc is installed on this UEFI system after installing grub-efi-amd64."

        if package_installed grub-cloud-amd64; then
            echo
            echo "Simulating removal of grub-cloud-amd64..."

            simulation=$(apt-get -s remove grub-cloud-amd64 2>&1) || {
                printf '%s\n' "$simulation" >&2
                die "APT could not simulate removal of grub-cloud-amd64."
            }

            unexpected=$(printf '%s\n' "$simulation" |
                awk '/^(Remv|Purg) / && $2 != "grub-cloud-amd64" { print $2 }' |
                sort -u)

            if [[ -n $unexpected ]]; then
                echo
                warn "Removing grub-cloud-amd64 would remove additional packages:"
                printf '  %s\n' $unexpected
                echo
                die "Refusing cloud-GRUB cleanup because APT proposed additional removals."
            fi

            DEBIAN_FRONTEND=noninteractive apt-get remove -y grub-cloud-amd64
        fi

        ! package_installed grub-cloud-amd64 ||
            die "grub-cloud-amd64 is still installed after UEFI GRUB normalization."

        package_installed grub-efi-amd64 ||
            die "grub-efi-amd64 is not installed after UEFI GRUB normalization."

        echo "Cloud-image GRUB was normalized successfully to standard UEFI grub-efi-amd64."
        return 0
    fi

    package_installed grub-efi-amd64 ||
        die "UEFI mode is active, but grub-efi-amd64 is not installed. Repair GRUB before continuing."

    ! package_installed grub-pc ||
        die "grub-pc is installed on this UEFI system. Repair the bootloader configuration before continuing."

    echo "Standard UEFI grub-efi-amd64 configuration detected."
}

install_removable_efi_grub() {
    [[ $SYSTEM_TYPE == "bare metal" ]] || return 0
    [[ -d /sys/firmware/efi ]] || return 0

    echo
    echo "Installing/refreshing the removable UEFI GRUB fallback path..."

    findmnt -rn -M /boot/efi >/dev/null 2>&1 ||
        die "System is running in UEFI mode, but /boot/efi is not a mounted filesystem."

    package_installed grub-efi-amd64 ||
        die "grub-efi-amd64 is not installed before refreshing the removable UEFI boot path."

    ! package_installed grub-cloud-amd64 ||
        die "grub-cloud-amd64 is still installed before refreshing the removable UEFI boot path."

    ! package_installed grub-pc ||
        die "grub-pc is installed on this UEFI system before refreshing the removable UEFI boot path."

    grub-install \
        --recheck \
        --efi-directory=/boot/efi \
        --removable

    [[ -f $EFI_REMOVABLE_BOOTLOADER ]] ||
        die "Removable UEFI installation did not create $EFI_REMOVABLE_BOOTLOADER."

    [[ -f $EFI_REMOVABLE_GRUB ]] ||
        die "Removable UEFI installation did not create $EFI_REMOVABLE_GRUB."

    [[ -f $EFI_REMOVABLE_CONFIG ]] ||
        die "Removable UEFI installation did not create $EFI_REMOVABLE_CONFIG."

    [[ -f $EFI_VENDOR_CONFIG ]] ||
        die "Standard UEFI GRUB configuration $EFI_VENDOR_CONFIG is missing after removable-path installation."

    echo "Removable UEFI GRUB fallback path installed successfully."
}

check_preflight() {
    check_requirements
    check_platform
    check_fresh_install
    check_network_stack
    check_static_network_and_hostname
    check_virtualization
    check_bare_metal_boot_requirements
}


# ------------------------------------------------------------------------------------------
# Local system preparation
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


# ------------------------------------------------------------------------------------------
# Proxmox repository
# ------------------------------------------------------------------------------------------

proxmox_keyring_package_installed() {
    package_installed proxmox-archive-keyring
}

install_proxmox_keyring() {
    local actual_sha256
    local actual_md5

    echo

    if proxmox_keyring_package_installed; then
        [[ -f $KEYRING ]] ||
            die "proxmox-archive-keyring is installed, but $KEYRING is missing."

        echo "Proxmox archive keyring is already managed by the proxmox-archive-keyring package."
        echo "Leaving the existing keyring unchanged; published bootstrap hashes may no longer apply."
        return 0
    fi

    KEY_TMP=$(mktemp)

    echo "Downloading Proxmox archive keyring..."
    wget -q "$KEY_URL" -O "$KEY_TMP" ||
        die "Failed to download the Proxmox archive keyring."

    actual_sha256=$(sha256sum "$KEY_TMP" | awk '{ print $1 }')
    [[ $actual_sha256 == "$KEY_SHA256" ]] ||
        die "Proxmox archive keyring SHA256 verification failed. Expected $KEY_SHA256, got $actual_sha256."

    echo "Proxmox archive keyring SHA256 verification passed."

    actual_md5=$(md5sum "$KEY_TMP" | awk '{ print $1 }')
    [[ $actual_md5 == "$KEY_MD5" ]] ||
        die "Proxmox archive keyring MD5 verification failed. Expected $KEY_MD5, got $actual_md5."

    echo "Proxmox archive keyring MD5 verification passed."

    install -m 0644 "$KEY_TMP" "$KEYRING"
    rm -f -- "$KEY_TMP"
    KEY_TMP=""
}

configure_proxmox_repository() {
    echo
    echo "Configuring Proxmox Datacenter Manager no-subscription repository..."

    printf '%s\n' \
        'Types: deb' \
        'URIs: http://download.proxmox.com/debian/pdm' \
        'Suites: trixie' \
        'Components: pdm-no-subscription' \
        'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' \
        > "$PDM_REPO"

    echo
    echo "$PDM_REPO:"
    echo
    sed 's/^/  /' "$PDM_REPO"
}


# ------------------------------------------------------------------------------------------
# Package installation
# ------------------------------------------------------------------------------------------

simulate_ifupdown2_upgrade() {
    local simulation
    local unexpected

    if package_installed ifupdown2; then
        echo
        echo "ifupdown2 is already installed; no network-stack package transition is required."
        return 0
    fi

    echo
    echo "Simulating ifupdown -> ifupdown2 upgrade..."

    simulation=$(apt-get -s install ifupdown2 2>&1) || {
        printf '%s\n' "$simulation" >&2
        die "APT could not simulate the ifupdown2 installation."
    }

    printf '%s\n' "$simulation" |
        awk '/^(Inst|Remv|Purg) / { print "  " $0 }'

    grep -Eq '^Inst ifupdown2([[:space:]]|$)' <<< "$simulation" ||
        die "APT simulation did not show ifupdown2 being installed."

    unexpected=$(printf '%s\n' "$simulation" |
        awk '/^(Remv|Purg) / && $2 != "ifupdown" { print $2 }' |
        sort -u)

    if [[ -n $unexpected ]]; then
        echo
        warn "Installing ifupdown2 would remove additional packages:"
        printf '  %s\n' $unexpected
        echo
        die "Refusing the ifupdown2 transition because packages other than classic ifupdown would be removed."
    fi
}

upgrade_to_ifupdown2() {
    local before_hash
    local after_hash

    if package_installed ifupdown2; then
        package_installed ifupdown &&
            die "Both ifupdown and ifupdown2 are installed before the network-stack transition."
        return 0
    fi

    simulate_ifupdown2_upgrade

    before_hash=$(sha256sum "$INTERFACES" | awk '{ print $1 }')

    echo
    echo "Upgrading networking from ifupdown to ifupdown2..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown2

    package_installed ifupdown2 ||
        die "ifupdown2 was not installed successfully."

    ! package_installed ifupdown ||
        die "Classic ifupdown is still installed after installing ifupdown2."

    [[ -f $INTERFACES ]] ||
        die "$INTERFACES is missing after the ifupdown2 package transition."

    after_hash=$(sha256sum "$INTERFACES" | awk '{ print $1 }')
    [[ $after_hash == "$before_hash" ]] ||
        die "$INTERFACES changed unexpectedly while installing ifupdown2."

    command -v ifquery >/dev/null 2>&1 ||
        die "ifquery was not found after installing ifupdown2."

    if ! ifquery "$DEFAULT_IFACE" >/dev/null; then
        die "ifupdown2 could not parse the existing configuration for $DEFAULT_IFACE."
    fi

    echo "ifupdown2 installed successfully; $INTERFACES was preserved unchanged."
    echo "The current network configuration has not been intentionally reloaded by this script."
}

simulate_pdm_install() {
    local simulation

    echo
    echo "Simulating Proxmox Datacenter Manager package installation..."

    simulation=$(apt-get -s install "$INSTALL_PACKAGE" ifupdown2 2>&1) || {
        printf '%s\n' "$simulation" >&2
        die "APT could not simulate the Proxmox Datacenter Manager installation."
    }

    if grep -Eq '^Remv ifupdown2([[:space:]]|$)' <<< "$simulation"; then
        echo
        printf '%s\n' "$simulation"
        echo
        die "APT would remove ifupdown2 during the Proxmox Datacenter Manager installation."
    fi

    if grep -Eq '^Inst ifupdown([[:space:]]|$)' <<< "$simulation"; then
        echo
        printf '%s\n' "$simulation"
        echo
        die "APT would reinstall classic ifupdown during the Proxmox Datacenter Manager installation."
    fi

    if [[ $SYSTEM_TYPE == "bare metal" && -d /sys/firmware/efi ]]; then
        if package_installed grub-cloud-amd64; then
            die "grub-cloud-amd64 is still installed immediately before the UEFI bare-metal Proxmox package transaction."
        fi

        package_installed grub-efi-amd64 ||
            die "grub-efi-amd64 is not installed immediately before the UEFI bare-metal Proxmox package transaction."

        if grep -Eq '^Inst grub-pc([[:space:]]|$)' <<< "$simulation"; then
            echo
            printf '%s\n' "$simulation"
            echo
            die "APT would install grub-pc on a UEFI bare-metal installation."
        fi
    fi

    echo "APT simulation confirms that ifupdown2 will remain the active networking package."
}

install_pdm_packages() {
    echo
    echo "Updating package indexes..."
    apt-get update

    prepare_bare_metal_grub_for_install

    echo
    echo "Upgrading Debian packages..."
    apt-get -y dist-upgrade

    upgrade_to_ifupdown2
    simulate_pdm_install

    echo
    echo "Installing Proxmox Datacenter Manager packages..."

    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y \
            "$INSTALL_PACKAGE" \
            ifupdown2

    package_installed proxmox-datacenter-manager ||
        die "proxmox-datacenter-manager does not appear to be installed successfully."

    package_installed "$INSTALL_PACKAGE" ||
        die "$INSTALL_PACKAGE does not appear to be installed successfully."

    package_installed ifupdown2 ||
        die "ifupdown2 is not installed after Proxmox Datacenter Manager installation."

    ! package_installed ifupdown ||
        die "Classic ifupdown is unexpectedly installed after Proxmox Datacenter Manager installation."

    if [[ $SYSTEM_TYPE == "bare metal" ]]; then
        package_installed proxmox-default-kernel ||
            die "proxmox-default-kernel was not installed by the bare-metal PDM package set."
    fi

    command -v proxmox-datacenter-manager-admin >/dev/null 2>&1 ||
        die "proxmox-datacenter-manager-admin was not found after installation."
}


# ------------------------------------------------------------------------------------------
# Repository cleanup
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

disable_enterprise_repository() {
    echo
    echo "Disabling Proxmox Datacenter Manager enterprise repository when present..."

    disable_deb822_enterprise_source "$PDM_ENTERPRISE_SOURCES" "PDM enterprise repository"
    disable_legacy_enterprise_source "$PDM_ENTERPRISE_LIST" "legacy PDM enterprise repository"

    echo
    echo "Refreshing package indexes with the resulting repository configuration..."
    apt-get update
}


# ------------------------------------------------------------------------------------------
# Bare-metal kernel and bootloader cleanup
# ------------------------------------------------------------------------------------------

remove_debian_kernel_meta() {
    [[ $SYSTEM_TYPE == "bare metal" ]] || return 0

    local simulation
    local unexpected
    local running_kernel
    local running_kernel_package
    local running_kernel_package_installed=false

    echo

    if ! package_installed linux-image-amd64; then
        echo "linux-image-amd64 is not installed; no Debian kernel meta-package needs to be removed."
        return 0
    fi

    running_kernel=$(uname -r)
    running_kernel_package="linux-image-$running_kernel"

    if package_installed "$running_kernel_package"; then
        running_kernel_package_installed=true
    fi

    echo "Simulating removal of the Debian linux-image-amd64 meta-package..."

    simulation=$(apt-get -s remove linux-image-amd64 2>&1) || {
        printf '%s\n' "$simulation" >&2
        die "APT could not simulate removal of linux-image-amd64."
    }

    printf '%s\n' "$simulation" |
        awk '/^(Remv|Purg) / { print "  " $0 }'

    unexpected=$(printf '%s\n' "$simulation" |
        awk '/^(Remv|Purg) / && $2 != "linux-image-amd64" { print $2 }' |
        sort -u)

    if [[ -n $unexpected ]]; then
        echo
        warn "Removing linux-image-amd64 would remove additional packages:"
        printf '  %s\n' $unexpected
        echo
        die "Refusing Debian kernel meta-package removal because APT proposed additional removals."
    fi

    echo
    echo "Removing Debian linux-image-amd64 meta-package..."
    DEBIAN_FRONTEND=noninteractive apt-get remove -y linux-image-amd64

    ! package_installed linux-image-amd64 ||
        die "linux-image-amd64 is still installed after the removal attempt."

    # Do not remove the concrete Debian kernel that is currently running. It remains available
    # until the system has successfully rebooted into the newly installed Proxmox kernel.
    if $running_kernel_package_installed; then
        package_installed "$running_kernel_package" ||
            die "The currently running kernel package $running_kernel_package was removed unexpectedly."
    fi

    [[ -d /lib/modules/$running_kernel ]] ||
        die "The module tree for the currently running kernel $running_kernel is missing after meta-package removal."

    echo "The currently running versioned kernel remains installed: $running_kernel"
}

remove_os_prober() {
    [[ $SYSTEM_TYPE == "bare metal" ]] || return 0

    echo

    if package_installed os-prober; then
        local simulation
        local unexpected

        echo "Simulating removal of os-prober..."
        simulation=$(apt-get -s remove os-prober 2>&1) || {
            printf '%s\n' "$simulation" >&2
            die "APT could not simulate removal of os-prober."
        }

        unexpected=$(printf '%s\n' "$simulation" |
            awk '/^(Remv|Purg) / && $2 != "os-prober" { print $2 }' |
            sort -u)

        if [[ -n $unexpected ]]; then
            echo
            warn "Removing os-prober would remove additional packages:"
            printf '  %s\n' $unexpected
            echo
            die "Refusing os-prober removal because APT proposed additional removals."
        fi

        echo "Removing os-prober..."
        DEBIAN_FRONTEND=noninteractive apt-get remove -y os-prober
    else
        echo "os-prober is not installed."
    fi
}

update_bare_metal_grub() {
    [[ $SYSTEM_TYPE == "bare metal" ]] || return 0

    local -a pve_kernels=()

    echo
    echo "Updating bootloader configuration..."
    update-grub

    mapfile -t pve_kernels < <(
        find /boot -maxdepth 1 -type f -name 'vmlinuz-*-pve' -printf '%f\n' 2>/dev/null |
            sort
    )

    (( ${#pve_kernels[@]} )) ||
        die "No Proxmox -pve kernel image was found under /boot after the bare-metal installation."

    echo
    echo "Installed Proxmox kernel image(s):"
    printf '  %s\n' "${pve_kernels[@]}"
}

verify_bare_metal_boot_preparation() {
    [[ $SYSTEM_TYPE == "bare metal" ]] || return 0

    package_installed proxmox-default-kernel ||
        die "Bare-metal boot verification failed: proxmox-default-kernel is not installed."

    ! package_installed linux-image-amd64 ||
        die "Bare-metal boot verification failed: linux-image-amd64 is still installed."

    ! package_installed os-prober ||
        die "Bare-metal boot verification failed: os-prober is still installed."

    [[ -d /lib/modules/$(uname -r) ]] ||
        die "Bare-metal boot verification failed: module tree for running kernel $(uname -r) is missing."

    if [[ -d /sys/firmware/efi ]]; then
        package_installed grub-efi-amd64 ||
            die "Bare-metal boot verification failed: grub-efi-amd64 is not installed."

        ! package_installed grub-cloud-amd64 ||
            die "Bare-metal boot verification failed: grub-cloud-amd64 is still installed."

        ! package_installed grub-pc ||
            die "Bare-metal boot verification failed: grub-pc is installed on a UEFI system."

        findmnt -rn -M /boot/efi >/dev/null 2>&1 ||
            die "Bare-metal boot verification failed: /boot/efi is not mounted."

        [[ -f $EFI_VENDOR_CONFIG ]] ||
            die "Bare-metal boot verification failed: standard UEFI GRUB config $EFI_VENDOR_CONFIG is missing."

        [[ -f $EFI_REMOVABLE_BOOTLOADER ]] ||
            die "Bare-metal boot verification failed: removable EFI loader $EFI_REMOVABLE_BOOTLOADER is missing."

        [[ -f $EFI_REMOVABLE_GRUB ]] ||
            die "Bare-metal boot verification failed: removable EFI GRUB image $EFI_REMOVABLE_GRUB is missing."

        [[ -f $EFI_REMOVABLE_CONFIG ]] ||
            die "Bare-metal boot verification failed: removable EFI GRUB config $EFI_REMOVABLE_CONFIG is missing."
    fi
}

cleanup_bare_metal_boot() {
    [[ $SYSTEM_TYPE == "bare metal" ]] || return 0

    install_removable_efi_grub
    remove_debian_kernel_meta
    remove_os_prober
    update_bare_metal_grub
    verify_bare_metal_boot_preparation
}


# ------------------------------------------------------------------------------------------
# Final host configuration and verification
# ------------------------------------------------------------------------------------------

enable_fstrim() {
    echo
    echo "Enabling periodic filesystem trimming..."
    systemctl enable --now fstrim.timer

    systemctl is-enabled --quiet fstrim.timer ||
        die "fstrim.timer is not enabled."
}

verify_installation() {
    local api_state
    local privileged_state

    package_installed proxmox-datacenter-manager ||
        die "Verification failed: proxmox-datacenter-manager is not installed."

    package_installed "$INSTALL_PACKAGE" ||
        die "Verification failed: $INSTALL_PACKAGE is not installed."

    package_installed ifupdown2 ||
        die "Verification failed: ifupdown2 is not installed."

    ! package_installed ifupdown ||
        die "Verification failed: classic ifupdown is still installed."

    systemctl is-enabled --quiet networking.service 2>/dev/null ||
        die "Verification failed: networking.service is not enabled."

    ! systemctl is-enabled --quiet systemd-networkd.service 2>/dev/null ||
        die "Verification failed: systemd-networkd.service is enabled."

    systemctl is-active --quiet proxmox-datacenter-api.service ||
        die "Verification failed: proxmox-datacenter-api.service is not active."

    systemctl is-active --quiet proxmox-datacenter-privileged-api.service ||
        die "Verification failed: proxmox-datacenter-privileged-api.service is not active."

    systemctl is-enabled --quiet fstrim.timer ||
        die "Verification failed: fstrim.timer is not enabled."

    api_state=$(systemctl is-active proxmox-datacenter-api.service)
    privileged_state=$(systemctl is-active proxmox-datacenter-privileged-api.service)

    echo
    echo "Proxmox Datacenter Manager installation verification:"
    echo
    printf '  %-20s %s\n' "System type:" "$SYSTEM_TYPE"
    if $FORCE_BARE_METAL_REQUESTED; then
        printf '  %-20s %s\n' "Install override:" "forced bare metal"
    fi
    printf '  %-20s %s\n' "Installed package:" "$INSTALL_PACKAGE"
    printf '  %-20s %s\n' "Running kernel:" "$(uname -r)"
    printf '  %-20s %s\n' "Networking:" "ifupdown2"
    if [[ $SYSTEM_TYPE == "bare metal" ]]; then
        printf '  %-20s %s\n' "Debian kernel meta:" "removed"
        printf '  %-20s %s\n' "Old running kernel:" "retained until post-reboot cleanup"
    fi
    printf '  %-20s %s\n' "PDM API:" "$api_state"
    printf '  %-20s %s\n' "Privileged API:" "$privileged_state"
    printf '  %-20s %s\n' "fstrim:" "$(systemctl is-enabled fstrim.timer)"
    printf '  %-20s %s\n' "Web interface:" "https://$HOST_FQDN:8443"
    printf '  %-20s %s\n' "Web interface (IP):" "https://$LOCAL_IPV4:8443"

    echo
    echo "Installed PDM versions:"
    echo
    proxmox-datacenter-manager-admin versions --verbose | sed 's/^/  /'
}

finish_installation() {
    echo
    echo "Proxmox Datacenter Manager installation is complete."
    echo

    if [[ $SYSTEM_TYPE == "bare metal" ]]; then
        echo "A reboot is required to start the installed Proxmox kernel."
        echo
        echo "The Debian linux-image-amd64 meta-package has been removed, but the currently"
        echo "installed versioned Debian kernel was deliberately retained for this first reboot."
        echo "After reboot, verify that 'uname -r' ends in '-pve'. Once verified, the old"
        echo "versioned Debian kernel package may be removed."
    else
        echo "A reboot is recommended after the Debian upgrade and PDM installation."
    fi

    echo

    if yesno "Reboot now?" Y; then
        systemctl reboot
    else
        echo
        if [[ $SYSTEM_TYPE == "bare metal" ]]; then
            echo "Reboot the system before putting Proxmox Datacenter Manager into service."
        else
            echo "Reboot the system when convenient before putting Proxmox Datacenter Manager into service."
        fi
    fi
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    parse_args "$@"
    check_preflight

    echo
    yesno "Install Proxmox Datacenter Manager using the configuration shown above?" N || exit 0

    disable_login_banner_service
    install_proxmox_keyring
    configure_proxmox_repository
    install_pdm_packages
    disable_enterprise_repository
    cleanup_bare_metal_boot
    enable_fstrim
    verify_installation
    finish_installation
}

main "$@"
