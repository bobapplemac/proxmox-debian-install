#!/bin/bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        setup-xfs-storage.sh
# Revision:    r6
# Modified:    2026-08-20
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Description: Configures auxiliary local XFS storage on otherwise unused block devices.
#              Enumerates eligible whole-disk devices, displays hardware, physical-path, and existing
#              layout information, suggests a local-* storage label, and requires explicit destructive
#              confirmation before wiping the selected device.
#
#              The selected device is revalidated immediately before destructive operations,
#              cleared of existing filesystem/RAID signatures and old partition-table metadata,
#              verified clean, repartitioned as GPT with one XFS partition spanning the usable
#              device, mounted at /mnt/<label>, and added persistently to /etc/fstab using its GPT
#              PARTLABEL. Multiple devices can be configured in one run.
#
# Naming:
#              Suggested local-storage labels follow these conventions where hardware can be
#              identified reliably:
#
#                  local-boss
#                  local-raid-##
#                  local-hdd-##
#                  local-ssd-##
#                  local-nvme-##
#
#              Suggestions are not enforced. If the selected device already has one valid GPT
#              PARTLABEL, that label is suggested for reuse. Custom lowercase labels containing
#              letters, numbers, and hyphens are accepted. GPT partition labels are limited to 36
#              ASCII characters by this script.
#
# Requirements:
#              bash
#              coreutils
#              findutils
#              gdisk
#              grep
#              parted
#              systemd
#              util-linux
#              xfsprogs
#
# Output:
#              GPT partition with the selected PARTLABEL
#              XFS filesystem on the new partition
#              /mnt/<PARTLABEL>
#              /etc/fstab entry using PARTLABEL=<PARTLABEL>
#
# Notes:
#              This script is intentionally destructive. Devices containing mounted filesystems,
#              active swap, or active holder relationships are excluded from selection. Existing
#              signatures and partition tables on the selected device are permanently destroyed.
# ------------------------------------------------------------------------------------------

set -euo pipefail

FSTAB=/etc/fstab
MOUNT_ROOT=/mnt
DEFAULT_LABEL_PREFIX=local

SELECTED_DRIVE=""
PARTLABEL=""
PARTITION=""

SWAP_DEVICES=""
FSTAB_DEVICES=""

declare -a CANDIDATES EXCLUDED_DEVICES
declare -A EXCLUDED_REASON


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

trim() {
    awk '{$1=$1; print}'
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
        awk basename chmod df find findmnt grep lsblk mkdir mkfs.xfs mount \
        parted partprobe readlink sgdisk sort swapon systemctl udevadm wipefs
    do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    refresh_safety_state
}

refresh_safety_state() {
    SWAP_DEVICES=$(swapon --show=NAME --noheadings 2>/dev/null || true)
    FSTAB_DEVICES=$(findmnt --fstab --evaluate -rn -o SOURCE 2>/dev/null || true)
}


# ------------------------------------------------------------------------------------------
# Device discovery and safety filtering
# ------------------------------------------------------------------------------------------

device_has_mounts() {
    local device=$1

    lsblk -nrpo MOUNTPOINT "$device" 2>/dev/null |
        awk 'NF { found = 1 } END { exit !found }'
}

device_has_active_swap() {
    local device=$1
    local node
    local swap

    [[ -n $SWAP_DEVICES ]] || return 1

    while read -r node; do
        [[ -n $node ]] || continue

        while read -r swap; do
            [[ -n $swap ]] || continue

            if [[ $node == "$swap" ]]; then
                return 0
            fi
        done <<< "$SWAP_DEVICES"
    done < <(
        lsblk -nrpo NAME "$device" 2>/dev/null
    )

    return 1
}

device_has_holders() {
    local device=$1
    local node
    local base

    while read -r node; do
        [[ -n $node ]] || continue
        base=$(basename "$node")

        if [[ -d /sys/class/block/$base/holders ]] &&
           find "/sys/class/block/$base/holders" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null |
               grep -q .
        then
            return 0
        fi
    done < <(
        lsblk -nrpo NAME "$device" 2>/dev/null
    )

    return 1
}

