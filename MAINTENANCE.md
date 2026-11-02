# Maintenance Notes

This repository is intentionally a small collection of human-readable shell scripts rather
than an installation framework. Changes should preserve that simplicity and keep the scripts
useful when downloaded and inspected independently of the repository.

## Repository conventions

- Canonical scripts live in the repository root and use descriptive filenames.
- `setup-*.sh` and `disable-ipv6.sh` are shared helpers used by more than one Proxmox product.
- `install-*.sh` contains the product-specific installation and validation policy for Proxmox
  VE (PVE), Proxmox Backup Server (PBS), or Proxmox Datacenter Manager (PDM).
- The PVE installer remains split into two stages because a reboot into the Proxmox kernel is
  required between them.
- Scripts should remain standalone. Avoid required runtime libraries, generated configuration,
  or other dependencies that make a downloaded script harder to audit.
- Some duplicated shell code between product installers is intentional. In particular, PBS and
  PDM should be reviewed together when changing Debian validation, networking, repositories,
  package installation, kernel policy, bootloader handling, or cleanup behavior.

## Quick-start workflows

The scripts under `quick-start/` are download helpers, not installers or orchestrators. They:

1. Download the latest canonical scripts from the `main` branch.
2. Give the working copies numeric prefixes that show the recommended execution order.
3. Mark the downloaded shell scripts executable.
4. Write the workflow instructions to `RUNBOOK.txt` and display the same instructions in the
   terminal.

Keep the downloaded file lists, numeric prefixes, and runbook instructions synchronized with
the recommended workflows in `README.md`. Quick-start scripts should not automatically execute
configuration or installation steps; the user should retain control of each operation and
reboot boundary.

## Making changes

- Prefer direct, readable shell over abstraction for its own sake.
- Keep validation and safety checks close to the operation they protect.
- Preserve existing conservative behavior around network changes, package removal, bootloader
  changes, and reboots.
- Update a script's revision and modified date when its behavior changes.
- Update `README.md` when supported platforms, package policy, networking behavior, workflow
  order, or reboot requirements change.
- Review every quick-start workflow when adding, removing, or renaming a canonical script.

Before committing shell-script changes, at minimum run `bash -n` against every affected script.
Installation and migration behavior should be validated manually on an appropriate disposable
or recoverable system when practical.
