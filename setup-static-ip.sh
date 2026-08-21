#!/bin/bash

# Quick start:
# curl -fsSLO https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/setup-static-ip.sh && bash setup-static-ip.sh

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        setup-static-ip.sh
# Revision:    r9
# Modified:    2026-08-21
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Description: Configures a Debian IPv4 interface with a static address. Live interface and
#              resolver settings are discovered and offered as defaults, but the IP address,
#              netmask/prefix, default gateway, DNS servers, and search domains can all be
#              overridden interactively. When a complete live configuration is discovered,
#              it can be accepted as a group without stepping through each individual prompt.
#              Interfaces without a current address can also be selected and configured by
#              supplying the required values manually.
#
#              Displays physical Ethernet interfaces with live network and hardware information
#              and allows interactive selection of the primary interface.
#
#              Proposed changes are staged as .new files and shown as diffs before they are
#              committed. The script updates /etc/network/interfaces, updates /etc/hosts so
#              the system hostname resolves to the selected static IPv4 address, converts
#              /etc/resolv.conf to a static resolver configuration, adds "nohook resolv.conf"
#              to /etc/dhcpcd.conf so future DHCP interfaces do not overwrite static DNS settings,
#              and disables cloud-init management of /etc/hosts when cloud-init is present.
#              If the system does not yet have an FQDN, a DHCP-provided default domain or single
#              search domain is used automatically; otherwise the user is prompted for the domain
#              to use.
#
#              If the selected interface has an active DHCP lease, its dhcpcd instance is
#              stopped with the current live network configuration preserved. Networking is
#              not restarted or reloaded while the script is running.
#
# Requirements:
#              bash
#              coreutils
#              dhcpcd-base
#              findutils
#              grep
#              hostname
#              iproute2
#              mawk
#
# Optional:
#              pciutils
#                                   Provides lspci hardware descriptions during interface
#                                   discovery. Interface discovery does not require it.
#
# Output:
#              /etc/network/interfaces
#              /etc/network/interfaces.bak-YYYYMMDD-HHMMSS
#              /etc/hosts
#              /etc/resolv.conf
#              /etc/dhcpcd.conf
#              /etc/cloud/cloud.cfg.d/99-disable-manage-etc-hosts.cfg (when cloud-init is present)
#
# Notes:
#              This script is intended for a standard Debian installation using ifupdown and
#              dhcpcd, with /etc/resolv.conf generated directly by dhcpcd. It intentionally
#              does not support resolver-manager symlinks such as systemd-resolved or
#              resolvconf.
# ------------------------------------------------------------------------------------------

set -euo pipefail

INTERFACES=/etc/network/interfaces
INTERFACES_NEW=/etc/network/interfaces.new
INTERFACES_D=/etc/network/interfaces.d

HOSTS=/etc/hosts
HOSTS_NEW=/etc/hosts.new

RESOLV_CONF=/etc/resolv.conf
RESOLV_CONF_NEW=/etc/resolv.conf.new

DHCPCD_CONF=/etc/dhcpcd.conf
DHCPCD_CONF_NEW=/etc/dhcpcd.conf.new

CLOUD_HOSTS_DISABLE=/etc/cloud/cloud.cfg.d/99-disable-manage-etc-hosts.cfg

SELECTED_IFACE=""
SELECTED_IP=""
SELECTED_PREFIX=""
SELECTED_ADDRESS=""
SELECTED_GATEWAY=""

LIVE_ADDRESS=""
LIVE_GATEWAY=""
SEARCH_DOMAINS=""
DISCOVERED_DOMAIN=""
DISCOVERED_SEARCH_DOMAINS=""
HOST_DOMAIN=""
HOST_SHORT=""
HOST_FQDN=""

DHCPCD_CONF_CHANGED=0
CLOUD_INIT_PRESENT=0

declare -a IFACES DNS_SERVERS DNS_OPTIONS
declare -A ID METHOD ADDRESS GATEWAY MAC PCI DRIVER DESC STATE DEFAULT_ROUTE


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

