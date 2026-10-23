# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow [Semantic Versioning](https://semver.org/).

## [0.0.1] - 2026-10-23

First version, extracted from the platform workspace's in-tree OS tooling.

### Added

- `bin/node-provisioning` with `render`, `validate`, `build-seed`, `node-setup`, `check-hygiene` and `version`.
- Autoinstall seed rendering from a private **site** (strict, schema-typed `KEY=value` files plus two site-owned network
  fragments), validated against the pinned Subiquity 26.04.1 autoinstall schema, `cloud-init schema` and `netplan generate`;
  images in three formats (ISO, 4 MiB VFAT, 1.44 MB FAT12 for a BMC virtual floppy).
- Node-setup scripts 00–08 and a runner (`run.sh`) with fixed order and failure semantics; new `08-hardening.sh`.
- Public-hygiene scan (`scripts/check-public-hygiene.sh`) with a site-derived denylist, a history scanner (`scripts/scan-history.sh`) and a pre-commit hook; release workflow (deterministic
  `git archive` tarball, keyless cosign bundle, GitHub attestation, GitHub Release and OCI publish); a manual QEMU/KVM VM test
  matrix (`tests/vm/`: probe, install, setup, scrub, negative, reinstall), run against Ubuntu Server 26.04.1.

### Security

- Disks are selected by udev `ID_SERIAL` with no default; the installer aborts before touching storage unless exactly one disk
  carries the OS serial and exactly one the data serial.
- The data-disk script works only on the named disk, ignores labels on other devices, mounts by UUID and refuses unrecognised
  partitions unless explicitly told otherwise.
- Multi-line installer commands fail closed; a firewall failure still enables the firewall with SSH allowed; an invalid sshd
  configuration is rolled back before activation.
- Secrets are read from 0600 files or the environment, never printed, passed in argv or written to tracked files; seeds are mode 0600.
- Images are byte-reproducible for the same inputs.
- Administrator names the installer refuses (`admin`, `root`, `operator`, ...) are rejected when the seed is rendered (built-in list always; the installer's own pinned list when fetched).
- `08-hardening.sh` redacts the password hash and any token in the installer's root-only copy of the seed's user-data.

### Changed (relative to the in-tree tooling it replaces)

- No swap partition and `swap: size: 0`; explicit timezone; `apt.fallback` is a site key; the Ubuntu Pro token appears once.
- Preflight checks the OS and data disks by serial; the telemetry hosts block is merged entry by entry.
- The `ntp:` block of the old cloud-init reference was not carried over (Ubuntu 25.10+ uses chrony with NTS).
