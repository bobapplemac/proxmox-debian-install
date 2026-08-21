# Debian Proxmox Install Scripts

A collection of Bash scripts for provisioning Proxmox VE, Proxmox Backup Server, and Proxmox Datacenter Manager on top of a fresh Debian 13 (Trixie) installation.

The primary goal of this project is to provide a repeatable Debian-first Proxmox installation workflow while retaining control over disk partitioning, filesystems, network interface naming, and other base-system configuration.

These scripts are intended for systems where the standard Proxmox installer does not provide the desired storage or operating-system layout.

## Why Install Proxmox on Debian?

Proxmox officially supports installation on top of Debian in addition to installation using the Proxmox ISO.

Installing Debian first provides substantially more control over the base system, particularly disk partitioning and filesystem selection.

My preferred basic layout is generally:

- UEFI boot
- A normal EFI System Partition
- A single root filesystem
- XFS for the root filesystem where appropriate
- No LVM unless it is specifically useful
- Additional storage configured separately as needed

This makes it possible to build relatively simple systems such as:

```text
System disk
├── EFI System Partition  -> /boot/efi
└── Root partition        -> /        (XFS)
```

rather than requiring an LVM-based layout.

## Why XFS?

XFS is useful for Proxmox hosts where VM or container storage will consist of ordinary files rather than ZFS or Ceph volumes.

For example:

```text
XFS filesystem
    |
    +-- raw disk images
    |
    +-- qcow2 disk images
```

`qcow2` remains useful when file-level snapshots are desired.

ZFS is an excellent option in many environments, but it is not always the appropriate storage backend. File-backed storage on XFS may be preferable for systems such as:

- Single-drive hosts
- Systems with limited RAM
- Systems using a hardware RAID controller
- Systems where ZFS features are unnecessary
- Environments where conventional filesystem storage is preferred

The included `setup-xfs-storage.sh` helper can configure additional local XFS storage when needed.

## Supported Environment

These scripts intentionally target a narrow and predictable environment.

### Proxmox VE

Expected starting point:

- Fresh Debian 13 / Trixie installation
- Installed using the Debian netinst installer
- amd64
- UEFI boot
- Bare metal

The PVE installation is split into two stages so the system can reboot into the Proxmox kernel before the full Proxmox VE package set and Debian-kernel cleanup are performed.

### Proxmox Backup Server

Supported starting points:

- Fresh Debian 13 / Trixie netinst installation on bare metal
- Fresh Debian 13 / Trixie standard installation in a virtual machine
- Fresh UEFI Debian 13 cloud image in a virtual machine

The installer automatically distinguishes virtual machines from bare metal.

Virtual machines receive the minimal PBS package set and retain the Debian kernel.

Bare-metal systems receive the full PBS package set, including the Proxmox kernel.

The `--force-bare-metal` option is available for testing the complete bare-metal installation path inside a VM.

### Proxmox Datacenter Manager

Supported starting points:

- Fresh Debian 13 / Trixie netinst installation on bare metal
- Fresh Debian 13 / Trixie standard installation in a virtual machine
- Fresh UEFI Debian 13 cloud image in a virtual machine

As with PBS, the installer automatically selects the appropriate VM or bare-metal package/kernel policy.

The `--force-bare-metal` option may be used to exercise the full bare-metal path inside a VM.

## Quick Start

Convenience scripts are provided under `quick-start/` to download an ordered working set of the canonical scripts for a particular installation workflow.

The downloaded copies are given numeric prefixes so they sort in the recommended execution order. The canonical repository filenames remain unchanged.

### Proxmox VE

Fresh Debian 13 / Trixie netinst installation on bare metal:

```bash
curl -fsSL https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/quick-start/pve.sh | bash
```

Creates:

```text
proxmox-pve/
├── 20-setup-nics.sh
├── 30-setup-static-ip.sh
├── 40-disable-ipv6.sh
├── 50-setup-swapfile.sh
├── 60-setup-xfs-storage.sh
├── 90-install-pve-part1.sh
└── 95-install-pve-part2.sh
```

### Proxmox Backup Server

Fresh standard Debian installation:

```bash
curl -fsSL https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/quick-start/pbs.sh | bash
```

Fresh Debian cloud image:

```bash
curl -fsSL https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/quick-start/pbs-cloud.sh | bash
```

### Proxmox Datacenter Manager

Fresh standard Debian installation:

```bash
curl -fsSL https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/quick-start/pdm.sh | bash
```

Fresh Debian cloud image:

```bash
curl -fsSL https://raw.githubusercontent.com/bobapplemac/proxmox-debian-install/main/quick-start/pdm-cloud.sh | bash
```

