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
| firewall | `05-ufw.sh` | reported, continues |
| telemetry opt-outs | `06-telemetry.sh` | reported, continues |
| Ubuntu Pro posture | `07-ubuntu-pro.sh` | reported, continues |

Configuration arrives as environment variables: run with `--site DIR --node NAME` to export the site and node values, or
export them yourself. Required: `KUBE_MINOR`, `KUBE_VERSION`, `PAUSE_IMAGE`, `LAN_CIDR`, `POD_CIDR`. Other knobs are
listed in `run.sh`.

## Data disk (00)

Creates three labelled ext4 partitions on the data disk once (`etcd`, `longhorn-nvme`, `persistent`), then on later runs
re-mounts them. The partition labels and mount points (`/var/lib/etcd`, `/var/lib/longhorn-nvme`,
`/var/lib/persistent`) are a stable contract. The installer never touches the data disk, so reinstalling the OS keeps
its data. If the disk holds unrecognised partitions the script refuses unless `WIPE_DATA_DISK=1`.

## Firewall (05)

`LAN_CIDR` and `POD_CIDR` are required. Administrative ports are restricted to `LAN_CIDR`; SSH stays open from anywhere
(key-only). `ALLOW_ANYWHERE=1` opens everything and is only for an isolated bench network.
