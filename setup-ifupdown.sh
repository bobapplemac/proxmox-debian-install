#!/bin/bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        setup-ifupdown.sh
# Revision:    r10
# Modified:    2026-08-21
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Description: Converts a simple Debian 13 Netplan/systemd-networkd configuration to ifupdown.
#              The script is intentionally limited to one configured Ethernet interface with
#              either DHCPv4 or one static IPv4 address. Simple cloud-image MAC match/set-name
#              configurations are supported. When Netplan uses set-name, the rename is preserved
#              with a systemd .link file under /usr/local/lib/systemd/network before Netplan is
#              removed. The currently working kernel network state is used to build the replacement
#              configuration, while Netplan's merged configuration is parsed to validate scope and
#              determine mode.
#
#              The conversion installs ifupdown and dhcpcd-base, writes /etc/network/interfaces,
#              preserves the current resolver state in a regular /etc/resolv.conf, configures
#              dhcpcd to use a MAC-based client ID instead of DUID, preserves Netplan set-name
#              interface naming with systemd .link files when required, disables cloud-init network
#              generation, disables Netplan YAML files by appending .disabled, disables
#              systemd-networkd for future boots, enables networking.service, and removes the
#              Netplan runtime/generator packages. For static IPv4 conversions, the script also
#              updates /etc/hosts so the system hostname resolves to the real static IPv4 address
#              instead of 127.0.1.1, adds "nohook resolv.conf" to /etc/dhcpcd.conf so the
#              preserved static resolver configuration cannot be overwritten by dhcpcd, and
#              disables cloud-init management of /etc/hosts so the hostname mapping persists.
#              If the system does not yet have an FQDN, a resolver-provided default domain or
#              single search domain is used automatically; otherwise the user is prompted for
#              the domain to use.
#
# Requirements:
#              bash
#              coreutils
#              debianutils
#              dpkg
#              findutils
#              grep
#              hostname
#              initramfs-tools
#              iproute2
#              netplan.io
#              python3
#              python3-yaml
#              sed
#              systemd
#
# Supported Netplan Configuration:
#              One Ethernet interface only
#              DHCPv4, or exactly one static IPv4 address/prefix
#              Zero or one IPv4 default gateway
#              IPv4 DNS servers and search domains
#              Optional exact MAC match
#              Optional set-name using the setup-nics eth# / eth#p# naming convention
#
# Output (static conversions additionally):
#              /etc/hosts
#              /etc/cloud/cloud.cfg.d/99-disable-manage-etc-hosts.cfg
#
# Notes:
#              This script does not restart networking. systemd-networkd is left running for the
#              current session and is disabled only for future boots. Reboot after conversion
#              before making further network changes.
#
#              Staged interfaces are validated with classic ifupdown before
#              /etc/network/interfaces is replaced.
#
#              Existing /etc/netplan/*.yaml files are renamed to *.yaml.disabled. Netplan config
#              originating from /run/netplan or /lib/netplan is considered unsupported and causes
#              the script to stop rather than guess.
# ------------------------------------------------------------------------------------------

set -euo pipefail

INTERFACES=/etc/network/interfaces
INTERFACES_NEW=/etc/network/interfaces.new
INTERFACES_D=/etc/network/interfaces.d
DHCPCD_CONF=/etc/dhcpcd.conf
HOSTS=/etc/hosts
HOSTS_NEW=/etc/hosts.new
RESOLV_CONF=/etc/resolv.conf
RESOLV_NEW=/etc/resolv.conf.new
CLOUD_NETWORK_DISABLE=/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
CLOUD_HOSTS_DISABLE=/etc/cloud/cloud.cfg.d/99-disable-manage-etc-hosts.cfg
LINK_DIR=/usr/local/lib/systemd/network

IFACE=""
MODE=""
NETPLAN_ID=""
NETPLAN_MATCH_MAC=""
NETPLAN_SET_NAME=""
LINK_FILE=""
LINK_ALREADY_CORRECT=false
NETPLAN_ADDRESS=""
NETPLAN_GATEWAY=""
NETPLAN_DNS=""
NETPLAN_SEARCH=""
LIVE_ADDRESS=""
LIVE_GATEWAY=""
LIVE_DOMAIN=""
HOST_DOMAIN=""
HOSTS_FQDN=""
HOSTS_SHORT=""

NETPLAN_INSTALLED=false
NETPLAN_GENERATOR_INSTALLED=false
IFUPDOWN_INSTALLED=false
IFUPDOWN2_INSTALLED=false
NETWORKD_ACTIVE=false
NETWORKD_ENABLED=false
NETWORKING_ACTIVE=false
NETWORKING_ENABLED=false
CLOUD_INIT_DISABLED=false
CLOUD_NETWORK_DISABLED=false

STATE_MISMATCH=0