The quick-start scripts only download and rename the canonical scripts. They do not execute provisioning steps automatically.

After downloading, enter the generated directory, review the scripts, and run the applicable files in numeric order. Optional steps and required reboot points are printed by the quick-start script and documented below.

## Network Interface Naming

These scripts use persistent systemd `.link` files for physical Ethernet interface naming.

The naming convention is:

```text
eth0
eth1
eth2
```

for separate single-port adapters, and:

```text
eth0p1
eth0p2

eth1p1
eth1p2
eth1p3
eth1p4
```

for ports belonging to the same multi-port adapter.

This is intentionally different from the naming convention produced by:

```text
pve-network-interface-pinning generate
```

The goal is to keep interface names short, predictable, and physically meaningful while still using systemd's supported persistent interface-name mechanism.

`setup-nics.sh` generates the corresponding `.link` files and updates the network configuration safely.

## Included Scripts

### `setup-nics.sh`

Configures persistent physical Ethernet interface names using systemd `.link` files.

It supports both single-port and multi-port adapters and updates `/etc/network/interfaces` to match the selected names.

A reboot is required before the new names become active.

### `setup-static-ip.sh`

Converts the selected interface to a persistent static IPv4 configuration.

It also configures persistent DNS, validates hostname/FQDN resolution, and updates `/etc/hosts` as required.

The script does not restart networking in-place.

A reboot is recommended after configuration.

### `setup-ifupdown.sh`

Converts a supported Netplan/systemd-networkd configuration to traditional Debian ifupdown networking.

This is primarily intended for Debian cloud images.

Supported source configurations are intentionally simple:

- One Ethernet interface
- DHCPv4 or one static IPv4 address
- Optional default gateway
- IPv4 DNS servers
- DNS search domains
- Optional exact MAC match
- Optional Netplan `set-name`

Where Netplan already contains a MAC-based `set-name` mapping, that mapping is preserved using a systemd `.link` file.

The conversion does not interrupt the active network session. A reboot is required to activate the new ifupdown configuration.

### `disable-ipv6.sh`

Optionally disables IPv6 system-wide and disables the standard IPv6 entries in `/etc/hosts`.

### `setup-swapfile.sh`

Creates and enables a swap file on systems that do not already have swap configured.

A modest amount of swap is recommended even on systems with substantial RAM unless there is a specific reason to operate without it.

### `setup-xfs-storage.sh`

Creates a local XFS filesystem on an additional disk and mounts it persistently.

This is useful for local file-backed Proxmox storage using raw or qcow2 disk images.

### `install-pve-part1.sh`

Performs the first stage of the Proxmox VE installation.

This stage primarily:

- Configures the Proxmox repository
- Installs the Proxmox kernel
- Prepares the system to reboot into that kernel

A reboot is required before running part 2.

### `install-pve-part2.sh`

Completes the Proxmox VE installation after the system has booted into a `-pve` kernel.

Among other tasks, it:

- Installs the full `proxmox-ve` package set
- Configures Postfix for local-only delivery
- Installs and enables Chrony
- Installs and enables `ksmtuned`
- Installs Open vSwitch
- Installs `open-iscsi`
- Disables Proxmox enterprise repositories
- Removes the remaining Debian kernel packages
- Removes `os-prober`
- Enables periodic filesystem trimming
- Configures `/mnt/local -> /var/lib/vz`
- Performs final installation verification

### `install-pbs.sh`

Installs Proxmox Backup Server.

The script automatically selects between:

```text
VM:
    proxmox-backup-server
    Debian kernel retained

Bare metal:
    proxmox-backup
    Proxmox kernel installed
```

On bare-metal UEFI installations, the script also validates and prepares the GRUB bootloader before rebooting into the Proxmox kernel.

### `install-pdm.sh`

Installs Proxmox Datacenter Manager.

The script automatically selects between the VM-oriented and bare-metal package sets.

The bare-metal path installs the Proxmox kernel and performs the corresponding bootloader and Debian-kernel cleanup.

## Recommended Installation Order

### Proxmox VE — Debian Netinst / Bare Metal

```text
setup-nics.sh
reboot

setup-static-ip.sh
reboot

disable-ipv6.sh            # optional

setup-swapfile.sh          # optional; recommended if no swap exists

setup-xfs-storage.sh       # optional; as needed

install-pve-part1.sh
reboot

install-pve-part2.sh
reboot
```

## Proxmox Backup Server — Debian Netinst / Standard Debian

For bare metal or a conventional Debian VM:

```text
setup-nics.sh
reboot

setup-static-ip.sh
reboot

disable-ipv6.sh            # optional

setup-swapfile.sh          # optional; recommended if no swap exists

setup-xfs-storage.sh       # optional; as needed

install-pbs.sh
reboot
```

