# Externalised-value inventory

Every value that used to be hard-coded in the seed builder, the autoinstall template and the node scripts, and where it
lives now. Types and defaults are in [`schema/`](../schema). A **required** key has no default.

Rows marked *(planned)* describe keys added by later, separately recorded changes before the first release; until then
the transitional key named in the schema (for example `OS_DISK_PATH`) is used.

## Seed builder and installer template

| What it controls | Key / mechanism | Default |
| --- | --- | --- |
| Management address in the installer network and the installed netplan | `NODE_IP` (cross-checked against the fragments) | required |
| Installer network block (interface, VLANs, routes, DNS) | `INSTALLER_NETWORK_FILE` (site-owned YAML) | required |
| Installed netplan (bonds, VLANs, routes, search domain) and its file name | `NETPLAN_FILE`, `NETPLAN_FILE_NAME` | required / `10-site.yaml` |
| Interfaces `systemd-networkd-wait-online` waits for | `WAIT_ONLINE_INTERFACES` | required |
| OS disk the installer erases | `OS_DISK_SERIAL` -> `match: {serial: ...}` *(planned; `OS_DISK_PATH` until then)* | required |
| Data disk the installer must never touch | `DATA_DISK_SERIAL` (guard in `early-commands`) *(planned)* | required |
| EFI partition size; swap | `EFI_SIZE`; swap is not created (`swap: {size: 0}`) | `1G` |
| Hostname and instance id | `HOSTNAME`; `INSTANCE_ID` | required / derived |
| Administrator user, sudo policy, password hash, SSH keys | `ADMIN_USER`, `ADMIN_SUDO_NOPASSWD` *(planned)*, `PASSWORD_HASH_FILE`, `AUTHORIZED_KEYS_FILE` | required (sudo: `false`) |
| Locale, keyboard, timezone | `LOCALE`, `KEYBOARD_LAYOUT`, `KEYBOARD_VARIANT`, `TIMEZONE` *(planned)* | timezone required |
| Installer source, update policy, apt fallback | `SOURCE_ID`, `UPDATES`, `APT_FALLBACK` *(planned)* | `abort` fallback |
| Packages installed by the installer | built-in minimal list + `PACKAGES_EXTRA` *(planned)* | - |
| Ubuntu Pro attachment | `UBUNTU_PRO_TOKEN_FILE` / `UBUNTU_PRO_TOKEN` | none (block removed) |
| Telemetry hosts blocked in `/etc/hosts` | built-in Ubuntu hosts + `TELEMETRY_HOSTS_EXTRA` *(planned)* | built-in |
| Output format and location | `--format` (iso, img, floppy), `--out` | required |

## Node-setup scripts

| Script | Values that were hard-coded | Now |
| --- | --- | --- |
| 00-data-disk | disk auto-detection ("largest non-root disk"); partition sizes; owner of the registry directory | `DATA_DISK_SERIAL` only, resolved through `/dev/disk/by-id` *(planned; today's script still auto-detects, which is why it is being replaced)*; `ETCD_SIZE`, `LONGHORN_SIZE`, `REGISTRY_UID`, `REGISTRY_GID`. Partition labels and mount points are a fixed contract. |
| 01-preflight | expected disks, NIC names, bond names, OS version, kernel | `EXPECT_ARCH`, `EXPECT_KERNEL_PREFIX`, `EXPECT_INTERFACES`, serials from the node file |
| 02-kernel | module list, sysctl values | built-in defaults; CNI-specific lines are conditional |
| 03-crio | runtime version channel, repository, pause image, limits | `KUBE_MINOR`, `PAUSE_IMAGE`, `INSTALL_PODMAN` *(planned)* |
| 04-kubetools | Kubernetes version and channel, Longhorn prerequisites | `KUBE_VERSION`, `KUBE_MINOR`, `LONGHORN_PREREQS` *(planned)* |
| 05-ufw | LAN and pod CIDRs, port list, open-anywhere switch | `LAN_CIDR`, `POD_CIDR` (required), `FIREWALL_EXTRA` *(planned)* |
| 06-telemetry | extra blocked hosts | built-in + `TELEMETRY_HOSTS_EXTRA` *(planned)* |
| 07-ubuntu-pro | services to enable/disable | `PRO_ENABLE`, `PRO_DISABLE` |

## Values the consuming project must keep in agreement

The tool cannot see the cluster it provisions, so the consumer checks these (the reference consumer does in its
`build-seed` wrapper): Kubernetes version and minor, container-runtime channel, pause image, pod CIDR (firewall, kubeadm
`podSubnet`, CNI pool), hostname and address against the API server's certificate SANs, administrator user.

## Never in this repository

Password hashes, SSH keys, Ubuntu Pro tokens, real hostnames, real addresses, real disk serials, real domain names.
`scripts/check-public-hygiene.sh` enforces this.
