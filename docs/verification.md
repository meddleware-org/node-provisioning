# Verification

## What runs offline (`bash tests/run.sh`)

- golden renders of the example site (with and without an Ubuntu Pro token), byte-identical on repeat
- type and parser unit tests; every fail-closed case (missing, unknown, duplicate, ill-typed, wrong mode, leaked secret)
- the three image formats: label, size, mode, contents equal to the rendered files
- the public-hygiene check, including that findings never print the matched value
- `validate`: the Subiquity autoinstall schema (pinned commit and checksum), `cloud-init schema`, `netplan generate`

## What only a VM can prove

`tests/vm/run-vm-test.sh <ubuntu-live-server.iso> [scenario ...]` (manual: it needs KVM, OVMF, QEMU, `xorriso` and a verified
Ubuntu Server ISO; it keeps everything under `tests/vm/.work`, generates an ephemeral SSH key per run and never touches the host's
disks). The VM has two emulated NVMe disks with serial numbers (OS, data) and a third disk carrying stale labelled partitions that
stand in for a disk left over from an earlier install.

| Scenario | What it proves |
| --- | --- |
| `probe` | the `ID_SERIAL` strings the installer really reports (QEMU NVMe: `<model>_<serial>_<namespace>`, the same shape as real NVMe disks) |
| `install` | a seed built by the tool installs unattended: the OS lands on the disk with the OS serial; the data disk is byte-identical afterwards; hostname, user, sudo, time zone, no swap and no swap file, netplan from the site (mode 600), telemetry hosts; key-only SSH; the installer's copy of the seed is root-only (0400) and no other file holds the password hash |
| `setup` | the real node setup (00–08) inside the installed VM: preflight finds both disks by serial; the data disk is provisioned by serial, mounted by UUID, the stale labels on the other disk are reported and ignored; firewall active with SSH allowed; effective `sshd -T` is hardened; sysctl; CRI-O and the pinned Kubernetes tools installed and held; SSH still works afterwards; a second run is idempotent and keeps the data |
| `scrub` | the credentials in the installer's copy of the seed are redacted and nothing else holds them |
| `negative` | a seed whose OS serial matches no disk aborts with the guard's message **before** any disk is touched (OS and data disk identical afterwards, compared with `qemu-img compare`) |
| `reinstall` | the OS is reinstalled onto the same disks: the data disk is byte-identical, the layout is recognised again and the data survives |
| `inspect` | boots the installed system and runs `$VM_CMD` (read-only investigation) |

Disk contents are compared with `qemu-img compare` against a copy taken before the operation. (Do not hash through
`qemu-img convert ... -`: it writes a file named `-`, not stdout.)

Record each run (date, ISO version, result) in the audit's re-verification log.

## What only real hardware proves

How a BMC presents its virtual floppy, the boot menu edit, real network interface names, link aggregation and VLAN
tagging during the installer, real disk serial strings and enumeration order, and vendor-specific kernel behaviour.
Record each hardware run (date, firmware, result) in the consuming project's runbook, not here.
