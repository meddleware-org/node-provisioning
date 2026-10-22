# Node setup

`node-provisioning node-setup` runs the numbered scripts of a target in a fixed order, as root, on the node. Every script
is idempotent.

| Step | Script | Failure |
| --- | --- | --- |
| preflight | `01-preflight.sh` | fatal (skip with `SKIP_PREFLIGHT=1`) |
| base packages | (runner) | fatal |
| data disk | `00-data-disk.sh` | fatal |
| kernel | `02-kernel.sh` | fatal |
| container runtime | `03-crio.sh` | fatal |
| kubernetes tools | `04-kubetools.sh` | fatal |
| firewall | `05-ufw.sh` | fatal (a failure still enables the firewall with SSH allowed) |
| telemetry opt-outs | `06-telemetry.sh` | reported, continues |
| Ubuntu Pro posture | `07-ubuntu-pro.sh` | reported, continues |
| host hardening | `08-hardening.sh` | fatal |

Configuration arrives as environment variables: run with `--site DIR --node NAME` to export the site and node values, or
export them yourself. Required: `KUBE_MINOR`, `KUBE_VERSION`, `PAUSE_IMAGE`, `LAN_CIDR`, `POD_CIDR`. Other knobs are
listed in `run.sh`.

## Data disk (00)

Works only on the disk whose udev `ID_SERIAL` equals `DATA_DISK_SERIAL` (required; exactly one disk must match; the root
disk is refused). Device names and "the largest disk" are never used.

It creates three labelled ext4 partitions once (`etcd`, `longhorn-nvme`, `persistent`), then on later runs recognises the
layout **on that disk** and re-mounts it. The labels and mount points (`/var/lib/etcd`, `/var/lib/longhorn-nvme`,
`/var/lib/persistent`) are a stable contract; `/etc/fstab` entries use the partitions' UUIDs. The installer never touches
the data disk, so reinstalling the OS keeps its data.

- The same labels on **another** device (a disk from an earlier install) are reported as a warning and ignored; they can
  neither be mistaken for this layout nor mounted.
- If the selected disk holds partitions that are not this layout, the script refuses unless `WIPE_DATA_DISK=1`. That
  override only ever applies to the disk named by the serial.
- If `/etc/fstab` already maps one of the mount points to a different source, the script stops rather than change it.

## Firewall (05)

`LAN_CIDR` and `POD_CIDR` are required. Administrative ports are restricted to `LAN_CIDR`; SSH stays open from anywhere
(key-only). `ALLOW_ANYWHERE=1` opens everything and is only for an isolated bench network.