On a VM, `install-pbs.sh` automatically uses the VM-oriented package set and retains the Debian kernel.

## Proxmox Backup Server — Debian Cloud Image

First convert the cloud-image networking stack:

```text
setup-ifupdown.sh
reboot
```

Then, if additional network configuration is required:

```text
setup-nics.sh              # optional
reboot                     # required if setup-nics.sh was run

setup-static-ip.sh         # optional
reboot                     # recommended if setup-static-ip.sh was run
```

`setup-nics.sh` is normally unnecessary when the original Netplan configuration already contained a suitable MAC-based interface mapping, because `setup-ifupdown.sh` preserves that mapping as a systemd `.link` file.

`setup-static-ip.sh` is normally unnecessary when the original Netplan configuration was already static and the converted configuration contains the desired address.

Continue with:

```text
disable-ipv6.sh            # optional

setup-swapfile.sh          # optional; recommended if no swap exists

setup-xfs-storage.sh       # optional; as needed

install-pbs.sh
reboot
```

## Proxmox Datacenter Manager — Debian Netinst / Standard Debian

```text
setup-nics.sh
reboot

setup-static-ip.sh
reboot

disable-ipv6.sh            # optional

setup-swapfile.sh          # optional; recommended if no swap exists

install-pdm.sh
reboot
```

On a VM, `install-pdm.sh` automatically uses the VM-oriented package set and retains the Debian kernel.

## Proxmox Datacenter Manager — Debian Cloud Image

First convert the cloud-image networking stack:

```text
setup-ifupdown.sh
reboot
```

Then, if needed:

```text
setup-nics.sh              # optional
reboot                     # required if setup-nics.sh was run

setup-static-ip.sh         # optional
reboot                     # recommended if setup-static-ip.sh was run
```

As with PBS:

- `setup-nics.sh` may be omitted when the original Netplan configuration already provided a suitable interface mapping.
- `setup-static-ip.sh` may be omitted when the original Netplan configuration was already static and the resulting ifupdown configuration is correct.

Continue with:

```text
disable-ipv6.sh            # optional

setup-swapfile.sh          # optional; recommended if no swap exists

install-pdm.sh
reboot
```

## Cloud-Image Networking

Debian cloud images commonly use:

```text
Netplan
    |
    +-- systemd-networkd
```

The rest of these scripts assume conventional Debian networking through:

```text
/etc/network/interfaces
    |
    +-- ifupdown
```

`setup-ifupdown.sh` performs this conversion while deliberately leaving the currently active network connection untouched.

After the conversion:

```text
systemd-networkd
        ↓
      reboot
        ↓
ifupdown
```

The PBS and PDM installers subsequently replace classic `ifupdown` with Proxmox-recommended `ifupdown2`.

## Reboots Are Intentional

Several scripts deliberately avoid restarting networking or replacing a running kernel underneath the active system.

The documented reboots are therefore part of the installation process rather than merely precautionary.

In particular:

- Interface-name changes are activated by reboot.
- Static networking is verified after reboot rather than being forcefully restarted remotely.
- Netplan-to-ifupdown conversion takes effect on reboot.
- PVE part 1 requires a reboot into the Proxmox kernel before part 2.
- Bare-metal PBS/PDM installations retain the currently running Debian kernel until the first boot into the newly installed Proxmox kernel.

This approach makes the scripts somewhat more conservative at the cost of additional reboots.

## Safety Philosophy

These scripts are intentionally conservative.

They generally:

- Validate the expected Debian release
- Validate the existing network state
- Validate hostname and `/etc/hosts` configuration
- Refuse unsupported or ambiguous configurations
- Simulate potentially disruptive APT transactions before applying them
- Avoid live network restarts
- Avoid removing the currently running kernel
- Validate generated configuration before committing it
- Verify important services and package state after installation

They are designed for fresh installations and are **not** intended to repair arbitrary existing Proxmox or Debian systems.

When a configuration is outside the expected scope, the scripts generally stop rather than attempt to guess the desired result.

## License

Unless otherwise noted, the scripts in this repository are released under the Zero-Clause BSD license:

```text
SPDX-License-Identifier: 0BSD
```

See `LICENSE` for the complete license text.

## Disclaimer

These scripts modify networking, package repositories, bootloader configuration, kernels, filesystems, and storage devices.

Review the scripts and understand the intended changes before running them.

Test changes in a non-production environment first, maintain current backups, and ensure that out-of-band or console access is available when modifying networking or boot configuration.

This project is independent of Proxmox Server Solutions GmbH and is not an official Proxmox project.
