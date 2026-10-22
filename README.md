# node-provisioning

Provision a bare-metal or VM node from nothing: render and validate an Ubuntu Server autoinstall **NoCloud seed**
(ISO, USB image or 1.44 MB BMC virtual-floppy image) and run the idempotent **node-setup** scripts (data disk,
kernel, CRI-O, kubeadm tools, firewall, telemetry opt-outs, Ubuntu Pro posture, hardening).

Everything that varies by site is external configuration. Nothing in this repository names a real host, address,
credential or disk.

> **Warning: an unattended install erases the OS disk.** The seed this tool builds drives an installer that
> repartitions the disk you name without asking. The OS disk and the data disk are selected by **serial number** and
> have **no defaults**; a missing or ambiguous match aborts the install before any disk is touched. Read
> [SECURITY.md](SECURITY.md) before building a seed, and never use a seed built for one machine on another.
>
> **A built seed is a credential-bearing artefact** (password hash, authorised keys, optional Ubuntu Pro token).
> Keep it private, do not commit or publish it, and delete it after the install.

Status: pre-0.1, testnet-era platform tooling. Patch-only versions until the platform's mainnet release.

## Quick start

```bash
# 1. Describe your site (copy examples/site and edit; keep it OUTSIDE this repository).
cp -r examples/site ~/my-site

# 2. Provide secrets by file, never on the command line (mode 0600).
mkpasswd -m yescrypt > ~/.config/node-provisioning/my-site/node1/password-hash && chmod 600 "$_"

# 3. Render + validate (no image yet), then build.
bin/node-provisioning validate --site ~/my-site --node node1
bin/node-provisioning build-seed --site ~/my-site --node node1 --format iso --out ./out
```

Verify a downloaded release before use: see [SECURITY.md](SECURITY.md).

## Components

| Component | What it does |
| --- | --- |
| `seed` | Renders `user-data` and `meta-data` from a site + node description, validates them (YAML, Subiquity autoinstall schema, `cloud-init schema`, network fragments), and packs them into a `CIDATA` image. Output is reproducible. |
| `node-setup` | Runs the numbered node scripts in a fixed order. Each script is idempotent; destructive steps refuse to run without an explicit target. |

Targets live under `targets/<distro-version>/` so other operating systems can be added without touching shared code.

## Runtime requirements

`bash`, `awk`, `sed`, `coreutils`, `python3` with PyYAML, `xorriso` (ISO), `dosfstools` and `mtools` (VFAT images),
`netplan.io` (fragment validation), `cloud-init` (schema check, optional). Node-setup runs as root on the target.

## Documentation

[docs/configuration.md](docs/configuration.md) · [docs/inventory.md](docs/inventory.md) ·
[docs/seed-delivery.md](docs/seed-delivery.md) · [docs/node-setup.md](docs/node-setup.md) ·
[docs/verification.md](docs/verification.md)

Licence: BSD Zero Clause (0BSD), see [LICENSE](LICENSE).