valid_domain_name() {
    local domain=${1%.}
    local label
    local -a labels=()

    [[ -n $domain && ${#domain} -le 253 ]] || return 1
    [[ $domain != .* && $domain != *. && $domain != *..* ]] || return 1

    IFS='.' read -ra labels <<< "$domain"

    for label in "${labels[@]}"; do
        [[ -n $label && ${#label} -le 63 ]] || return 1
        [[ $label =~ ^[A-Za-z0-9]$ || $label =~ ^[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]$ ]] || return 1
    done
}

prompt_for_host_domain() {
    local input
    local -a search_domains=()

    read -ra search_domains <<< "$DISCOVERED_SEARCH_DOMAINS"

    echo
    warn "The system hostname '$HOST_SHORT' does not currently have a domain/FQDN."

    if (( ${#search_domains[@]} > 1 )); then
        echo "DHCP-provided search domains:" >&2
        printf '  %s\n' "${search_domains[@]}" >&2
    elif (( ${#search_domains[@]} == 0 )); then
        echo "No DHCP-provided default domain or search domain was discovered." >&2
    fi

    while true; do
        read -r -p "Domain to use for this host: " input
        input=${input%.}

        if valid_domain_name "$input"; then
            HOST_DOMAIN=$input
            return 0
        fi

        echo "Enter a valid DNS domain name, for example: example.com"
    done
}

determine_hostname_identity() {
    local current_fqdn
    local candidate=""
    local -a search_domains=()

    HOST_SHORT=$(hostname --short 2>/dev/null || true)
    current_fqdn=$(hostname --fqdn 2>/dev/null || true)

    [[ -n $HOST_SHORT ]] || die "Unable to determine the system short hostname."

    if [[ -n $current_fqdn && $current_fqdn != "$HOST_SHORT" && $current_fqdn == *.* ]]; then
        HOST_FQDN=$current_fqdn
        HOST_DOMAIN=${current_fqdn#*.}
        return 0
    fi

    if [[ -n $DISCOVERED_DOMAIN ]]; then
        candidate=${DISCOVERED_DOMAIN%.}

        if valid_domain_name "$candidate"; then
            HOST_DOMAIN=$candidate
            echo
            echo "No FQDN is currently configured; using DHCP-provided domain '$HOST_DOMAIN'."
        else
            warn "Ignoring invalid DHCP-provided domain '$DISCOVERED_DOMAIN'."
        fi
    fi

    read -ra search_domains <<< "$DISCOVERED_SEARCH_DOMAINS"

    if [[ -z $HOST_DOMAIN && ${#search_domains[@]} -eq 1 ]]; then
        candidate=${search_domains[0]%.}

        if valid_domain_name "$candidate"; then
            HOST_DOMAIN=$candidate
            echo
            echo "No FQDN is currently configured; using DHCP-provided search domain '$HOST_DOMAIN'."
        else
            warn "Ignoring invalid DHCP-provided search domain '${search_domains[0]}'."
        fi
    fi

    if [[ -z $HOST_DOMAIN ]]; then
        prompt_for_host_domain
    fi

    HOST_FQDN="$HOST_SHORT.$HOST_DOMAIN"

    echo "Host identity will use:"
    printf '  %-18s %s\n' "Hostname:" "$HOST_SHORT"
    printf '  %-18s %s\n' "FQDN:" "$HOST_FQDN"
}


# ------------------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------------------

preflight() {
    (( EUID == 0 )) || die "Run this script as root."
    [[ -t 0 ]] || die "This script requires an interactive terminal."

    [[ -f $INTERFACES ]] || die "$INTERFACES does not exist."
    [[ -f $HOSTS ]] || die "$HOSTS does not exist."
    [[ -e $RESOLV_CONF ]] || die "$RESOLV_CONF does not exist."
    [[ -f $DHCPCD_CONF ]] || die "$DHCPCD_CONF does not exist."

    [[ ! -L $RESOLV_CONF ]] ||
        die "$RESOLV_CONF is a symbolic link. This script expects a regular file generated by dhcpcd."

    local cmd

    for cmd in \
        awk basename cat cp date dhcpcd diff find grep hostname ip mkdir mv \
        readlink rm sort
    do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    if ! grep -Eq '^#[[:space:]]*Generated by dhcpcd([[:space:]]|$)' "$RESOLV_CONF"; then
        echo
        warn "$RESOLV_CONF does not appear to have been generated by dhcpcd."
        warn "This script is designed for the standard Debian dhcpcd resolver configuration."
        echo

        yesno "Continue anyway?" N || exit 1
    fi

    if [[ -f /etc/cloud/cloud.cfg || -d /etc/cloud/cloud.cfg.d || -e /etc/cloud/cloud-init.disabled ]]; then
        CLOUD_INIT_PRESENT=1
    fi

    check_interfaces_d
    check_existing_new_files
}

check_interfaces_d() {
    [[ -d $INTERFACES_D ]] || return 0

    local -a files=()

    mapfile -t files < <(
        find "$INTERFACES_D" -maxdepth 1 \
            \( -type f -o -type l \) \
            -print |
        sort
    )

    (( ${#files[@]} )) || return 0

    echo
    warn "Files were found under $INTERFACES_D:"
    echo
    printf '  %s\n' "${files[@]}"

    echo
    echo "Only $INTERFACES will be updated."
    echo "Configuration in these files will NOT be modified."
    echo

    yesno "Continue anyway?" N || exit 1
}

check_existing_new_files() {
    local -a files=()
    local file

    for file in \
        "$INTERFACES_NEW" \
        "$HOSTS_NEW" \
        "$RESOLV_CONF_NEW" \
        "$DHCPCD_CONF_NEW"
    do
        [[ -e $file ]] && files+=("$file")
    done

    (( ${#files[@]} )) || return 0

    echo
    warn "Existing staged configuration files were found:"
    echo
    printf '  %s\n' "${files[@]}"
    echo

    yesno "Overwrite these staged files?" N || exit 1

    rm -f -- "${files[@]}"
}


# ------------------------------------------------------------------------------------------
# Interface discovery
# ------------------------------------------------------------------------------------------

pci_address() {
    local iface=$1
    local dev

    [[ -e /sys/class/net/$iface/device ]] || return 0

    dev=$(basename "$(readlink -f "/sys/class/net/$iface/device")")

    if [[ $dev =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-7]$ ]]; then
        printf '%s\n' "$dev"
    fi
}

interface_method() {
    local iface=$1

    awk -v iface="$iface" '
        $1 == "iface" && $2 == iface && $3 == "inet" {
            print $4
            exit
        }
    ' "$INTERFACES"
}

interface_addresses() {
    local iface=$1

    ip -4 -o addr show dev "$iface" scope global 2>/dev/null |
        awk '{ print $4 }'
}

interface_gateway() {
    local iface=$1

    ip -4 route show default dev "$iface" 2>/dev/null |
        awk '
            $1 == "default" {
                for (i = 1; i <= NF; i++) {
                    if ($i == "via" && (i + 1) <= NF) {
                        print $(i + 1)
                    }
                }
            }
        '
}

discover_interfaces() {
    local path
    local iface
    local method
    local id=1
    local pci
    local addresses
    local gateway
    local default_dev
    local -a found=()

    default_dev=$(
        ip -4 route show default 2>/dev/null |
            awk '
                $1 == "default" {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "dev" && (i + 1) <= NF) {
                            print $(i + 1)
                            exit
                        }
                    }
                }
            '
    )

    for path in /sys/class/net/*; do
        iface=$(basename "$path")

        [[ $iface == lo ]] && continue

        # Ethernet only.
        [[ -r $path/type && $(cat "$path/type") == 1 ]] || continue

        # Excludes bridges, bonds, VLANs, veth interfaces, etc.
        [[ -e $path/device ]] || continue

        # Exclude wireless devices.
        [[ -d $path/wireless ]] && continue

        # Exclude SR-IOV virtual functions.
        [[ -e $path/device/physfn ]] && continue

        found+=("$iface")
    done

    (( ${#found[@]} )) ||
        die "No physical Ethernet interfaces were found."

    mapfile -t IFACES < <(
        printf '%s\n' "${found[@]}" |
        sort
    )

    for iface in "${IFACES[@]}"; do
        method=$(interface_method "$iface")
        [[ -n $method ]] || method="unconfigured"

        ID[$iface]=$id
        METHOD[$iface]=$method

        addresses=$(interface_addresses "$iface" | paste_lines)
        gateway=$(interface_gateway "$iface" | paste_lines)

        ADDRESS[$iface]=${addresses:--}
        GATEWAY[$iface]=${gateway:--}
        DEFAULT_ROUTE[$iface]=0

        [[ $iface == "$default_dev" ]] && DEFAULT_ROUTE[$iface]=1

        path=/sys/class/net/$iface

        MAC[$iface]="-"
        PCI[$iface]=""
        DRIVER[$iface]=""
        DESC[$iface]=""
        STATE[$iface]="unknown"

        [[ -r $path/address ]] && MAC[$iface]=$(cat "$path/address")
        [[ -r $path/operstate ]] && STATE[$iface]=$(cat "$path/operstate")

        pci=$(pci_address "$iface")
        PCI[$iface]=$pci

        if [[ -L $path/device/driver ]]; then
            DRIVER[$iface]=$(
                basename "$(readlink -f "$path/device/driver")"
            )
        fi

        if [[ -n $pci ]] && command -v lspci >/dev/null 2>&1; then
            DESC[$iface]=$(
                lspci -D -s "$pci" 2>/dev/null |
                awk '{$1=""; sub(/^ /, ""); print}' ||
                true
            )
        fi

        ((id += 1))
    done
}

paste_lines() {
    awk '
        BEGIN { first = 1 }
        {
            if (!first) {
                printf ", "
            }
            printf "%s", $0
            first = 0
        }
        END {
            if (!first) {
                printf "\n"
            }
        }
    '
}

show_interface() {
    local iface=$1
    local marker=""

    [[ ${DEFAULT_ROUTE[$iface]} == 1 ]] && marker="  DEFAULT"

    printf '  [%d] %-12s %-12s %-20s State %-7s%s\n' \
        "${ID[$iface]}" \
        "$iface" \
        "${METHOD[$iface]}" \
        "${ADDRESS[$iface]}" \
        "${STATE[$iface]}" \
        "$marker"

    printf '      MAC: %-17s' "${MAC[$iface]}"

    if [[ -n ${PCI[$iface]} ]]; then
        printf '  PCI: %s' "${PCI[$iface]}"
    fi

    printf '\n'

    if [[ -n ${DESC[$iface]} || -n ${DRIVER[$iface]} ]]; then
        printf '      '

        if [[ -n ${DESC[$iface]} ]]; then
            printf '%s' "${DESC[$iface]}"
        fi

        if [[ -n ${DESC[$iface]} && -n ${DRIVER[$iface]} ]]; then
            printf ' | '
        fi

        if [[ -n ${DRIVER[$iface]} ]]; then
            printf 'driver=%s' "${DRIVER[$iface]}"
        fi

        printf '\n'
    fi

    if [[ ${GATEWAY[$iface]} != "-" ]]; then
        printf '      Gateway: %s\n' "${GATEWAY[$iface]}"
    fi
}

show_interfaces() {
    local iface

    echo
    echo "Physical Ethernet interfaces:"
    echo

    for iface in "${IFACES[@]}"; do
        show_interface "$iface"
    done
}

choose_interface() {
    local default_id=""
    local iface
    local input

    for iface in "${IFACES[@]}"; do
        if [[ ${DEFAULT_ROUTE[$iface]} == 1 ]]; then
            default_id=${ID[$iface]}
            break
        fi
    done

    while true; do
        echo

        if [[ -n $default_id ]]; then
            read -r -p "Primary network interface [$default_id]: " input
            input=${input:-$default_id}
        else
            read -r -p "Primary network interface: " input
        fi

        if [[ $input =~ ^[0-9]+$ ]]; then
            for iface in "${IFACES[@]}"; do
                if [[ ${ID[$iface]} == "$input" ]]; then
                    SELECTED_IFACE=$iface
                    return 0
                fi
            done
        fi

        echo "Enter one of the listed interface numbers."
    done
}


# ------------------------------------------------------------------------------------------
# Current configuration capture and interactive override
# ------------------------------------------------------------------------------------------

valid_ipv4() {
    local value=$1
    local a b c d extra
    local octet

    IFS=. read -r a b c d extra <<< "$value"

    [[ -n ${a:-} && -n ${b:-} && -n ${c:-} && -n ${d:-} && -z ${extra:-} ]] ||
        return 1

    for octet in "$a" "$b" "$c" "$d"; do
        [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

netmask_to_prefix() {
    local mask=$1
    local a b c d extra
    local octet
    local bits
    local prefix=0
    local partial=0

    IFS=. read -r a b c d extra <<< "$mask"

    [[ -n ${a:-} && -n ${b:-} && -n ${c:-} && -n ${d:-} && -z ${extra:-} ]] ||
        return 1

    for octet in "$a" "$b" "$c" "$d"; do
        case "$octet" in
            255) bits=8 ;;
            254) bits=7 ;;
            252) bits=6 ;;
            248) bits=5 ;;
            240) bits=4 ;;
            224) bits=3 ;;
            192) bits=2 ;;
            128) bits=1 ;;
            0)   bits=0 ;;
            *)   return 1 ;;
        esac

        if (( partial && bits != 0 )); then
            return 1
        fi

        ((prefix += bits))

        if (( bits < 8 )); then
            partial=1
        fi
    done

    printf '%s\n' "$prefix"
}

normalize_prefix() {
    local value=$1
    local prefix

    if [[ $value =~ ^[0-9]+$ ]]; then
        (( 10#$value >= 0 && 10#$value <= 32 )) || return 1
        printf '%d\n' "$((10#$value))"
        return 0
    fi

    prefix=$(netmask_to_prefix "$value") || return 1
    printf '%s\n' "$prefix"
}

prefix_to_netmask() {
    local prefix=$1
    local remaining=$prefix
    local i
    local bits
    local octet
    local result=""

    for ((i=0; i<4; i++)); do
        if (( remaining >= 8 )); then
            bits=8
            remaining=$((remaining - 8))
        else
            bits=$remaining
            remaining=0
        fi

        if (( bits == 0 )); then
            octet=0
        else
            octet=$((256 - (1 << (8 - bits))))
        fi

        result+="${result:+.}$octet"
    done

    printf '%s\n' "$result"
}

capture_network_configuration() {
    local -a addresses=()
    local -a gateways=()

    LIVE_ADDRESS=""
    LIVE_GATEWAY=""

    mapfile -t addresses < <(
        interface_addresses "$SELECTED_IFACE"
    )

    if (( ${#addresses[@]} == 1 )); then
        LIVE_ADDRESS=${addresses[0]}
    elif (( ${#addresses[@]} > 1 )); then
        echo
        warn "$SELECTED_IFACE has multiple global IPv4 addresses; no address default will be selected."
    fi

    mapfile -t gateways < <(
        interface_gateway "$SELECTED_IFACE"
    )

    if (( ${#gateways[@]} == 1 )); then
        LIVE_GATEWAY=${gateways[0]}
    elif (( ${#gateways[@]} > 1 )); then
        echo
        warn "$SELECTED_IFACE has multiple IPv4 default gateways; no gateway default will be selected."
    fi

    capture_dns_configuration
}

capture_dns_configuration() {
    DNS_SERVERS=()
    DNS_OPTIONS=()
    SEARCH_DOMAINS=""
    DISCOVERED_DOMAIN=""
    DISCOVERED_SEARCH_DOMAINS=""

    local line_type
    local line_value
    local domain_value=""

    while read -r line_type line_value; do
        case "$line_type" in
            nameserver)
                [[ -n ${line_value:-} ]] && DNS_SERVERS+=("$line_value")
                ;;

            search)
                if [[ -n ${line_value:-} ]]; then
                    SEARCH_DOMAINS=$line_value
                    DISCOVERED_SEARCH_DOMAINS=$line_value
                fi
                ;;

            domain)
                if [[ -n ${line_value:-} ]]; then
                    domain_value=$line_value
                    DISCOVERED_DOMAIN=$line_value
                fi
                ;;

            options)
                [[ -n ${line_value:-} ]] && DNS_OPTIONS+=("$line_value")
                ;;
        esac
    done < <(
        awk '
            /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
            $1 == "nameserver" { print "nameserver", $2; next }
            $1 == "search" {
                $1 = ""
                sub(/^[[:space:]]+/, "")
                print "search", $0
                next
            }
            $1 == "domain" { print "domain", $2; next }
            $1 == "options" {
                $1 = ""
                sub(/^[[:space:]]+/, "")
                print "options", $0
                next
            }
        ' "$RESOLV_CONF"
    )

    if [[ -z $SEARCH_DOMAINS && -n $domain_value ]]; then
        SEARCH_DOMAINS=$domain_value
    fi
}

discovered_configuration_complete() {
    local ip
    local prefix
    local dns

    [[ -n $LIVE_ADDRESS && $LIVE_ADDRESS == */* ]] || return 1
    [[ -n $LIVE_GATEWAY ]] || return 1
    (( ${#DNS_SERVERS[@]} )) || return 1

    ip=${LIVE_ADDRESS%/*}
    prefix=${LIVE_ADDRESS#*/}

    valid_ipv4 "$ip" || return 1
    normalize_prefix "$prefix" >/dev/null || return 1
    valid_ipv4 "$LIVE_GATEWAY" || return 1

    for dns in "${DNS_SERVERS[@]}"; do
        valid_ipv4 "$dns" || return 1
    done
}

load_discovered_configuration() {
    SELECTED_IP=${LIVE_ADDRESS%/*}
    SELECTED_PREFIX=$(normalize_prefix "${LIVE_ADDRESS#*/}")
    SELECTED_ADDRESS="$SELECTED_IP/$SELECTED_PREFIX"
    SELECTED_GATEWAY=$LIVE_GATEWAY
}

show_detected_configuration() {
    local dns

    echo
    echo "Detected values for $SELECTED_IFACE:"
    echo

    if [[ -n $LIVE_ADDRESS ]]; then
        printf '  Address:        %s\n' "$LIVE_ADDRESS"
    else
        printf '  Address:        -\n'
    fi

    if [[ -n $LIVE_GATEWAY ]]; then
        printf '  Gateway:        %s\n' "$LIVE_GATEWAY"
    else
        printf '  Gateway:        -\n'
    fi

    if (( ${#DNS_SERVERS[@]} )); then
        printf '  DNS Servers:    %s\n' "${DNS_SERVERS[0]}"

        for dns in "${DNS_SERVERS[@]:1}"; do
            printf '                  %s\n' "$dns"
        done
    else
        printf '  DNS Servers:    -\n'
    fi

    if [[ -n $SEARCH_DOMAINS ]]; then
        printf '  Search Domains: %s\n' "$SEARCH_DOMAINS"
    else
        printf '  Search Domains: -\n'
    fi

    if (( ${#DNS_OPTIONS[@]} )); then
        printf '  DNS Options:    %s\n' "${DNS_OPTIONS[0]}"

        for dns in "${DNS_OPTIONS[@]:1}"; do
            printf '                  %s\n' "$dns"
        done
    fi

    echo
}

prompt_static_configuration() {
    local default_ip=""
    local default_prefix=""
    local default_gateway=$LIVE_GATEWAY
    local default_dns=""
    local input
    local normalized_prefix
    local dns
    local -a dns_values=()

    if [[ -n $LIVE_ADDRESS && $LIVE_ADDRESS == */* ]]; then
        default_ip=${LIVE_ADDRESS%/*}
        default_prefix=${LIVE_ADDRESS#*/}
    fi

    echo "Enter the desired static configuration. Press Enter to accept a displayed default."
    echo

    while true; do
        if [[ -n $default_ip ]]; then
            read -r -p "IP address [$default_ip]: " input
            input=${input:-$default_ip}
        else
            read -r -p "IP address: " input
        fi

        if valid_ipv4 "$input"; then
            SELECTED_IP=$input
            break
        fi

        echo "Enter a valid IPv4 address."
    done

    while true; do
        if [[ -n $default_prefix ]]; then
            read -r -p "Netmask/prefix [$default_prefix]: " input
            input=${input:-$default_prefix}
        else
            read -r -p "Netmask/prefix (for example 24 or 255.255.255.0): " input
        fi

        if normalized_prefix=$(normalize_prefix "$input"); then
            SELECTED_PREFIX=$normalized_prefix
            break
        fi

        echo "Enter a valid IPv4 netmask or prefix length from 0 through 32."
    done

    while true; do
        if [[ -n $default_gateway ]]; then
            read -r -p "Default gateway [$default_gateway]: " input
            input=${input:-$default_gateway}
        else
            read -r -p "Default gateway: " input
        fi

        if valid_ipv4 "$input"; then
            SELECTED_GATEWAY=$input
            break
        fi

        echo "Enter a valid IPv4 gateway address."
    done

    if (( ${#DNS_SERVERS[@]} )); then
        default_dns="${DNS_SERVERS[*]}"
    fi

    while true; do
        if [[ -n $default_dns ]]; then
            read -r -p "DNS servers, space-separated [$default_dns]: " input
            input=${input:-$default_dns}
        else
            read -r -p "DNS servers, space-separated: " input
        fi

        input=${input//,/ }
        read -ra dns_values <<< "$input"

        (( ${#dns_values[@]} )) || {
            echo "Enter at least one DNS server."
            continue
        }

        local dns_valid=1

        for dns in "${dns_values[@]}"; do
            if ! valid_ipv4 "$dns"; then
                dns_valid=0
                break
            fi
        done

        if (( dns_valid )); then
            DNS_SERVERS=("${dns_values[@]}")
            break
        fi

        echo "Enter valid IPv4 DNS server addresses separated by spaces or commas."
    done

    if [[ -n $SEARCH_DOMAINS ]]; then
        read -r -p "Search domains [$SEARCH_DOMAINS] (use '-' for none): " input

        if [[ -z $input ]]; then
            :
        elif [[ $input == "-" ]]; then
            SEARCH_DOMAINS=""
        else
            SEARCH_DOMAINS=${input//,/ }
        fi
    else
        read -r -p "Search domains [none]: " input

        if [[ -n $input && $input != "-" ]]; then
            SEARCH_DOMAINS=${input//,/ }
        fi
    fi

    SELECTED_ADDRESS="$SELECTED_IP/$SELECTED_PREFIX"
}

show_selected_configuration() {
    local dns
    local netmask

    netmask=$(prefix_to_netmask "$SELECTED_PREFIX")

    echo
    echo "Proposed static configuration for $SELECTED_IFACE:"
    echo
    printf '  IP Address:     %s\n' "$SELECTED_IP"
    printf '  Netmask:        %s (/%s)\n' "$netmask" "$SELECTED_PREFIX"
    printf '  Gateway:        %s\n' "$SELECTED_GATEWAY"
    printf '  DNS Servers:    %s\n' "${DNS_SERVERS[0]}"

    for dns in "${DNS_SERVERS[@]:1}"; do
        printf '                  %s\n' "$dns"
    done

    if [[ -n $SEARCH_DOMAINS ]]; then
        printf '  Search Domains: %s\n' "$SEARCH_DOMAINS"
    else
        printf '  Search Domains: -\n'
    fi

    printf '  Hostname:       %s\n' "$HOST_SHORT"
    printf '  FQDN:           %s\n' "$HOST_FQDN"

    echo
}


choose_static_configuration() {
    if discovered_configuration_complete; then
        load_discovered_configuration
        show_selected_configuration

        if yesno "Use these values?" Y; then
            return 0
        fi

        echo
    else
        show_detected_configuration
    fi

    prompt_static_configuration
    show_selected_configuration

    yesno "Use this static network configuration?" N || exit 0
}


# ------------------------------------------------------------------------------------------
# Configuration staging
# ------------------------------------------------------------------------------------------

stage_interfaces() {
    local matches
    local tmp="${INTERFACES_NEW}.tmp"

    matches=$(
        awk -v iface="$SELECTED_IFACE" '
            $1 == "iface" && $2 == iface && $3 == "inet" {
                count += 1
            }
            END { print count + 0 }
        ' "$INTERFACES"
    )

    (( matches <= 1 )) ||
        die "Expected at most one IPv4 stanza for $SELECTED_IFACE in $INTERFACES; found $matches."

    cp -a "$INTERFACES" "$INTERFACES_NEW"

    if (( matches == 0 )); then
        if [[ -s $INTERFACES_NEW ]]; then
            printf '
' >> "$INTERFACES_NEW"
        fi

        cat >> "$INTERFACES_NEW" <<EOF_INTERFACE
# Static primary network interface configured by setup-static-ip.sh
allow-hotplug $SELECTED_IFACE
iface $SELECTED_IFACE inet static
    address $SELECTED_ADDRESS
    gateway $SELECTED_GATEWAY
EOF_INTERFACE
        return 0
    fi

    awk \
        -v iface="$SELECTED_IFACE" \
        -v address="$SELECTED_ADDRESS" \
        -v gateway="$SELECTED_GATEWAY" '
        $1 == "iface" && $2 == iface && $3 == "inet" {
            leading = ""
            if (match($0, /^[[:space:]]+/)) {
                leading = substr($0, RSTART, RLENGTH)
            }

            print leading "iface " iface " inet static"
            print "    address " address
            print "    gateway " gateway
            selected = 1
            next
        }

        selected && $1 == "iface" {
            selected = 0
        }

        selected && ($1 == "address" || $1 == "netmask" || $1 == "gateway") {
            next
        }

        { print }
    ' "$INTERFACES_NEW" > "$tmp"

    cat "$tmp" > "$INTERFACES_NEW"
    rm -f "$tmp"
}

stage_hosts() {
    local matches
    local hosts_line
    local static_ip
    local tmp="${HOSTS_NEW}.tmp"

    matches=$(
        awk '
            $1 == "127.0.1.1" {
                count += 1
            }
            END { print count + 0 }
        ' "$HOSTS"
    )

    (( matches == 1 )) ||
        die "Expected exactly one active 127.0.1.1 hostname entry in $HOSTS; found $matches."

    hosts_line=$(
        awk '$1 == "127.0.1.1" { print; exit }' "$HOSTS"
    )

    awk -v hostname="$HOST_SHORT" '
        $1 == "127.0.1.1" {
            for (i = 2; i <= NF; i++) {
                if ($i == hostname) found = 1
            }
        }
        END { exit !found }
    ' <<< "$hosts_line" ||
        die "The active 127.0.1.1 entry in $HOSTS does not contain the system hostname '$HOST_SHORT'."

    static_ip=${SELECTED_ADDRESS%/*}

    cp -a "$HOSTS" "$HOSTS_NEW"

    awk \
        -v ip="$static_ip" \
        -v fqdn="$HOST_FQDN" \
        -v hostname="$HOST_SHORT" '
        $0 ~ /^# Your system has configured .*manage_etc_hosts.* as True\.$/ ||
        $0 == "# As a result, if you wish for changes to this file to persist" ||
        $0 == "# then you will need to either" ||
        $0 == "# a.) make changes to the master file in /etc/cloud/templates/hosts.debian.tmpl" ||
        $0 ~ /^# b\.\) change or remove the value of .*manage_etc_hosts.* in$/ ||
        $0 == "#     /etc/cloud/cloud.cfg or cloud-config from user-data" {
            next
        }

        !updated && $1 == "127.0.1.1" {
            print "# " $0
            print ip "\t" fqdn " " hostname
            updated = 1
            next
        }

        { print }

        END {
            if (!updated) {
                exit 1
            }
        }
    ' "$HOSTS_NEW" > "$tmp"

    cat "$tmp" > "$HOSTS_NEW"
    rm -f "$tmp"
}

stage_resolv_conf() {
    local dns
    local option

    cp -a "$RESOLV_CONF" "$RESOLV_CONF_NEW"
    : > "$RESOLV_CONF_NEW"

    cat >> "$RESOLV_CONF_NEW" <<'EOF_RESOLV'
# Static DNS configuration generated by setup-static-ip.sh
# dhcpcd DNS updates are disabled by "nohook resolv.conf" in /etc/dhcpcd.conf.
EOF_RESOLV

    if [[ -n $SEARCH_DOMAINS ]]; then
        printf '\nsearch %s\n' "$SEARCH_DOMAINS" >> "$RESOLV_CONF_NEW"
    fi

    for dns in "${DNS_SERVERS[@]}"; do
        printf 'nameserver %s\n' "$dns" >> "$RESOLV_CONF_NEW"
    done

    for option in "${DNS_OPTIONS[@]}"; do
        printf 'options %s\n' "$option" >> "$RESOLV_CONF_NEW"
    done
}

stage_dhcpcd_conf() {
    cp -a "$DHCPCD_CONF" "$DHCPCD_CONF_NEW"
    DHCPCD_CONF_CHANGED=0

    if grep -Eq '^[[:space:]]*nohook[[:space:]].*resolv\.conf([[:space:],]|$)' "$DHCPCD_CONF_NEW"; then
        return 0
    fi

    if [[ -s $DHCPCD_CONF_NEW ]]; then
        printf '\n' >> "$DHCPCD_CONF_NEW"
    fi

    cat >> "$DHCPCD_CONF_NEW" <<'EOF_DHCPCD'
# DNS is statically configured in /etc/resolv.conf by setup-static-ip.sh.
nohook resolv.conf
EOF_DHCPCD

    DHCPCD_CONF_CHANGED=1
}

show_staged_changes() {
    echo
    echo "Proposed changes to $INTERFACES:"
    echo
    diff -u "$INTERFACES" "$INTERFACES_NEW" || true

    echo
    echo "Proposed changes to $HOSTS:"
    echo
    diff -u "$HOSTS" "$HOSTS_NEW" || true

    if (( CLOUD_INIT_PRESENT )); then
        echo
        echo "Cloud-init /etc/hosts management will be disabled:"
        echo "  $CLOUD_HOSTS_DISABLE"
        echo "  manage_etc_hosts: false"
    fi

    echo
    echo "Proposed changes to $RESOLV_CONF:"
    echo
    diff -u "$RESOLV_CONF" "$RESOLV_CONF_NEW" || true

    if (( DHCPCD_CONF_CHANGED )); then
        echo
        echo "Proposed changes to $DHCPCD_CONF:"
        echo
        diff -u "$DHCPCD_CONF" "$DHCPCD_CONF_NEW" || true
    else
        echo
        echo "$DHCPCD_CONF already contains 'nohook resolv.conf'; no change required."
    fi

    echo
}


# ------------------------------------------------------------------------------------------
# Commit and transition
# ------------------------------------------------------------------------------------------

disable_cloud_hosts_management() {
    (( CLOUD_INIT_PRESENT )) || return 0

    echo
    echo "Disabling cloud-init /etc/hosts management..."

    mkdir -p /etc/cloud/cloud.cfg.d

    printf '%s\n' \
        '# /etc/hosts is managed locally after static network configuration.' \
        'manage_etc_hosts: false' \
        > "$CLOUD_HOSTS_DISABLE"
}

commit_configuration() {
    local interfaces_backup

    interfaces_backup="${INTERFACES}.bak-$(date '+%Y%m%d-%H%M%S')"

    cp -a "$INTERFACES" "$interfaces_backup"

    if (( DHCPCD_CONF_CHANGED )); then
        mv "$DHCPCD_CONF_NEW" "$DHCPCD_CONF"
    else
        rm -f "$DHCPCD_CONF_NEW"
    fi

    mv "$INTERFACES_NEW" "$INTERFACES"
    disable_cloud_hosts_management
    mv "$HOSTS_NEW" "$HOSTS"

    echo
    echo "Configuration backup:"
    echo "  $interfaces_backup"

    stop_dhcpcd

    mv "$RESOLV_CONF_NEW" "$RESOLV_CONF"
}

stop_dhcpcd() {
    local pidfile_iface="/run/dhcpcd/${SELECTED_IFACE}.pid"
    local pidfile_manager="/run/dhcpcd/pid"

    if [[ ${METHOD[$SELECTED_IFACE]} != "dhcp" || -z $LIVE_ADDRESS ]]; then
        echo
        echo "No active DHCP lease needs to be stopped for $SELECTED_IFACE."
        return 0
    fi

    if [[ ! -e $pidfile_iface && ! -e $pidfile_manager ]]; then
        echo
        warn "No running dhcpcd PID file was found."
        warn "The current network configuration will be left untouched."
        return 0
    fi

    echo
    echo "Stopping dhcpcd for $SELECTED_IFACE while preserving current network state..."

    if ! dhcpcd --persistent --exit "$SELECTED_IFACE"; then
        warn "dhcpcd could not be stopped cleanly."
        warn "$RESOLV_CONF has NOT been replaced because the running DHCP client may still overwrite it."
        warn "The staged static resolver configuration remains at $RESOLV_CONF_NEW."
        exit 2
    fi

    verify_live_network
}

verify_live_network() {
    local current_address
    local current_gateway

    if [[ -n $LIVE_ADDRESS ]]; then
        current_address=$(
            interface_addresses "$SELECTED_IFACE" |
            awk -v expected="$LIVE_ADDRESS" '$0 == expected { print; exit }'
        )

        if [[ -z $current_address ]]; then
            warn "$LIVE_ADDRESS is no longer present on $SELECTED_IFACE after stopping dhcpcd."
        fi
    fi

    if [[ -n $LIVE_GATEWAY ]]; then
        current_gateway=$(
            interface_gateway "$SELECTED_IFACE" |
            awk -v expected="$LIVE_GATEWAY" '$0 == expected { print; exit }'
        )

        if [[ -z $current_gateway ]]; then
            warn "Default gateway $LIVE_GATEWAY is no longer present on $SELECTED_IFACE after stopping dhcpcd."
        fi
    fi
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    preflight

    discover_interfaces
    show_interfaces
    choose_interface

    capture_network_configuration
    determine_hostname_identity
    choose_static_configuration

    stage_interfaces
    stage_hosts
    stage_resolv_conf
    stage_dhcpcd_conf

    show_staged_changes

    yesno "Apply this static network configuration?" N || exit 0

    commit_configuration

    echo
    echo "Static network configuration complete."
    echo
    echo "  Interface: $SELECTED_IFACE"
    echo "  Address:   $SELECTED_ADDRESS"
    echo "  Gateway:   $SELECTED_GATEWAY"
    echo "  Hostname:  $HOST_SHORT"
    echo "  FQDN:      $HOST_FQDN"
    echo

    if [[ -n $LIVE_ADDRESS ]]; then
        echo "The current live network configuration was preserved; networking was not restarted."
    else
        echo "Networking was not restarted or otherwise activated by this script."
    fi

    echo "The selected static configuration will be used normally on subsequent boots."
}

main "$@"