device_is_in_fstab() {
    local device=$1
    local node
    local source
    local canonical

    [[ -n $FSTAB_DEVICES ]] || return 1

    while read -r node; do
        [[ -n $node ]] || continue

        while read -r source; do
            [[ -n $source ]] || continue

            if [[ $source == /dev/* ]]; then
                canonical=$(readlink -f "$source" 2>/dev/null || true)
            else
                canonical=$source
            fi

            if [[ $node == "$canonical" ]]; then
                return 0
            fi
        done <<< "$FSTAB_DEVICES"
    done < <(
        lsblk -nrpo NAME "$device" 2>/dev/null
    )

    return 1
}

device_exclusion_reason() {
    local device=$1
    local readonly

    readonly=$(lsblk -dnro RO "$device" 2>/dev/null | trim)

    if [[ $readonly == 1 ]]; then
        echo "read-only device"
        return 0
    fi

    if device_has_mounts "$device"; then
        echo "contains mounted filesystem(s)"
        return 0
    fi

    if device_has_active_swap "$device"; then
        echo "contains active swap"
        return 0
    fi

    if device_is_in_fstab "$device"; then
        echo "device or child is referenced in /etc/fstab"
        return 0
    fi

    if device_has_holders "$device"; then
        echo "has active holder/device-mapper relationships"
        return 0
    fi

    return 1
}

discover_devices() {
    local device
    local type
    local reason

    CANDIDATES=()
    EXCLUDED_DEVICES=()
    EXCLUDED_REASON=()

    while read -r device type; do
        [[ -n $device && -n $type ]] || continue

        case "$type" in
            disk|raid0|raid1|raid4|raid5|raid6|raid10)
                ;;
            *)
                continue
                ;;
        esac

        if reason=$(device_exclusion_reason "$device"); then
            EXCLUDED_DEVICES+=("$device")
            EXCLUDED_REASON[$device]=$reason
        else
            CANDIDATES+=("$device")
        fi
    done < <(
        lsblk -dnpo NAME,TYPE | sort
    )
}

media_type() {
    local device=$1
    local type
    local rota

    type=$(lsblk -dnro TYPE "$device" 2>/dev/null | trim)
    rota=$(lsblk -dnro ROTA "$device" 2>/dev/null | trim)

    if [[ $type == raid* ]]; then
        echo "RAID"
    elif [[ $device == /dev/nvme* ]]; then
        echo "NVMe"
    elif [[ $rota == 1 ]]; then
        echo "HDD"
    elif [[ $rota == 0 ]]; then
        echo "SSD"
    else
        echo "Unknown"
    fi
}

device_paths() {
    local device=$1
    local canonical_device
    local link
    local target

    [[ -d /dev/disk/by-path ]] || return 0

    canonical_device=$(readlink -f "$device" 2>/dev/null || true)
    [[ -n $canonical_device ]] || return 0

    for link in /dev/disk/by-path/*; do
        [[ -L $link ]] || continue

        target=$(readlink -f "$link" 2>/dev/null || true)

        if [[ $target == "$canonical_device" ]]; then
            basename "$link"
        fi
    done
}

device_summary() {
    local device=$1
    local size
    local media
    local tran
    local vendor
    local model
    local serial
    local -a paths=()
    local i

    # Do not use lsblk raw output for human-readable fields; raw mode escapes
    # spaces and other characters (for example, spaces become \x20).
    size=$(lsblk -dno SIZE "$device" 2>/dev/null | trim)
    media=$(media_type "$device")
    tran=$(lsblk -dno TRAN "$device" 2>/dev/null | trim)
    vendor=$(lsblk -dno VENDOR "$device" 2>/dev/null | trim)
    model=$(lsblk -dno MODEL "$device" 2>/dev/null | trim)
    serial=$(lsblk -dno SERIAL "$device" 2>/dev/null | trim)

    printf '      Size:       %s\n' "${size:--}"
    printf '      Media:      %s\n' "$media"
    printf '      Transport:  %s\n' "${tran:--}"

    if [[ -n $vendor || -n $model ]]; then
        printf '      Hardware:   %s%s%s\n' \
            "$vendor" \
            "${vendor:+${model:+ }}" \
            "$model"
    fi

    if [[ -n $serial ]]; then
        printf '      Serial:     %s\n' "$serial"
    fi

    mapfile -t paths < <(
        device_paths "$device" | sort
    )

    if (( ${#paths[@]} == 1 )); then
        printf '      Path:       %s\n' "${paths[0]}"
    elif (( ${#paths[@]} > 1 )); then
        printf '      Paths:      %s\n' "${paths[0]}"

        for ((i=1; i<${#paths[@]}; i++)); do
            printf '                  %s\n' "${paths[$i]}"
        done
    fi
}

show_candidates() {
    local i
    local device

    echo
    echo "Eligible auxiliary storage devices:"
    echo

    if (( ${#CANDIDATES[@]} == 0 )); then
        echo "  None"
    else
        for ((i=0; i<${#CANDIDATES[@]}; i++)); do
            device=${CANDIDATES[$i]}
            printf '  [%d] %s\n' "$((i + 1))" "$device"
            device_summary "$device"
            echo
        done
    fi

    if (( ${#EXCLUDED_DEVICES[@]} )); then
        echo "Excluded whole-disk devices:"
        echo

        for device in "${EXCLUDED_DEVICES[@]}"; do
            printf '  %s\n' "$device"
            device_summary "$device"
            printf '      Excluded:   %s\n' "${EXCLUDED_REASON[$device]}"
            echo
        done

        echo
    fi
}

choose_device() {
    local input

    while true; do
        read -r -p "Storage device [0 to exit]: " input

        if [[ $input == 0 ]]; then
            return 1
        fi

        if [[ $input =~ ^[0-9]+$ ]] &&
           (( input >= 1 && input <= ${#CANDIDATES[@]} ))
        then
            SELECTED_DRIVE=${CANDIDATES[$((input - 1))]}
            return 0
        fi

        echo "Enter one of the listed device numbers, or 0 to exit."
    done
}

show_selected_layout() {
    echo
    echo "Selected device: $SELECTED_DRIVE"
    echo
    device_summary "$SELECTED_DRIVE"

    echo
    echo "Current block layout:"
    echo
    lsblk -o NAME,SIZE,TYPE,FSTYPE,FSVER,LABEL,PARTLABEL,MOUNTPOINTS "$SELECTED_DRIVE"

    echo
    echo "Detected signatures:"

    local node
    local signatures
    local found=0

    while read -r node; do
        [[ -n $node ]] || continue
        signatures=$(wipefs "$node" 2>/dev/null || true)

        if [[ -n $signatures ]]; then
            echo
            printf '  %s:\n' "$node"
            printf '%s\n' "$signatures"
            found=1
        fi
    done < <(
        lsblk -nrpo NAME "$SELECTED_DRIVE"
    )

    if (( ! found )); then
        echo "  None"
    fi

    echo
}


# ------------------------------------------------------------------------------------------
# Storage label suggestion and validation
# ------------------------------------------------------------------------------------------

selected_device_contains_node() {
    local candidate=$1
    local node

    while read -r node; do
        [[ -n $node ]] || continue

        if [[ $node == "$candidate" ]]; then
            return 0
        fi
    done < <(
        lsblk -nrpo NAME "$SELECTED_DRIVE" 2>/dev/null
    )

    return 1
}

next_storage_number() {
    local max=0
    local node
    local value
    local number

    while read -r node value; do
        [[ -n $value ]] || continue

        # Do not let the selected device's old label advance its own suggested number.
        if selected_device_contains_node "$node"; then
            continue
        fi

        if [[ $value =~ ^local-[a-z0-9-]+-([0-9]+)$ ]]; then
            number=$((10#${BASH_REMATCH[1]}))

            if (( number > max )); then
                max=$number
            fi
        fi
    done < <(
        lsblk -nrpo NAME,PARTLABEL 2>/dev/null || true
    )

    while read -r value; do
        [[ -n $value ]] || continue

        if [[ $value =~ ^local-[a-z0-9-]+-([0-9]+)$ ]]; then
            number=$((10#${BASH_REMATCH[1]}))

            if (( number > max )); then
                max=$number
            fi
        fi
    done < <(
        {
            grep -Eo 'local-[a-z0-9-]+-[0-9]+' "$FSTAB" 2>/dev/null || true
            find "$MOUNT_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null || true
        } | sort -u
    )

    printf '%02d\n' "$((max + 1))"
}

existing_selected_label() {
    local -a labels=()
    local value

    mapfile -t labels < <(
        lsblk -nr -o PARTLABEL "$SELECTED_DRIVE" 2>/dev/null |
            awk 'NF' |
            sort -u
    )

    (( ${#labels[@]} == 1 )) || return 1

    value=${labels[0]}

    [[ $value =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || return 1
    (( ${#value} <= 36 )) || return 1

    # The existing label is useful as a default only if it is not also used elsewhere.
    label_in_use "$value" && return 1

    printf '%s\n' "$value"
}

suggest_label() {
    local device=$1
    local type
    local rota
    local vendor
    local model
    local hardware
    local number

    type=$(lsblk -dnro TYPE "$device" 2>/dev/null | trim)
    rota=$(lsblk -dnro ROTA "$device" 2>/dev/null | trim)
    vendor=$(lsblk -dno VENDOR "$device" 2>/dev/null | trim)
    model=$(lsblk -dno MODEL "$device" 2>/dev/null | trim)
    hardware=$(printf '%s %s' "$vendor" "$model" | tr '[:upper:]' '[:lower:]')
    number=$(next_storage_number)

    if [[ $hardware == *boss* ]]; then
        echo "local-boss"
    elif [[ $type == raid* ||
            $hardware == *raid* ||
            $hardware == *perc* ||
            $hardware == *"virtual disk"* ||
            $hardware == *"logical volume"* ]]
    then
        echo "local-raid-$number"
    elif [[ $device == /dev/nvme* ]]; then
        echo "local-nvme-$number"
    elif [[ $rota == 1 ]]; then
        echo "local-hdd-$number"
    elif [[ $rota == 0 ]]; then
        echo "local-ssd-$number"
    else
        echo "local-storage-$number"
    fi
}

label_in_use() {
    local label=$1
    local mountpoint="$MOUNT_ROOT/$label"
    local node
    local existing_label

    while read -r node existing_label; do
        [[ -n $node && -n $existing_label ]] || continue
        [[ $existing_label == "$label" ]] || continue

        # Reusing a PARTLABEL that already exists on the selected device is safe because the
        # selected device is about to be wiped. The same label on any other device is a conflict.
        if ! selected_device_contains_node "$node"; then
            return 0
        fi
    done < <(
        lsblk -nrpo NAME,PARTLABEL 2>/dev/null || true
    )

    if awk -v source="PARTLABEL=$label" -v target="$mountpoint" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        $1 == source || $2 == target { found = 1 }
        END { exit !found }
    ' "$FSTAB"
    then
        return 0
    fi

    if findmnt -rn -M "$mountpoint" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

mountpoint_has_content() {
    local mountpoint=$1

    [[ -d $mountpoint ]] || return 1

    find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null |
        grep -q .
}

choose_label() {
    local suggested
    local existing
    local input
    local mountpoint

    if existing=$(existing_selected_label); then
        suggested=$existing
    else
        suggested=$(suggest_label "$SELECTED_DRIVE")
    fi

    while true; do
        echo
        read -r -p "Partition/storage label [$suggested]: " input
        input=${input:-$suggested}

        if [[ ! $input =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
            echo "Use lowercase letters, numbers, and hyphens only."
            continue
        fi

        if (( ${#input} > 36 )); then
            echo "The label must be 36 characters or fewer."
            continue
        fi

        if [[ $input != local-* ]]; then
            echo
            warn "'$input' does not follow the recommended local-* naming convention."
            yesno "Use this label anyway?" N || continue
        fi

        if label_in_use "$input"; then
            echo "The label or mountpoint '$input' is already in use."
            continue
        fi

        mountpoint="$MOUNT_ROOT/$input"

        if mountpoint_has_content "$mountpoint"; then
            echo "The mountpoint $mountpoint already exists and is not empty."
            continue
        fi

        PARTLABEL=$input
        return 0
    done
}


# ------------------------------------------------------------------------------------------
# Destructive confirmation and formatting
# ------------------------------------------------------------------------------------------

confirm_wipe() {
    local confirmation

    echo
    warn "ALL DATA on $SELECTED_DRIVE will be permanently destroyed."
    echo
    echo "  Device:     $SELECTED_DRIVE"
    echo "  New label:  $PARTLABEL"
    echo "  Mountpoint: $MOUNT_ROOT/$PARTLABEL"
    echo

    read -r -p "Type '$SELECTED_DRIVE' to confirm: " confirmation

    [[ $confirmation == "$SELECTED_DRIVE" ]] || {
        echo "Confirmation did not match. Device was not modified."
        return 1
    }

    return 0
}

revalidate_selected_device() {
    local reason
    local type

    refresh_safety_state

    if [[ ! -b $SELECTED_DRIVE ]]; then
        warn "$SELECTED_DRIVE is no longer present as a block device."
        warn "The device was not modified."
        return 1
    fi

    type=$(lsblk -dnro TYPE "$SELECTED_DRIVE" 2>/dev/null | trim)

    case "$type" in
        disk|raid0|raid1|raid4|raid5|raid6|raid10)
            ;;
        *)
            warn "$SELECTED_DRIVE is no longer an eligible whole-disk device (type: ${type:-unknown})."
            warn "The device was not modified."
            return 1
            ;;
    esac

    if reason=$(device_exclusion_reason "$SELECTED_DRIVE"); then
        warn "$SELECTED_DRIVE is no longer eligible: $reason"
        warn "The device was not modified."
        return 1
    fi

    return 0
}

verify_wipe() {
    local -a partitions=()
    local signatures

    mapfile -t partitions < <(
        lsblk -nrpo NAME,TYPE "$SELECTED_DRIVE" 2>/dev/null |
            awk '$2 == "part" { print $1 }'
    )

    if (( ${#partitions[@]} )); then
        warn "Partition devices are still present after wiping $SELECTED_DRIVE:"
        printf '  %s\n' "${partitions[@]}" >&2
        die "Refusing to create a new partition table until the stale partition devices are cleared."
    fi

    signatures=$(wipefs "$SELECTED_DRIVE" 2>/dev/null || true)

    if [[ -n $signatures ]]; then
        warn "Signatures remain on $SELECTED_DRIVE after wiping:"
        printf '%s\n' "$signatures" >&2
        die "Refusing to create a new partition table while signatures remain."
    fi

    echo "  Verified: no partition devices or recognized signatures remain."
}

wipe_device() {
    local -a partitions=()
    local partition

    mapfile -t partitions < <(
        lsblk -nrpo NAME,TYPE "$SELECTED_DRIVE" |
            awk '$2 == "part" { print $1 }'
    )

    echo
    echo "Clearing existing signatures and partition metadata from $SELECTED_DRIVE..."

    for partition in "${partitions[@]}"; do
        echo "  wipefs: $partition"
        wipefs -a -f "$partition"
    done

    echo "  zap GPT/MBR: $SELECTED_DRIVE"
    sgdisk --zap-all "$SELECTED_DRIVE"

    echo "  wipefs: $SELECTED_DRIVE"
    wipefs -a -f "$SELECTED_DRIVE"

    partprobe "$SELECTED_DRIVE"
    udevadm settle

    verify_wipe
}

create_partition() {
    local -a partitions=()

    echo
    echo "Creating GPT partition table and XFS partition..."

    parted -s -a optimal "$SELECTED_DRIVE" mklabel gpt
    parted -s -a optimal "$SELECTED_DRIVE" \
        mkpart "$PARTLABEL" xfs 1MiB 100%

    partprobe "$SELECTED_DRIVE"
    udevadm settle

    mapfile -t partitions < <(
        lsblk -nrpo NAME,TYPE "$SELECTED_DRIVE" |
            awk '$2 == "part" { print $1 }'
    )

    (( ${#partitions[@]} == 1 )) ||
        die "Expected exactly one partition on $SELECTED_DRIVE after partitioning; found ${#partitions[@]}."

    PARTITION=${partitions[0]}

    local actual_label
    actual_label=$(lsblk -dnro PARTLABEL "$PARTITION" 2>/dev/null | trim)

    [[ $actual_label == "$PARTLABEL" ]] ||
        die "Created partition label '$actual_label' does not match expected label '$PARTLABEL'."

    echo "  Partition: $PARTITION"
}

create_filesystem() {
    echo
    echo "Creating XFS filesystem on $PARTITION..."
    mkfs.xfs -f "$PARTITION"
}

configure_mount() {
    local mountpoint="$MOUNT_ROOT/$PARTLABEL"

    mkdir -p "$mountpoint"

    printf '%s\n' \
        '' \
        "# $PARTLABEL" \
        "PARTLABEL=$PARTLABEL  $mountpoint  xfs  defaults  0  0" \
        >> "$FSTAB"

    echo
    echo "Validating $FSTAB..."

    if ! findmnt --verify; then
        warn "$FSTAB verification failed after adding $mountpoint."
        die "Manual intervention is required before continuing."
    fi

    systemctl daemon-reload

    echo
    echo "Mounting $mountpoint..."

    if ! mount "$mountpoint"; then
        warn "The filesystem was created and $FSTAB was updated, but the mount failed."
        die "Manual intervention is required before continuing."
    fi

    echo
    echo "Storage configuration complete:"
    echo
    findmnt "$mountpoint"
    echo
    df -hT "$mountpoint"
}

configure_selected_device() {
    show_selected_layout
    choose_label

    confirm_wipe || return 1

    if ! revalidate_selected_device; then
        return 1
    fi

    wipe_device
    create_partition
    create_filesystem
    configure_mount

    return 0
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    preflight

    while true; do
        discover_devices
        show_candidates

        if (( ${#CANDIDATES[@]} == 0 )); then
            echo "No additional eligible storage devices were found."
            return 0
        fi

        if ! choose_device; then
            echo
            echo "No storage device selected."
            return 0
        fi

        if ! configure_selected_device; then
            echo
            echo "Returning to device selection."
            continue
        fi

        refresh_safety_state
        discover_devices

        if (( ${#CANDIDATES[@]} == 0 )); then
            echo
            echo "No additional eligible storage devices were found."
            return 0
        fi

        echo
        if ! yesno "Configure another storage device?" N; then
            return 0
        fi
    done
}

main "$@"
