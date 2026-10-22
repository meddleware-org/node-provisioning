# Verification

## What runs offline (`bash tests/run.sh`)

- golden renders of the example site (with and without an Ubuntu Pro token), byte-identical on repeat
- type and parser unit tests; every fail-closed case (missing, unknown, duplicate, ill-typed, wrong mode, leaked secret)
- the three image formats: label, size, mode, contents equal to the rendered files
- the public-hygiene check, including that findings never print the matched value
- `validate`: the Subiquity autoinstall schema (pinned commit and checksum), `cloud-init schema`, `netplan generate`

## What only a VM can prove

Run `tests/vm/` (manual: needs KVM, OVMF and the Ubuntu Server ISO): a serial-matched install, the negative cases that
must abort before storage is touched, fail-closed late-commands, no swap after reboot, key-only SSH, whether installer
logs retain secrets, a reinstall that preserves the data disk, and seed delivery by CD-ROM, USB floppy and HTTP.

## What only real hardware proves

How a BMC presents its virtual floppy, the boot menu edit, real network interface names, link aggregation and VLAN
tagging during the installer, real disk serial strings and enumeration order, and vendor-specific kernel behaviour.
Record each hardware run (date, firmware, result) in the consuming project's runbook, not here.