declare -a LIVE_DNS LIVE_SEARCH NETPLAN_FILES


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

    echo
    warn "The system hostname '$HOSTS_SHORT' does not currently have a domain/FQDN."

    if (( ${#LIVE_SEARCH[@]} > 1 )); then
        echo "Resolver search domains:" >&2
        printf '  %s\n' "${LIVE_SEARCH[@]}" >&2
    elif (( ${#LIVE_SEARCH[@]} == 0 )); then
        echo "No resolver domain or search domain was discovered." >&2
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
    [[ $MODE == static ]] || return 0

    local current_fqdn
    local candidate=""

    HOSTS_SHORT=$(hostname --short 2>/dev/null || true)
    current_fqdn=$(hostname --fqdn 2>/dev/null || true)

    [[ -n $HOSTS_SHORT ]] || die "Unable to determine the system short hostname."

    if [[ -n $current_fqdn && $current_fqdn != "$HOSTS_SHORT" && $current_fqdn == *.* ]]; then
        HOSTS_FQDN=$current_fqdn
        HOST_DOMAIN=${current_fqdn#*.}
        return 0
    fi

    if [[ -n $LIVE_DOMAIN ]]; then
        candidate=${LIVE_DOMAIN%.}

        if valid_domain_name "$candidate"; then
            HOST_DOMAIN=$candidate
            echo
            echo "No FQDN is currently configured; using resolver domain '$HOST_DOMAIN'."
        else
            warn "Ignoring invalid resolver domain '$LIVE_DOMAIN'."
        fi
    fi

    if [[ -z $HOST_DOMAIN && ${#LIVE_SEARCH[@]} -eq 1 ]]; then
        candidate=${LIVE_SEARCH[0]%.}

        if valid_domain_name "$candidate"; then
            HOST_DOMAIN=$candidate
            echo
            echo "No FQDN is currently configured; using resolver search domain '$HOST_DOMAIN'."
        else
            warn "Ignoring invalid resolver search domain '${LIVE_SEARCH[0]}'."
        fi
    fi

    if [[ -z $HOST_DOMAIN ]]; then
        prompt_for_host_domain
    fi

    HOSTS_FQDN="$HOSTS_SHORT.$HOST_DOMAIN"

    echo "Host identity will use:"
    printf '  %-18s %s\n' "Hostname:" "$HOSTS_SHORT"
    printf '  %-18s %s\n' "FQDN:" "$HOSTS_FQDN"
}

package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null |
        grep -qx 'install ok installed'
}

service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

service_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}


# ------------------------------------------------------------------------------------------
# Platform and network-stack detection
# ------------------------------------------------------------------------------------------

check_platform() {
    [[ -r /etc/os-release ]] || die "/etc/os-release was not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    [[ ${ID:-} == debian ]] ||
        die "This script requires Debian."

    [[ ${VERSION_ID:-} == 13 ]] ||
        die "This script requires Debian 13."

    [[ ${VERSION_CODENAME:-} == trixie ]] ||
        die "This script requires Debian 13 (Trixie)."
}

collect_stack_state() {
    package_installed netplan.io && NETPLAN_INSTALLED=true || NETPLAN_INSTALLED=false
    package_installed netplan-generator && NETPLAN_GENERATOR_INSTALLED=true || NETPLAN_GENERATOR_INSTALLED=false
    package_installed ifupdown && IFUPDOWN_INSTALLED=true || IFUPDOWN_INSTALLED=false
    package_installed ifupdown2 && IFUPDOWN2_INSTALLED=true || IFUPDOWN2_INSTALLED=false

    service_active systemd-networkd.service && NETWORKD_ACTIVE=true || NETWORKD_ACTIVE=false
    service_enabled systemd-networkd.service && NETWORKD_ENABLED=true || NETWORKD_ENABLED=false
    service_active networking.service && NETWORKING_ACTIVE=true || NETWORKING_ACTIVE=false
    service_enabled networking.service && NETWORKING_ENABLED=true || NETWORKING_ENABLED=false

    [[ -e /etc/cloud/cloud-init.disabled ]] && CLOUD_INIT_DISABLED=true || CLOUD_INIT_DISABLED=false
    [[ -e $CLOUD_NETWORK_DISABLE ]] && CLOUD_NETWORK_DISABLED=true || CLOUD_NETWORK_DISABLED=false
}

print_stack_state() {
    echo
    echo "Network configuration state:"
    echo
    printf '  %-39s %s\n' "netplan.io installed:" "$NETPLAN_INSTALLED"
    printf '  %-39s %s\n' "netplan-generator installed:" "$NETPLAN_GENERATOR_INSTALLED"
    printf '  %-39s %s\n' "systemd-networkd active:" "$NETWORKD_ACTIVE"
    printf '  %-39s %s\n' "systemd-networkd enabled:" "$NETWORKD_ENABLED"
    echo
    printf '  %-39s %s\n' "ifupdown installed:" "$IFUPDOWN_INSTALLED"
    printf '  %-39s %s\n' "ifupdown2 installed:" "$IFUPDOWN2_INSTALLED"
    printf '  %-39s %s\n' "/etc/network/interfaces present:" "$([[ -f $INTERFACES ]] && echo true || echo false)"
    printf '  %-39s %s\n' "networking.service active:" "$NETWORKING_ACTIVE"
    printf '  %-39s %s\n' "networking.service enabled:" "$NETWORKING_ENABLED"
    echo
    printf '  %-39s %s\n' "cloud-init disabled:" "$CLOUD_INIT_DISABLED"
    printf '  %-39s %s\n' "cloud-init networking disabled:" "$CLOUD_NETWORK_DISABLED"
    echo
}

classify_stack() {
    # Intentional post-conversion/pre-reboot state: classic ifupdown is fully configured,
    # networkd has been disabled for future boots, but it may still be running now.
    if $IFUPDOWN_INSTALLED &&
       ! $IFUPDOWN2_INSTALLED &&
       [[ -f $INTERFACES ]] &&
       $NETWORKING_ENABLED &&
       ! $NETWORKD_ENABLED &&
       ! $NETPLAN_INSTALLED &&
       ! $NETPLAN_GENERATOR_INSTALLED
    then
        if $NETWORKD_ACTIVE; then
            echo "Detected network stack: ifupdown (conversion complete; reboot pending)"
        else
            echo "Detected network stack: ifupdown"
        fi
        echo "No conversion is required."
        exit 0
    fi

    # This script intentionally targets Debian's classic ifupdown stack. Do not silently
    # reinterpret a system that already has ifupdown2 installed.
    if $IFUPDOWN2_INSTALLED; then
        die "ifupdown2 is installed; this script targets classic ifupdown and will not modify an existing ifupdown2 installation."
    fi

    if $NETWORKD_ENABLED && $NETWORKING_ENABLED; then
        die "Both systemd-networkd and networking.service are enabled; network ownership is ambiguous."
    fi

    if $NETPLAN_INSTALLED &&
       { $NETWORKD_ENABLED || $NETWORKD_ACTIVE; } &&
       ! $NETWORKING_ENABLED
    then
        echo "Detected network stack: Netplan / systemd-networkd"
        return 0
    fi

    if $IFUPDOWN_INSTALLED && [[ -f $INTERFACES ]] && ! $NETWORKD_ENABLED; then
        die "The system appears partially converted to ifupdown, but Netplan components remain or networking.service is not enabled."
    fi

    die "Unable to identify a supported Netplan/systemd-networkd source configuration."
}


# ------------------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------------------

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
    printf '  %s\n' "${files[@]}"
    echo
    echo "The generated $INTERFACES will source this directory."
    echo "Existing files could conflict with the converted configuration."
    echo

    yesno "Continue anyway?" N || exit 1
}

check_existing_staging_files() {
    local file

    for file in "$INTERFACES_NEW" "$HOSTS_NEW" "$RESOLV_NEW"; do
        [[ -e $file ]] || continue

        echo
        warn "$file already exists."
        yesno "Overwrite it?" N || exit 1
        rm -f -- "$file"
    done
}

preflight() {
    (( EUID == 0 )) || die "Run this script as root."
    [[ -t 0 ]] || die "This script requires an interactive terminal."

    check_platform

    local cmd

    # Check only commands needed to classify the current stack first. A fully
    # converted system no longer has Netplan installed and should still exit cleanly.
    for cmd in \
        apt-get awk cat chmod cp date diff dpkg-query find grep hostname ip mkdir mktemp mv \
        python3 rm sed sort systemctl touch tr update-initramfs
    do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    collect_stack_state
    print_stack_state
    classify_stack

    # Reaching this point means a Netplan source configuration needs to be converted.
    command -v netplan >/dev/null 2>&1 ||
        die "The Netplan command is required to convert the current source configuration."

    python3 -c 'import yaml' >/dev/null 2>&1 ||
        die "The Python YAML module is required but could not be imported."

    check_interfaces_d
    check_existing_staging_files
}


# ------------------------------------------------------------------------------------------
# Netplan validation
# ------------------------------------------------------------------------------------------

collect_netplan_files() {
    local -a etc_files=()
    local -a run_files=()
    local -a lib_files=()
    local file

    [[ -d /etc/netplan ]] &&
        mapfile -t etc_files < <(
            find /etc/netplan -maxdepth 1 \
                \( -type f -o -type l \) \
                -name '*.yaml' -print |
            sort
        )

    [[ -d /run/netplan ]] &&
        mapfile -t run_files < <(
            find /run/netplan -maxdepth 1 \
                \( -type f -o -type l \) \
                -name '*.yaml' -print |
            sort
        )

    [[ -d /lib/netplan ]] &&
        mapfile -t lib_files < <(
            find /lib/netplan -maxdepth 1 \
                \( -type f -o -type l \) \
                -name '*.yaml' -print |
            sort
        )

    if (( ${#run_files[@]} || ${#lib_files[@]} )); then
        echo
        warn "Netplan YAML was found outside /etc/netplan:"
        printf '  %s\n' "${run_files[@]}" "${lib_files[@]}"
        echo
        die "This script only converts Netplan configuration stored under /etc/netplan."
    fi

    (( ${#etc_files[@]} )) ||
        die "No active /etc/netplan/*.yaml configuration files were found."

    NETPLAN_FILES=("${etc_files[@]}")

    for file in "${NETPLAN_FILES[@]}"; do
        [[ ! -e ${file}.disabled ]] ||
            die "Cannot disable $file because ${file}.disabled already exists."
    done
}

parse_netplan() {
    local merged
    local parsed
    local netplan_err
    local -a values

    netplan_err=$(mktemp)

    if ! merged=$(netplan get 2>"$netplan_err"); then
        cat "$netplan_err" >&2
        rm -f -- "$netplan_err"
        die "Netplan could not parse the current configuration."
    fi

    # Netplan may emit informational diagnostics or warnings on stderr even when
    # `netplan get` succeeds. Keep those visible to the user, but never mix them
    # into stdout because stdout is the YAML document parsed below.
    if [[ -s $netplan_err ]]; then
        cat "$netplan_err" >&2
    fi

    rm -f -- "$netplan_err"

    if ! parsed=$(printf '%s\n' "$merged" | python3 -c '
import ipaddress
import sys
import yaml

cfg = yaml.safe_load(sys.stdin) or {}
net = cfg.get("network", cfg)

if not isinstance(net, dict):
    raise SystemExit("network configuration is not a mapping")

renderer = str(net.get("renderer", "networkd")).lower()
if renderer not in ("networkd", "none"):
    raise SystemExit(f"unsupported Netplan renderer: {renderer}")

for key in ("bridges", "bonds", "vlans", "wifis", "modems", "tunnels", "dummy-devices"):
    value = net.get(key)
    if value:
        raise SystemExit(f"unsupported Netplan device type/configuration: {key}")

ethernets = net.get("ethernets") or {}
if not isinstance(ethernets, dict) or len(ethernets) != 1:
    raise SystemExit(f"expected exactly one configured Ethernet interface; found {len(ethernets) if isinstance(ethernets, dict) else 0}")

netdef_id, conf = next(iter(ethernets.items()))
if not isinstance(conf, dict):
    raise SystemExit("Ethernet configuration is not a mapping")

if not isinstance(netdef_id, str) or not netdef_id or any(ch.isspace() for ch in netdef_id):
    raise SystemExit("unsupported Netplan interface identifier")

# Cloud images commonly use a MAC match plus set-name to pin the virtual NIC.
# Support that narrow form while continuing to reject broader matching rules.
match = conf.get("match")
match_mac = ""
if match is not None:
    if not isinstance(match, dict):
        raise SystemExit("match must be a mapping")

    unknown_match = sorted(set(match) - {"macaddress"})
    if unknown_match:
        raise SystemExit("unsupported match option(s): " + ", ".join(unknown_match))

    match_mac = str(match.get("macaddress", "")).lower()
    if not match_mac:
        raise SystemExit("a match stanza must contain an exact macaddress")

    parts = match_mac.split(":")
    if len(parts) != 6 or any(len(part) != 2 or any(ch not in "0123456789abcdef" for ch in part) for part in parts):
        raise SystemExit("only an exact Ethernet MAC address match is supported")

set_name = conf.get("set-name")
if set_name is not None:
    if not isinstance(set_name, str) or not set_name or any(ch.isspace() for ch in set_name):
        raise SystemExit("unsupported set-name value")
    if not match_mac:
        raise SystemExit("set-name requires an exact MAC match so the rename can be preserved safely")
    if not __import__("re").fullmatch(r"eth[0-9]+(?:p[1-9][0-9]*)?", set_name):
        raise SystemExit("set-name is supported only for the eth# / eth#p# naming convention")

iface_renderer = str(conf.get("renderer", renderer)).lower()
if iface_renderer not in ("networkd", "none"):
    raise SystemExit(f"unsupported interface renderer: {iface_renderer}")

if conf.get("dhcp6") is True:
    raise SystemExit("DHCPv6 configuration is not supported")

if conf.get("routing-policy"):
    raise SystemExit("routing-policy configuration is not supported")

allowed = {
    "accept-ra", "addresses", "dhcp4", "dhcp4-overrides", "dhcp6",
    "dhcp-identifier", "gateway4", "link-local", "match", "nameservers", "optional",
    "renderer", "routes", "set-name"
}
unknown = sorted(set(conf) - allowed)
if unknown:
    raise SystemExit("unsupported Ethernet option(s): " + ", ".join(unknown))

def ipv4(value):
    try:
        return isinstance(ipaddress.ip_address(str(value)), ipaddress.IPv4Address)
    except ValueError:
        return False

def ipv4_interface(value):
    try:
        return isinstance(ipaddress.ip_interface(str(value)), ipaddress.IPv4Interface)
    except ValueError:
        return False

addresses = conf.get("addresses") or []
if not isinstance(addresses, list):
    raise SystemExit("addresses must be a list")

simple_addresses = []
for value in addresses:
    if isinstance(value, dict):
        raise SystemExit("address mappings/lifetimes are not supported")
    if not ipv4_interface(value):
        raise SystemExit(f"non-IPv4 or invalid address is not supported: {value}")
    simple_addresses.append(str(value))

dhcp4 = conf.get("dhcp4") is True

if dhcp4:
    if simple_addresses:
        raise SystemExit("mixed DHCPv4 and static IPv4 addressing is not supported")
    mode = "dhcp"

    overrides = conf.get("dhcp4-overrides") or {}
    if not isinstance(overrides, dict):
        raise SystemExit("dhcp4-overrides must be a mapping")

    unsupported_overrides = sorted(set(overrides) - {"use-dns", "use-domains"})
    if unsupported_overrides:
        raise SystemExit("unsupported dhcp4-overrides option(s): " + ", ".join(unsupported_overrides))

    if overrides.get("use-dns", True) is not True:
        raise SystemExit("DHCP use-dns=false is not supported")
    if overrides.get("use-domains", True) is not True:
        raise SystemExit("DHCP use-domains=false is not supported")

    if conf.get("nameservers"):
        raise SystemExit("static nameservers combined with DHCPv4 are not supported")
else:
    if len(simple_addresses) != 1:
        raise SystemExit(f"static mode requires exactly one IPv4 address; found {len(simple_addresses)}")
    mode = "static"

routes = conf.get("routes") or []
if not isinstance(routes, list):
    raise SystemExit("routes must be a list")

route_gateway = ""
if routes:
    if len(routes) != 1 or not isinstance(routes[0], dict):
        raise SystemExit("only one default IPv4 route is supported")

    route = routes[0]
    allowed_route = {"to", "via", "metric", "on-link"}
    route_unknown = sorted(set(route) - allowed_route)
    if route_unknown:
        raise SystemExit("unsupported route option(s): " + ", ".join(route_unknown))

    to = str(route.get("to", ""))
    if to not in ("default", "0.0.0.0/0"):
        raise SystemExit("only a default IPv4 route is supported")

    via = route.get("via")
    if via is not None:
        if not ipv4(via):
            raise SystemExit("default gateway must be IPv4")
        route_gateway = str(via)

legacy_gateway = conf.get("gateway4")
if legacy_gateway is not None:
    if route_gateway:
        raise SystemExit("both gateway4 and a default route are configured")
    if not ipv4(legacy_gateway):
        raise SystemExit("gateway4 must be IPv4")
    route_gateway = str(legacy_gateway)

nameservers = conf.get("nameservers") or {}
if not isinstance(nameservers, dict):
    raise SystemExit("nameservers must be a mapping")

ns_addresses = nameservers.get("addresses") or []
if not isinstance(ns_addresses, list):
    raise SystemExit("nameserver addresses must be a list")

for value in ns_addresses:
    if not ipv4(value):
        raise SystemExit(f"non-IPv4 DNS server is not supported: {value}")

search = nameservers.get("search") or []
if not isinstance(search, list):
    raise SystemExit("DNS search domains must be a list")

print(netdef_id)
print(match_mac or "-")
print(set_name or "-")
print(mode)
print(simple_addresses[0] if simple_addresses else "-")
print(route_gateway or "-")
print(" ".join(str(x) for x in ns_addresses) or "-")
print(" ".join(str(x) for x in search) or "-")
' 2>&1)
    then
        printf '%s\n' "$parsed" >&2
        die "The merged Netplan configuration is outside this script's supported scope."
    fi

    mapfile -t values <<< "$parsed"

    (( ${#values[@]} >= 8 )) ||
        die "Unexpected result while parsing Netplan configuration."

    NETPLAN_ID=${values[0]}
    NETPLAN_MATCH_MAC=${values[1]}
    NETPLAN_SET_NAME=${values[2]}
    MODE=${values[3]}
    NETPLAN_ADDRESS=${values[4]}
    NETPLAN_GATEWAY=${values[5]}
    NETPLAN_DNS=${values[6]}
    NETPLAN_SEARCH=${values[7]}

    [[ $NETPLAN_MATCH_MAC == - ]] && NETPLAN_MATCH_MAC=""
    [[ $NETPLAN_SET_NAME == - ]] && NETPLAN_SET_NAME=""
    [[ $NETPLAN_ADDRESS == - ]] && NETPLAN_ADDRESS=""
    [[ $NETPLAN_GATEWAY == - ]] && NETPLAN_GATEWAY=""
    [[ $NETPLAN_DNS == - ]] && NETPLAN_DNS=""
    [[ $NETPLAN_SEARCH == - ]] && NETPLAN_SEARCH=""

    resolve_netplan_interface
}


resolve_netplan_interface() {
    local live_mac
    local path
    local -a matches=()

    if [[ -n $NETPLAN_SET_NAME ]]; then
        IFACE=$NETPLAN_SET_NAME

        [[ -e /sys/class/net/$IFACE ]] ||
            die "Netplan set-name resolves to '$IFACE', but no live interface with that name exists."

        live_mac=$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$IFACE/address")

        [[ $live_mac == "$NETPLAN_MATCH_MAC" ]] ||
            die "Netplan MAC match '$NETPLAN_MATCH_MAC' does not match live $IFACE MAC '$live_mac'."

        LINK_FILE="$LINK_DIR/40-$NETPLAN_SET_NAME.link"
        return 0
    fi

    if [[ -n $NETPLAN_MATCH_MAC ]]; then
        for path in /sys/class/net/*; do
            [[ -e $path/address ]] || continue
            live_mac=$(tr '[:upper:]' '[:lower:]' < "$path/address")
            [[ $live_mac == "$NETPLAN_MATCH_MAC" ]] || continue
            matches+=("${path##*/}")
        done

        (( ${#matches[@]} == 1 )) ||
            die "Expected one live interface matching MAC '$NETPLAN_MATCH_MAC'; found ${#matches[@]}."

        IFACE=${matches[0]}
        return 0
    fi

    IFACE=$NETPLAN_ID

    [[ -e /sys/class/net/$IFACE ]] ||
        die "Netplan configures '$IFACE', but no live interface with that name exists."
}

link_file_matches() {
    local file=$1
    local expected
    local actual

    expected=$(printf '%s\n' \
        '[Match]' \
        "MACAddress=$NETPLAN_MATCH_MAC" \
        'Type=ether' \
        '' \
        '[Link]' \
        "Name=$NETPLAN_SET_NAME")

    actual=$(cat "$file" 2>/dev/null || true)
    [[ $actual == "$expected" ]]
}

check_existing_link_files() {
    [[ -n $NETPLAN_SET_NAME ]] || return 0

    local -a conflicts=()
    local dir
    local file

    LINK_ALREADY_CORRECT=false

    if [[ -e $LINK_FILE || -L $LINK_FILE ]]; then
        if link_file_matches "$LINK_FILE"; then
            LINK_ALREADY_CORRECT=true
        else
            die "$LINK_FILE already exists but does not match the Netplan MAC/name mapping."
        fi
    fi

    for dir in \
        /usr/local/lib/systemd/network \
        /etc/systemd/network
    do
        [[ -d $dir ]] || continue

        while IFS= read -r file; do
            [[ $file == "$LINK_FILE" ]] && continue
            conflicts+=("$file")
        done < <(
            find "$dir" -maxdepth 1 \
                \( -type f -o -type l \) \
                -name '*.link' \
                -print |
            sort
        )
    done

    if $LINK_ALREADY_CORRECT; then
        echo
        echo "Existing persistent interface pin is already correct:"
        echo "  $LINK_FILE"
    fi

    (( ${#conflicts[@]} )) || return 0

    echo
    warn "Other systemd .link files were found:"
    echo
    printf '  %s\n' "${conflicts[@]}"
    echo
    echo "Existing .link files may affect interface naming or conflict with"
    echo "the Netplan set-name mapping being preserved by this script."
    echo

    yesno "Continue anyway?" N || exit 1
}


# ------------------------------------------------------------------------------------------
# Live network-state collection and comparison
# ------------------------------------------------------------------------------------------

collect_live_address() {
    local -a addresses=()

    mapfile -t addresses < <(
        ip -4 -o addr show dev "$IFACE" scope global |
            awk '{print $4}'
    )

    (( ${#addresses[@]} == 1 )) ||
        die "Expected exactly one live global IPv4 address on $IFACE; found ${#addresses[@]}."

    LIVE_ADDRESS=${addresses[0]}
}

collect_live_gateway() {
    local -a routes=()
    local route
    local dev
    local gateway

    mapfile -t routes < <(
        ip -4 route show default |
            awk '{print}'
    )

    (( ${#routes[@]} <= 1 )) ||
        die "More than one live IPv4 default route was detected."

    LIVE_GATEWAY=""

    if (( ${#routes[@]} == 1 )); then
        route=${routes[0]}
        dev=$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }}' <<< "$route")
        gateway=$(awk '{for (i=1; i<=NF; i++) if ($i == "via") { print $(i+1); exit }}' <<< "$route")

        [[ $dev == "$IFACE" ]] ||
            die "The live IPv4 default route uses '$dev', not Netplan interface '$IFACE'."

        LIVE_GATEWAY=$gateway
    fi
}

collect_live_resolver() {
    local line
    local token
    local -a dns=()
    local -a search=()

    LIVE_DOMAIN=""

    if command -v resolvectl >/dev/null 2>&1 &&
       service_active systemd-resolved.service
    then
        line=$(resolvectl dns "$IFACE" 2>/dev/null || true)
        line=${line#*:}

        for token in $line; do
            [[ $token == *:* ]] && continue
            [[ $token =~ ^[0-9]+(\.[0-9]+){3}$ ]] || continue
            [[ $token == 127.* ]] && continue
            dns+=("$token")
        done

        line=$(resolvectl domain "$IFACE" 2>/dev/null || true)
        line=${line#*:}

        for token in $line; do
            [[ $token == '~'* ]] && continue
            search+=("$token")
        done
    fi

    if (( ${#dns[@]} == 0 )); then
        [[ -e $RESOLV_CONF ]] || die "$RESOLV_CONF does not exist."

        mapfile -t dns < <(
            awk '
                $1 == "nameserver" && $2 ~ /^[0-9]+(\.[0-9]+){3}$/ && $2 !~ /^127\./ {
                    print $2
                }
            ' "$RESOLV_CONF" |
            awk '!seen[$0]++'
        )

        LIVE_DOMAIN=$(
            awk '$1 == "domain" { print $2; exit }' "$RESOLV_CONF"
        )

        mapfile -t search < <(
            awk '
                $1 == "search" {
                    for (i=2; i<=NF; i++) print $i
                }
            ' "$RESOLV_CONF" |
            awk '!seen[$0]++'
        )

        if (( ${#search[@]} == 0 )) && [[ -n $LIVE_DOMAIN ]]; then
            search+=("$LIVE_DOMAIN")
        fi
    fi

    (( ${#dns[@]} )) ||
        die "No usable live IPv4 DNS servers could be determined."

    LIVE_DNS=("${dns[@]}")
    LIVE_SEARCH=("${search[@]}")
}

compare_state() {
    local live_dns_joined
    local live_search_joined

    live_dns_joined=$(printf '%s\n' "${LIVE_DNS[@]}" | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    live_search_joined=$(printf '%s\n' "${LIVE_SEARCH[@]}" | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')

    if [[ $MODE == static ]]; then
        if [[ $NETPLAN_ADDRESS != "$LIVE_ADDRESS" ]]; then
            warn "Netplan address '$NETPLAN_ADDRESS' does not match live address '$LIVE_ADDRESS'."
            STATE_MISMATCH=1
        fi

        if [[ -n $NETPLAN_GATEWAY && $NETPLAN_GATEWAY != "$LIVE_GATEWAY" ]]; then
            warn "Netplan gateway '$NETPLAN_GATEWAY' does not match live gateway '${LIVE_GATEWAY:-(none)}'."
            STATE_MISMATCH=1
        fi

        if [[ -n $NETPLAN_DNS ]]; then
            local netplan_dns_sorted
            netplan_dns_sorted=$(tr ' ' '\n' <<< "$NETPLAN_DNS" | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')

            if [[ $netplan_dns_sorted != "$live_dns_joined" ]]; then
                warn "Netplan DNS servers do not exactly match the live resolver state."
                STATE_MISMATCH=1
            fi
        fi

        if [[ -n $NETPLAN_SEARCH ]]; then
            local netplan_search_sorted
            netplan_search_sorted=$(tr ' ' '\n' <<< "$NETPLAN_SEARCH" | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')

            if [[ $netplan_search_sorted != "$live_search_joined" ]]; then
                warn "Netplan DNS search domains do not exactly match the live resolver state."
                STATE_MISMATCH=1
            fi
        fi
    fi
}

show_configuration() {
    echo
    echo "Netplan configuration files:"
    printf '  %s\n' "${NETPLAN_FILES[@]}"

    echo
    echo "Merged Netplan configuration:"
    echo
    netplan get

    echo
    echo "Conversion summary:"
    echo
    printf '  %-18s %s\n' "Netplan ID:" "$NETPLAN_ID"
    printf '  %-18s %s\n' "Interface:" "$IFACE"
    if [[ -n $NETPLAN_MATCH_MAC ]]; then
        printf '  %-18s %s\n' "MAC match:" "$NETPLAN_MATCH_MAC"
    fi
    if [[ -n $NETPLAN_SET_NAME ]]; then
        printf '  %-18s %s\n' "Netplan set-name:" "$NETPLAN_SET_NAME"
        printf '  %-18s %s\n' "Persistent pin:" "$LINK_FILE"
    fi
    printf '  %-18s %s\n' "Netplan mode:" "$MODE"

    if [[ $MODE == static ]]; then
        printf '  %-18s %s\n' "Netplan address:" "$NETPLAN_ADDRESS"
        printf '  %-18s %s\n' "Netplan gateway:" "${NETPLAN_GATEWAY:-(none)}"
    fi

    echo
    echo "Current live state:"
    echo
    printf '  %-18s %s\n' "Address:" "$LIVE_ADDRESS"
    printf '  %-18s %s\n' "Gateway:" "${LIVE_GATEWAY:-(none)}"
    printf '  %-18s %s\n' "DNS servers:" "${LIVE_DNS[*]}"
    printf '  %-18s %s\n' "Search domains:" "${LIVE_SEARCH[*]:-(none)}"

    if [[ $MODE == static ]]; then
        printf '  %-18s %s\n' "Hostname:" "$HOSTS_SHORT"
        printf '  %-18s %s\n' "FQDN:" "$HOSTS_FQDN"
    fi

    if (( STATE_MISMATCH )); then
        echo
        warn "The persistent Netplan configuration differs from the current live state."
        warn "The generated ifupdown configuration will preserve the CURRENT LIVE state."
        echo
        yesno "Continue with the live values?" N || exit 1
    else
        echo
        echo "Netplan configuration and current live state are compatible with conversion."
    fi
}


check_netplan_purge_safety() {
    local simulation
    local unexpected

    simulation=$(apt-get -s purge netplan.io netplan-generator 2>&1) || {
        printf '%s\n' "$simulation" >&2
        die "APT could not simulate Netplan removal."
    }

    unexpected=$(printf '%s\n' "$simulation" |
        awk '/^(Remv|Purg) / && $2 != "netplan.io" && $2 != "netplan-generator" { print $2 }' |
        sort -u)

    if [[ -n $unexpected ]]; then
        echo
        warn "Removing Netplan would also remove additional packages:"
        while IFS= read -r package; do
            [[ -n $package ]] && printf '  %s\n' "$package"
        done <<< "$unexpected"
        echo
        die "Refusing to continue with an unsafe Netplan package removal plan."
    fi
}


# ------------------------------------------------------------------------------------------
# Staging
# ------------------------------------------------------------------------------------------

stage_interfaces() {
    {
        if [[ -n $NETPLAN_SET_NAME ]]; then
            printf '%s\n' \
                '# Interface names are pinned by systemd .link files in:' \
                "# $LINK_DIR/" \
                ''
        fi

        printf '%s\n' \
            '# Network configuration converted from Netplan by setup-ifupdown.sh' \
            '' \
            'source /etc/network/interfaces.d/*' \
            '' \
            'auto lo' \
            'iface lo inet loopback' \
            '' \
            "allow-hotplug $IFACE"

        if [[ $MODE == dhcp ]]; then
            printf '%s\n' "iface $IFACE inet dhcp"
        else
            printf '%s\n' \
                "iface $IFACE inet static" \
                "    address $LIVE_ADDRESS"

            if [[ -n $LIVE_GATEWAY ]]; then
                printf '%s\n' "    gateway $LIVE_GATEWAY"
            fi
        fi
    } > "$INTERFACES_NEW"
}

stage_hosts() {
    [[ $MODE == static ]] || return 0

    local matches
    local hosts_line
    local static_ip
    local tmp="${HOSTS_NEW}.tmp"

    [[ -f $HOSTS ]] || die "$HOSTS does not exist."

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

    awk -v hostname="$HOSTS_SHORT" '
        $1 == "127.0.1.1" {
            for (i = 2; i <= NF; i++) {
                if ($i == hostname) found = 1
            }
        }
        END { exit !found }
    ' <<< "$hosts_line" ||
        die "The active 127.0.1.1 entry in $HOSTS does not contain the system hostname '$HOSTS_SHORT'."

    static_ip=${LIVE_ADDRESS%/*}

    cp -a "$HOSTS" "$HOSTS_NEW"

    awk \
        -v ip="$static_ip" \
        -v fqdn="$HOSTS_FQDN" \
        -v hostname="$HOSTS_SHORT" '
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
    rm -f -- "$tmp"
}

stage_resolv_conf() {
    {
        if [[ $MODE == static ]]; then
            printf '%s\n' \
                '# Static DNS configuration preserved by setup-ifupdown.sh during Netplan conversion.' \
                '# dhcpcd DNS updates are disabled by "nohook resolv.conf" in /etc/dhcpcd.conf.'
        else
            printf '%s\n' \
                '# Resolver state preserved by setup-ifupdown.sh during Netplan conversion.' \
                '# DHCP may replace this file with lease-provided resolver information.'
        fi

        if (( ${#LIVE_SEARCH[@]} )); then
            printf 'search'
            printf ' %s' "${LIVE_SEARCH[@]}"
            printf '\n'
        fi

        local dns
        for dns in "${LIVE_DNS[@]}"; do
            printf 'nameserver %s\n' "$dns"
        done
    } > "$RESOLV_NEW"
}

show_staged_files() {
    if [[ -n $NETPLAN_SET_NAME ]]; then
        echo
        if $LINK_ALREADY_CORRECT; then
            echo "Existing persistent interface pin (already correct):"
        else
            echo "Proposed persistent interface pin $LINK_FILE:"
        fi
        echo
        printf '%s\n' \
            '[Match]' \
            "MACAddress=$NETPLAN_MATCH_MAC" \
            'Type=ether' \
            '' \
            '[Link]' \
            "Name=$NETPLAN_SET_NAME"
    fi

    echo
    echo "Proposed $INTERFACES:"
    echo
    cat "$INTERFACES_NEW"

    if [[ $MODE == static ]]; then
        echo
        echo "Proposed $HOSTS:"
        echo
        cat "$HOSTS_NEW"

        echo
        echo "Changes to $HOSTS:"
        echo
        diff -u "$HOSTS" "$HOSTS_NEW" || true

        echo
        echo "Cloud-init /etc/hosts management will be disabled:"
        echo "  $CLOUD_HOSTS_DISABLE"
        echo "  manage_etc_hosts: false"
    fi

    echo
    echo "Proposed $RESOLV_CONF:"
    echo
    cat "$RESOLV_NEW"

    if [[ -f $INTERFACES ]]; then
        echo
        echo "Changes to $INTERFACES:"
        echo
        diff -u "$INTERFACES" "$INTERFACES_NEW" || true
    fi

    echo
    yesno "Convert this system to ifupdown?" N || exit 0
}


# ------------------------------------------------------------------------------------------
# Conversion
# ------------------------------------------------------------------------------------------

install_ifupdown() {
    echo
    echo "Installing ifupdown and dhcpcd-base..."

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ifupdown dhcpcd-base

    package_installed ifupdown ||
        die "ifupdown was not installed successfully."

    ! package_installed ifupdown2 ||
        die "ifupdown2 is unexpectedly installed after installing ifupdown."

    command -v ifquery >/dev/null 2>&1 ||
        die "ifupdown was installed, but ifquery was not found."
}

configure_dhcpcd() {
    echo
    echo "Configuring dhcpcd defaults..."

    [[ -f $DHCPCD_CONF ]] || touch "$DHCPCD_CONF"

    sed -Ei \
        's/^[[:space:]]*duid([[:space:]].*)?$/#duid/;
         s/^[[:space:]]*#?[[:space:]]*clientid([[:space:]].*)?$/clientid/' \
        "$DHCPCD_CONF"

    grep -qxF 'clientid' "$DHCPCD_CONF" ||
        printf '%s\n' 'clientid' >> "$DHCPCD_CONF"

    if [[ $MODE == static ]] &&
       ! grep -Eq '^[[:space:]]*nohook[[:space:]].*resolv\.conf([[:space:],]|$)' "$DHCPCD_CONF"
    then
        [[ ! -s $DHCPCD_CONF ]] || printf '\n' >> "$DHCPCD_CONF"
        printf '%s\n' \
            '# DNS is statically configured in /etc/resolv.conf by setup-ifupdown.sh.' \
            'nohook resolv.conf' \
            >> "$DHCPCD_CONF"
    fi
}

write_persistent_link() {
    [[ -n $NETPLAN_SET_NAME ]] || return 0

    if $LINK_ALREADY_CORRECT; then
        echo
        echo "Persistent interface pin is already correct; leaving it unchanged."
        return 0
    fi

    echo
    echo "Writing persistent interface pin:"

    mkdir -p "$LINK_DIR"

    printf '%s\n' \
        '[Match]' \
        "MACAddress=$NETPLAN_MATCH_MAC" \
        'Type=ether' \
        '' \
        '[Link]' \
        "Name=$NETPLAN_SET_NAME" \
        > "$LINK_FILE"

    chmod 0644 "$LINK_FILE"
    echo "  $LINK_FILE"
}

update_initramfs_for_link() {
    [[ -n $NETPLAN_SET_NAME ]] || return 0

    echo
    echo "Updating initramfs for persistent interface naming..."
    update-initramfs -u -k all
}

validate_staged_interfaces() {
    echo
    echo "Validating staged ifupdown configuration..."

    if ! ifquery -i "$INTERFACES_NEW" lo >/dev/null; then
        die "$INTERFACES_NEW does not contain a valid loopback configuration."
    fi

    if ! ifquery -i "$INTERFACES_NEW" "$IFACE" >/dev/null; then
        die "$INTERFACES_NEW does not contain a valid configuration for $IFACE."
    fi

    # Dry-run the selected interface as an additional check that ifupdown can
    # translate the stanza into the expected low-level commands without changing
    # the currently active network session.
    if ! ifup -n -i "$INTERFACES_NEW" "$IFACE" >/dev/null; then
        die "$INTERFACES_NEW failed the ifupdown dry-run for $IFACE."
    fi

    echo "Staged ifupdown configuration validated successfully."
}

commit_interfaces() {
    local backup

    if [[ -f $INTERFACES ]]; then
        backup="${INTERFACES}.bak-$(date '+%Y%m%d-%H%M%S')"
        cp -a "$INTERFACES" "$backup"
        echo "Backup: $backup"
    fi

    mv "$INTERFACES_NEW" "$INTERFACES"
    chmod 0644 "$INTERFACES"
}

commit_hosts() {
    [[ $MODE == static ]] || return 0

    mv "$HOSTS_NEW" "$HOSTS"
}

commit_resolv_conf() {
    rm -f -- "$RESOLV_CONF"
    mv "$RESOLV_NEW" "$RESOLV_CONF"
    chmod 0644 "$RESOLV_CONF"
}

disable_cloud_networking() {
    echo
    echo "Disabling cloud-init network generation..."

    mkdir -p /etc/cloud/cloud.cfg.d

    printf '%s\n' \
        '# Network configuration is managed by ifupdown.' \
        'network: {config: disabled}' \
        > "$CLOUD_NETWORK_DISABLE"
}

disable_cloud_hosts_management() {
    [[ $MODE == static ]] || return 0

    echo
    echo "Disabling cloud-init /etc/hosts management..."

    mkdir -p /etc/cloud/cloud.cfg.d

    printf '%s\n' \
        '# /etc/hosts is managed locally after static network configuration.' \
        'manage_etc_hosts: false' \
        > "$CLOUD_HOSTS_DISABLE"
}

disable_netplan_yaml() {
    local file

    echo
    echo "Disabling Netplan YAML configuration:"

    for file in "${NETPLAN_FILES[@]}"; do
        mv "$file" "${file}.disabled"
        printf '  %s -> %s\n' "$file" "${file}.disabled"
    done
}

switch_services() {
    echo
    echo "Configuring networking services for the next boot..."

    systemctl daemon-reload
    systemctl enable networking.service

    systemctl disable systemd-networkd.service 2>/dev/null || true
    systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true

    echo "systemd-networkd has NOT been stopped; the current network session remains active."
}

purge_netplan() {
    local simulation

    echo
    echo "Simulating removal of Netplan runtime components..."

    simulation=$(apt-get -s purge netplan.io netplan-generator 2>&1) || {
        printf '%s\n' "$simulation" >&2
        die "APT could not simulate Netplan removal."
    }

    printf '%s\n' "$simulation" |
        awk '/^(Remv|Purg) / { print "  " $0 }'

    local unexpected
    unexpected=$(printf '%s\n' "$simulation" |
        awk '/^(Remv|Purg) / && $2 != "netplan.io" && $2 != "netplan-generator" { print $2 }' |
        sort -u)

    if [[ -n $unexpected ]]; then
        echo
        warn "APT would remove additional packages:"
        printf '  %s\n' $unexpected
        echo
        die "Refusing to remove packages other than netplan.io and netplan-generator."
    fi

    echo
    echo "Removing Netplan runtime components..."
    DEBIAN_FRONTEND=noninteractive apt-get purge -y netplan.io netplan-generator
}

verify_conversion() {
    collect_stack_state

    echo
    echo "Conversion status:"
    echo
    printf '  %-39s %s\n' "ifupdown installed:" "$IFUPDOWN_INSTALLED"
    printf '  %-39s %s\n' "ifupdown2 installed:" "$IFUPDOWN2_INSTALLED"
    printf '  %-39s %s\n' "networking.service enabled:" "$NETWORKING_ENABLED"
    printf '  %-39s %s\n' "systemd-networkd enabled:" "$NETWORKD_ENABLED"
    printf '  %-39s %s\n' "systemd-networkd still active:" "$NETWORKD_ACTIVE"
    printf '  %-39s %s\n' "netplan.io installed:" "$NETPLAN_INSTALLED"
    printf '  %-39s %s\n' "netplan-generator installed:" "$NETPLAN_GENERATOR_INSTALLED"
    printf '  %-39s %s\n' "cloud-init networking disabled:" "$([[ -e $CLOUD_NETWORK_DISABLE ]] && echo true || echo false)"
    if [[ -n $NETPLAN_SET_NAME ]]; then
        printf '  %-39s %s\n' "persistent interface pin:" "$LINK_FILE"
    fi

    $IFUPDOWN_INSTALLED || die "ifupdown is not installed after conversion."
    ! $IFUPDOWN2_INSTALLED || die "ifupdown2 is unexpectedly installed after conversion."
    $NETWORKING_ENABLED || die "networking.service is not enabled after conversion."
    ! $NETWORKD_ENABLED || die "systemd-networkd is still enabled after conversion."
    ! $NETPLAN_INSTALLED || die "netplan.io is still installed after conversion."
    ! $NETPLAN_GENERATOR_INSTALLED || die "netplan-generator is still installed after conversion."
    if [[ -n $NETPLAN_SET_NAME ]]; then
        [[ -f $LINK_FILE ]] || die "Persistent interface pin $LINK_FILE is missing after conversion."
        link_file_matches "$LINK_FILE" || die "Persistent interface pin $LINK_FILE does not contain the expected mapping."
    fi

    if [[ $MODE == static ]]; then
        local static_ip=${LIVE_ADDRESS%/*}

        grep -Eq '^[[:space:]]*nohook[[:space:]].*resolv\.conf([[:space:],]|$)' "$DHCPCD_CONF" ||
            die "$DHCPCD_CONF does not contain 'nohook resolv.conf' after static conversion."

        grep -Eq '^[[:space:]]*manage_etc_hosts:[[:space:]]*false([[:space:]]|$)' "$CLOUD_HOSTS_DISABLE" ||
            die "$CLOUD_HOSTS_DISABLE does not disable cloud-init /etc/hosts management."

        awk \
            -v ip="$static_ip" \
            -v fqdn="$HOSTS_FQDN" \
            -v hostname="$HOSTS_SHORT" '
            $1 == ip {
                have_fqdn = 0
                have_hostname = 0
                for (i = 2; i <= NF; i++) {
                    if ($i == fqdn) have_fqdn = 1
                    if ($i == hostname) have_hostname = 1
                }
                if (have_fqdn && have_hostname) found = 1
            }
            END { exit !found }
        ' "$HOSTS" ||
            die "$HOSTS does not map $HOSTS_FQDN/$HOSTS_SHORT to $static_ip after conversion."
    fi

    echo
    echo "Network conversion complete."
    echo
    echo "The current network connection was intentionally left untouched."
    echo "Reboot the system to activate ifupdown networking."
    echo
    echo "After reboot, verify networking before running setup-nics.sh or setup-static-ip.sh."
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    preflight
    collect_netplan_files
    parse_netplan
    check_existing_link_files

    collect_live_address
    collect_live_gateway
    collect_live_resolver
    determine_hostname_identity
    compare_state
    check_netplan_purge_safety
    show_configuration

    stage_interfaces
    stage_hosts
    stage_resolv_conf
    show_staged_files

    install_ifupdown
    validate_staged_interfaces
    configure_dhcpcd
    write_persistent_link
    commit_interfaces
    disable_cloud_hosts_management
    commit_hosts
    commit_resolv_conf
    disable_cloud_networking
    disable_netplan_yaml
    switch_services
    purge_netplan
    update_initramfs_for_link
    verify_conversion
}

main "$@"
