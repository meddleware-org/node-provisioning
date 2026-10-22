# Security Audit — `node-provisioning`

**Classification:** Internal security review
**Project:** `repos/node-provisioning` — renders and validates an unattended-installer seed and runs the node-setup scripts for a Kubernetes node
**Project type:** Shell and Python tooling (host provisioning)
**Template:** AUDIT_TEMPLATE.md (2026-10-08) + AUDIT_TEMPLATE_HOST.md (2026-10-22) + AUDIT_TEMPLATE_OPS.md (2026-10-08, script-safety rows only)
Not triggered: SUI and SUI_CLIENT (no chain interaction), IMG (no container image is built or deployed), TS/RS/GO (no such code), AUTH (the tool issues and verifies no tokens; it handles a password hash and an optional vendor token as opaque credentials, covered by HOST), PLATFORM (the cluster is audited with the workspace; node hardening is owned by HOST).
**Targets:** Ubuntu Server 26.04 LTS, Subiquity autoinstall (installer schema pinned to tag 26.04.1), cloud-init NoCloud datasource; kubeadm-based single node with CRI-O, Cilium and Longhorn prerequisites
**Destructive operations:** the installer erases exactly one disk, the OS disk, selected by udev `ID_SERIAL` (`match: {serial}`) after an early-commands guard confirms exactly one OS-serial disk and one data-serial disk; `00-data-disk.sh` partitions only the disk named by `DATA_DISK_SERIAL`, only when it holds no unrecognised data or `WIPE_DATA_DISK=1` is set; `05-ufw.sh` resets the firewall; `08-hardening.sh` rewrites SSH, sysctl and apt policy files
**Credentials in artefacts:** a built seed holds the administrator's password hash, authorised SSH public keys and optionally an Ubuntu Pro token; it is written with mode 0600 outside the repository, never published, and deleted after the install
**Evidence:** hermetic suite and container tests (2026-10-22); VM matrix harness written 2026-10-22, runs recorded in the re-verification log; hardware runs: none yet
**Deployment status:** unreleased (`VERSION` 0.0.1); first release not yet tagged
**Review date:** 2026-10-22 (first pass, written during the extraction)
**Reviewer:** Internal review
**Severity ceiling:** High — the tool decides which disks are erased on a machine that holds the cluster's data, and produces artefacts that carry credentials.
**Status:** first-pass baseline

---

## Executive summary

The tool was extracted from a workspace where the installer template, the seed builder and the node scripts held one
site's values. The extraction changed how destructive decisions are made: disks are chosen by serial number with no
default, the installer aborts before touching storage when the identity is wrong, persistent data is recognised only on
the named disk, and every failure of a security-establishing step is fatal with a fail-safe where it matters.

Twenty-one findings are recorded. Nineteen are resolved, with hermetic evidence (tests named below) and, where the behaviour
needs a real installer, VM evidence (2026-10-22/23, Ubuntu Server 26.04.1). The first hardware run is the remaining
evidence gate. One finding (F15) is deferred behind a maintainer action: package repository key fingerprints must be
verified out of band before they are pinned. One (F18) is an accepted design risk awaiting a maintainer decision.

## Threat model / trust boundaries

| Actor / asset | Power | Bounded by |
| --- | --- | --- |
| Operator workstation | holds every secret at build time | secrets read from 0600 files or the environment; never printed, logged, or in argv; `umask 077` |
| Seed artefact | credentials, and an installer that erases disks | mode 0600, never committed, deleted after use; the guard makes a seed for another machine abort |
| Delivery path (USB, BMC media, HTTP) | read or substitute the seed | documented bind-and-stop rules; integrity is the operator's |
| Installer | erases the OS disk | serial identity, exactly-one match, guard before storage |
| Target disks | OS erased; data must survive | data disk absent from `storage:`; own-partition labels; UUID mounts; opt-in wipe bound to the serial |
| Release tarball and registries | code that runs as root on the node | signed release, consensus pin, sha256 check on the node |
| Package repositories | code that runs as root | signed-by keyrings; fingerprint pinning (F15, open) |
| Public repository | must hold nothing site-identifying | hygiene scan on every change, with the site's own values as a denylist |

## Severity scale

Critical: erases or exposes data or credentials without operator intent. High: a plausible wrong-disk, lock-out or
credential exposure. Medium: lowers a protection or hides a failure. Low: wrong or misleading behaviour with a safe
outcome. Info: design note.

## Scope

In scope: `bin/`, `lib/`, `schema/`, `targets/ubuntu-server-26.04/` (template, node-setup), `scripts/`, `tests/`,
`.github/workflows/`, `docs/`. Out of scope: the cluster the node joins, the consumer's site data and runbooks, the
Subiquity and cloud-init projects themselves (their documented behaviour is recorded in B.HOST-2).

## Findings

### F1 — The OS disk was selected by device path

**Severity:** High   **Disposition:** RESOLVED (hermetic and VM, 2026-10-22/23).
The old template used `path: /dev/nvme0n1`. NVMe names are not stable across boots: on the reference node the OS
had landed on the other NVMe than the template named. Now the disk is `match: {serial: ...}`; the type forbids glob
characters; an `early-commands` guard (POSIX `sh`) aborts before storage unless exactly one disk carries the OS serial and
exactly one the data serial. **Evidence:** `tests/guard.test.sh` (13 cases: exact match, device-name independence, missing,
duplicate, near-miss, none, loop devices ignored, message names counts not serials), `tests/validator.test.sh` (path and
glob rejected), `tests/validate-fail.test.sh` (missing, glob, identical, too-short serials). **VM:** the `install` scenario installed onto the disk whose serial matched (root on the OS-serial disk, whatever its device name); `negative` (an OS serial that matches no disk) aborted with the guard's message and left the OS and data disks identical (`qemu-img compare`).

### F2 — The data disk was auto-detected as the largest non-root disk

**Severity:** High   **Disposition:** RESOLVED (hermetic and VM, 2026-10-22/23).
`00-data-disk.sh` chose "the largest whole disk that is not the root disk". On the reference node that was a 3.6 TB
RAID volume, not the intended NVMe, and the cluster's etcd ended up on a rotational disk. The disk is now selected only by
`DATA_DISK_SERIAL` (required, exactly one match, root disk refused). **Evidence:** `tests/data-disk.test.sh`
(`serial_absent`, `serial_duplicate`, `serial_is_root_disk`, `serial_required`, `serial_glob_rejected`). **VM:** the `setup` scenario provisioned only the disk with the data serial.

### F3 — Labels from an earlier install could hijack provisioning and mounts

**Severity:** High   **Disposition:** RESOLVED (hermetic and VM, 2026-10-22/23).
The sentinel was `blkid -L persistent` anywhere, and fstab used `LABEL=`. A leftover disk with the same labels would skip
provisioning of the real data disk and be mounted instead. The script now inspects only partitions of the selected disk,
mounts by UUID, warns about the same labels elsewhere and refuses to overwrite an fstab entry that maps a mount point to
another source. **Evidence:** `data-disk.test.sh`: `stale_hdd_blank_data`, `stale_hdd_layout_present`, `fstab_conflict`,
`wipe_never_other_disk`. **VM:** with stale labelled partitions on a third disk, `setup` and `reinstall` reported them, provisioned and mounted the data-serial disk by UUID, and mounted nothing from the stale disk; the OS reinstall left the data disk byte-identical, the layout was recognised again without repartitioning, and a marker file survived.

### F4 — A failing multi-line installer command still succeeded

**Severity:** Medium   **Disposition:** RESOLVED (hermetic and VM, 2026-10-22/23).
Installer commands run under `sh -c`; a block reports only its last command's status, and the netplan block ended with
`set -e` (exit 0). A failed write would have produced a node without its network configuration. Both multi-line commands now
start with `set -eu`. **Evidence:** `tests/late-commands.test.sh` (no `set +e`, every multi-line command starts with
`set -eu`, the netplan command is executed against a scratch root and a failing write exits non-zero). **VM:** the installed system has the site's netplan at mode 600 and the telemetry hosts block.

### F5 — The installed network configuration contained an invalid key and was never validated

**Severity:** Medium   **Disposition:** RESOLVED in the tool; the reference node is fixed by its rebuild.
The reference netplan carried `dhcp4-wait`, which is not a netplan key; `netplan get` fails on the installed copy. The old
tooling never ran a validator. `validate` now runs `netplan generate` on both fragments and checks that an address equals
`NODE_IP`. **Evidence:** `validate` against the reference fragments failed before the key was removed; `tests/validate-fail.test.sh`
(fragment not YAML, address mismatch, missing fragment).

### F6 — The hardening described in the docs was never applied

**Severity:** Medium   **Disposition:** RESOLVED (hermetic and VM, 2026-10-22/23).
A cloud-init file described SSH hardening, sysctl and unattended-upgrade policy, but no flow consumed it, although the
runbooks said the installer applied them. `08-hardening.sh` now applies them, validates `sshd -t` before activating and rolls
back on failure, writes a drop-in instead of overwriting the package's unattended-upgrades file, and uses
`KbdInteractiveAuthentication`. `ntp:` was not carried over (it would replace chrony's authenticated time with plain NTP).
**Evidence:** `tests/hardening.test.sh` (23 cases including rollback, idempotence and the installer-copy redaction). **VM:** after the real node setup `sshd -T` reports key-only authentication, no root login and no TCP forwarding; `kernel.kptr_restrict` is 2; the unattended-upgrades policy is installed; SSH still works after the firewall and hardening.

### F7 — The Ubuntu Pro token was substituted into text by `sed` and written three times

**Severity:** Medium   **Disposition:** RESOLVED.
The old builder passed the token to `sed` (visible in a process listing), replaced the bare word everywhere including
comments (three copies in the seed) and did not type-check it. The token is now read from a 0600 file or the environment,
checked against the installer's token shape, reaches `awk` only through its environment, and appears exactly once.
**Evidence:** `tests/render.test.sh` (token appears once, never in comments), `tests/validate-fail.test.sh` (invalid token
rejected without echoing it, file mode, env and file together refused).

### F8 — Built seeds were world-readable

**Severity:** Medium   **Disposition:** RESOLVED.
Images were created with the default umask (0664) in a shared build directory. All outputs are now mode 0600 under
`umask 077`. **Evidence:** `tests/seed.test.sh`, `tests/reproducible.test.sh` (mode 0600 on every format).

### F9 — Real credentials and identity were committed in the template

**Severity:** High (for a public repository)   **Disposition:** RESOLVED.
The template held a password hash, an SSH key with an identifying comment, a host name and network layout. They moved to a
private site directory; the public repository carries only fixtures and documentation addresses. `scripts/check-public-hygiene.sh`
fails on non-documentation IPv4 addresses, crypt hashes, SSH public keys and token shapes, and on any term of a denylist
derived from the site (reporting file and line, never the value). Test samples are built at run time so no secret-shaped
literal exists in the source. `scripts/scan-history.sh` runs the same scan over every commit, because history keeps removed values: on 2026-10-22 it found a real hardware identifier in a test sample of the first local commit (replaced before it was ever pushed, and history rewritten while the repository was still local). **Evidence:** `tests/hygiene.test.sh` (21 cases). A password hash that was read into an
assistant session during the extraction is treated as exposed: a new password is required (OQ1).

### F10 — A firewall script failure left the node open

**Severity:** High   **Disposition:** RESOLVED (hermetic and VM, 2026-10-22/23).
`ufw --force reset` disables the firewall; any later failure left the node unprotected, and the runner only warned. The
script now installs an `ERR` trap that allows SSH and enables the firewall with the rules staged so far, validates both
CIDRs before touching anything, asserts SSH is allowed in the active ruleset, and is fatal in the runner. **Evidence:**
`tests/ufw.test.sh` (16 cases: order, failure at a rule, failure of the SSH rule itself, validation, open-anywhere switch),
`tests/run-order.test.sh`. **VM:** the real setup left the firewall active with SSH allowed. (Failure injection is covered by the container suite only.)

### F11 — Preflight checked names, a removed flag and an unrelated disk

**Severity:** Low   **Disposition:** RESOLVED.
Preflight required three named devices (including a RAID volume that is not part of the layout), fixed interface names and
used `kubectl version --short`. It now checks the OS and data disks by serial, warns when the root filesystem is not on the
OS disk, and takes interface expectations from the site. **Evidence:** `tests/preflight.test.sh`.

### F12 — The telemetry block was skipped when the installer had already written its marker

**Severity:** Low   **Disposition:** RESOLVED.
Entries added by the second script never appeared on an autoinstalled node. Hosts are now merged one by one (never
duplicated, never suppressed), validated as host names, and the third-party endpoints come from a site key.
**Evidence:** `tests/telemetry.test.sh` (10 cases).

### F13 — A swap partition was created and then removed from fstab

**Severity:** Low   **Disposition:** RESOLVED (hermetic and VM, 2026-10-22/23).
The partition remained and curtin would create a swap file when no swap is defined. The partition is gone and
`storage: swap: size: 0` is set (the key's location was checked against the installer reference). **Evidence:** the validator
rejects any swap partition or non-zero swap size (`tests/validator.test.sh`). **VM:** `swapon --show` is empty after reboot, there is no `/swap.img` and no swap entry in fstab (also after the node setup).

### F14 — Misleading reporting comment, no explicit timezone, silent offline install

**Severity:** Low   **Disposition:** RESOLVED.
The comment claimed the setting disabled reporting to the vendor (the default reporter only prints to the console); the
installer geolocated without a time zone; an unreachable mirror silently turned into an offline install. `timezone` is
required, `apt.fallback` is a site key defaulting to `abort`, the comment is corrected. **Evidence:** golden renders,
`tests/validate-fail.test.sh` (timezone and fallback cases).

### F15 — Package repository keys are fetched without fingerprint pinning

**Severity:** Medium   **Disposition:** DEFERRED — gate: pre-mainnet; needs the maintainer to verify the fingerprints out of band.
`03-crio.sh` and `04-kubetools.sh` download a repository key over HTTPS and install it into a signed-by keyring. A changed
key would be trusted. Pinning requires fingerprints obtained from a source independent of the download; writing a value
read from the same download would be trust-on-first-use presented as a pin. See OQ2.
**Observed 2026-10-22 (candidates only, NOT verified out of band):** the CRI-O repository key `85B67D5C50100B1AC8CEFE49CBA9C85640A2B579` (created 2025-02-11, expires 2027-04-22) and the Kubernetes repository key `DE15B14486CD377B9E876E1A234654DA9A296436` (created 2022-08-25, **expires 2026-12-29**). Both scripts install a key only when none exists, so a key that is rotated or expires later is never refreshed on an existing node (`apt-get update` would then fail with an expired-key error): a rebuilt node fetches the current key, and the pin must be updated whenever the project rotates it.

### F16 — Images were not reproducible

**Severity:** Low   **Disposition:** RESOLVED.
Timestamps, volume identifiers, ownership and the builder's time zone leaked into the images. All derive from
`SOURCE_DATE_EPOCH` (default: the mtime of `VERSION`), identifiers are fixed, ownership normalised, the build runs in UTC.
**Evidence:** `tests/reproducible.test.sh` (all three formats, across time, time zone and output directory). Byte equality
across machines also needs the same tool versions (documented).

### F17 — Documentation faults in the delivery instructions

**Severity:** Low   **Disposition:** RESOLVED.
The HTTP recipe served the unrendered template; the kernel parameter with a semicolon is cut off at the GRUB prompt unless
escaped; an empty `meta-data` is invalid for NoCloud; a runbook told operators to `git clone` a directory that is not a
repository. `docs/seed-delivery.md` states the corrected procedures (the `by-label` form and the escaping are confirmed or
disproved in the VM matrix).

### F18 — Passwordless sudo for the administrator

**Severity:** Low   **Disposition:** ACCEPTED-RISK pending OQ1.
The installer grants the administrator passwordless sudo, so a compromised SSH key is root. It is the behaviour the platform
has today; whether it should become a site choice is a maintainer decision.

### F19 — The installer keeps a copy of the seed's user-data, including credentials

**Severity:** Low   **Disposition:** RESOLVED (hermetic and VM, 2026-10-22/23).
Found by the VM matrix: Subiquity writes `/var/log/installer/autoinstall-user-data` on the installed system, re-serialised as
YAML with **unquoted** values, so it holds the password hash and any Ubuntu Pro token. The file is mode 0400 root-only (the
directory is `root:adm`, mode 770), so the exposure is no wider than `/etc/shadow` for the hash, but a vendor token has no
business in a log. `08-hardening.sh` redacts every `password:` and `token:` value in place (quoted or not), keeps the mode, and
is idempotent. **Evidence:** `tests/hardening.test.sh` (quoted and unquoted forms, mode kept, idempotent); VM `scrub`: the hash was
present before, absent from every file under `/var`, `/etc`, `/run`, `/home` and `/root` after, and a second run found nothing.

### F20 — The installer rejects reserved administrator names; the tool accepted them

**Severity:** Medium   **Disposition:** RESOLVED (hermetic and VM, 2026-10-22/23).
Found by the first VM install: the example site used `admin`, which the installer refuses ("Username is reserved by the system")
after loading the configuration, so an operator would find out on the machine. The tool now rejects a built-in list of common
reserved names always and the installer's own `reserved-usernames` file (119 names, pinned by commit and checksum next to the
schema, fetched not vendored) when it has been fetched. **Evidence:** `tests/validate-fail.test.sh` (`admin`, `root`, `sshd`,
`operator`, and a name that is only in the pinned list); the examples and the VM site use a non-reserved name and install.

### F21 — Preflight crashed when optional expectations were not configured

**Severity:** Low   **Disposition:** RESOLVED (hermetic and VM, 2026-10-22/23).
`01-preflight.sh` ran under `set -u` and referenced `EXPECT_BONDS` and `EXPECT_INTERFACES` unconditionally, so a site that omitted
them got "unbound variable". Hermetic tests had always set them. Found by the VM `scrub` scenario; both default to empty now.
**Evidence:** `tests/preflight.test.sh` (`optional_expectations_unset`); VM `scrub`: preflight passes.

---

## Section A — Invariant verification matrix

| # | Invariant | Enforced at | Proven by | Status |
| --- | --- | --- | --- | --- |
| I1 | Disks are selected by exact serial; no default; exactly one match | `schema/node.schema.tsv`, template `match.serial`, `early-commands` guard, `00-data-disk.sh`, `01-preflight.sh` | `guard`, `validator`, `validate-fail`, `data-disk`, `preflight` tests | HOLDS (hermetic and VM) |
| I2 | The installer aborts before storage when identity is wrong | template `early-commands` | `guard.test.sh`; VM negative scenario | HOLDS (hermetic and VM) |
| I3 | Persistent data is recognised only on the named disk; foreign labels ignored; UUID mounts | `00-data-disk.sh` | `data-disk.test.sh` | HOLDS (hermetic and VM) |
| I4 | Secrets never in argv, logs, errors or tracked files | `lib/seed.sh`, `lib/render.awk` (ENVIRON), error messages | `validate-fail.test.sh` (no secret in output), `hygiene.test.sh` | HOLDS |
| I5 | Unknown, missing, empty-required, ill-typed input fails the build | `lib/config.sh` | `config.test.sh`, `validate-fail.test.sh` | HOLDS |
| I6 | Rendered output is schema-valid | `lib/validate.py`, `scripts/fetch-subiquity-schema.sh` | `render.test.sh`; CI fetches the pinned schema | HOLDS |
| I7 | Same inputs, same bytes | `lib/seed.sh` | `reproducible.test.sh` | HOLDS (same tool versions) |
| I8 | Setup order and failure semantics | `node-setup/run.sh` | `run-order.test.sh` | HOLDS |
| I9 | A firewall failure never leaves the node open | `05-ufw.sh` ERR trap | `ufw.test.sh` | HOLDS (hermetic and VM) |
| I10 | An invalid sshd configuration is never activated | `08-hardening.sh` | `hardening.test.sh` | HOLDS |
| I11 | The public repository holds no site data | `check-public-hygiene.sh`, `scan-history.sh` | `hygiene.test.sh`; run with the site as denylist over the tree and every commit | HOLDS |
| I12 | Administrator names the installer rejects are refused at render time | `lib/config.sh` `np_check_reserved_user` | `validate-fail.test.sh`; VM install | HOLDS (F20) |
| I13 | The installer's copy of the seed holds no credentials after setup | `08-hardening.sh` | `hardening.test.sh`; VM `scrub` | HOLDS (F19) |

### Lens categories

| Lens | Category | Status |
| --- | --- | --- |
| HOST | Destructive-target identity | HOLDS (F1, F2) |
| HOST | Data preservation | HOLDS (F3), including the VM OS reinstall |
| HOST | Credential-bearing artefacts | HOLDS (F7, F8, F9); installer logs checked in the VM: only a root-only copy of the seed's user-data held the hash, redacted by `08-hardening.sh` (F19, OQ3) |
| HOST | Render and validation | HOLDS (F5, F14) |
| HOST | Fail-closed execution | HOLDS (F4, F10) |
| HOST | Node hardening | HOLDS (F6); verified on a real install in the VM (`sshd -T`, sysctl, firewall, holds) |
| HOST | Package-source trust | DEFERRED (F15) |
| HOST | Reproducibility | HOLDS (F16) |
| HOST | Distribution and pinning | HOLDS in design and offline tests; first release pending |
| HOST | Cross-repository consistency | consumer-side check (the workspace's `os/tool/check-site-consistency.sh`) |
| HOST | Privacy of the public repository | HOLDS (F9) |
| OPS | Script safety | `set -euo pipefail` on every script; shellcheck at warning level clean in CI; no `eval`; secrets never sourced |

## Section B — Supply-chain, publish-authority & capability matrix

### B.1 Dependency & CVE risk

| Item | Source | Pin | Notes |
| --- | --- | --- | --- |
| Subiquity autoinstall schema | github.com/canonical/subiquity, tag 26.04.1 | commit `f759e0ad…` and sha256 in `scripts/fetch-subiquity-schema.sh` | AGPL: fetched, never vendored |
| GitHub Actions | fleet pins | full commit SHA with version comment; Dependabot (actions only) | `actions/attest` v4.2.2 |
| shellcheck / actionlint | runner / container | shellcheck from the runner; actionlint container pinned by digest | |
| Runtime tools | distribution packages | listed in README | `xorriso`, `dosfstools`, `mtools`, `python3-yaml`, `netplan.io`, optional `cloud-init` |
| Test base image | `ubuntu:26.04` | tag (not digest) | container tests only; no network, no devices |

### B.2 Publish authority, capabilities & secret custody

- **Release:** a `v*` tag runs `release.yml`: version gate, full CI, credential-free deterministic build, keyless signing
  and attestation, GitHub Release, OCI publish. A manual run is a dry run. Registry credentials exist only in the publish job.
- **Secret custody of the tool's inputs:** the password hash and optional token are the operator's files; the repository's
  CI holds only registry credentials and a denylist secret.
- **Capabilities the tool grants a seed:** erase one disk and install an administrator with the given key.

### B.HOST-1 Hard-coded value inventory

See [`inventory.md`](../inventory.md).

### B.HOST-2 Verified upstream facts

| Fact | Source | Checked |
| --- | --- | --- |
| A disk action can be selected by `match: {serial}` (udev `ID_SERIAL`; globs allowed, so the type forbids them); a match that finds no disk fails the install | Subiquity autoinstall reference, storage "disk selection extensions"; curtin storage docs | 2026-10-22 |
| A failing command in `early-commands` aborts the install; they run before storage is probed; string commands run under `sh -c` | autoinstall reference, "command lists" | 2026-10-22 |
| `storage: swap: size: 0` disables the default swap file; `swap` sits beside `config` | autoinstall reference (storage example) | 2026-10-22 |
| `autoinstall.user-data` and `identity` can coexist; user-data runs on first boot | autoinstall reference | 2026-10-22 |
| `apt.fallback` defaults to an offline install | autoinstall reference | 2026-10-22 |
| The default reporter prints to the console; it sends nothing to the vendor | autoinstall reference | 2026-10-22 |
| NoCloud needs an `instance-id` in `meta-data` | cloud-init NoCloud datasource docs | 2026-10-22 |
| `mkfs.fat --invariant`, `mcopy -m`, and `xorrisofs` timestamp handling | man pages; confirmed empirically (`reproducible.test.sh`: FAT stores local time, so the build forces UTC) | 2026-10-22 |

## Section C — Test-coverage & hermetic/live split

### C.1 Coverage

Fifteen suites (config, render, validate-fail, validator, guard, late-commands, seed, reproducible, hygiene, run-order and
five container suites: data-disk, preflight, ufw, hardening, telemetry), run by `tests/run.sh` in CI; shellcheck at warning
level and actionlint run in CI.

### C.2 Hermetic vs. live paths

Hermetic: everything above; device commands are stubbed in containers with no network and no devices. Live: the VM matrix
(`tests/vm/run-vm-test.sh`, manual) and the hardware run. The destructive partitioning path of `00-data-disk.sh` and the
installer's storage handling are proved by the VM matrix (2026-10-22/23); real device enumeration is proved only on hardware.

## Section D — Deployment-readiness gates

### pre-localnet

- [x] hermetic tests green; shellcheck, actionlint and the hygiene scan clean
- [x] no destructive default: every disk identifier is required, typed and exact (F1, F2)

### pre-testnet

- [x] VM matrix recorded 2026-10-22/23 (Ubuntu Server 26.04.1, QEMU/KVM): serial-matched install, negative abort with the disks identical, OS reinstall preserves and re-mounts the data disk, real node setup 00-08, no swap, key-only SSH, installer-log secrets (F19) — see the re-verification log
- [ ] release published, signed, consensus-pinned by the consumer (maintainer: GitHub, registry and settings steps are the maintainer's)

### pre-mainnet

- [ ] hardware run recorded: BMC virtual-media delivery, real disk serial strings, network during the installer (maintainer: needs the physical server)
- [ ] package-repository key fingerprints pinned after out-of-band verification (F15; maintainer)
- [ ] external review of the provisioning path (needs the maintainer's funding; mainnet go-live)

## Cross-project themes

- **Chain-access layering** — N/A (no chain interaction).
- **Versioning policy** — patch-only until mainnet; `VERSION` equals the tag (`scripts/check-versions.sh`).
- **Supply chain and release integrity** — pinned actions, signed deterministic release, consumer consensus pin (D65).
- **Public-repository privacy** — enforced mechanically (F9).

## Normative requirements (MUST / MUST NOT)

- **HOST-M1** holds. **HOST-M2** holds (VM OS reinstall proved). **HOST-M3** holds (mode 0600, deletion is the consumer's `--clean`; the installer's own copy is redacted, F19).
- **HOST-M4** holds. **HOST-M5** holds. **HOST-M6** holds (installer-level behaviour proved in the VM; failure injection is hermetic).
- **HOST-M7** holds, verified on a real install in the VM. **HOST-M8** does not hold yet (F15).
- **HOST-M9** holds. **HOST-M10** holds in design and offline tests (first release pending). **HOST-M11** holds.

## Implementation suggestions (SHOULD / MAY)

- SHOULD add an optional `BULK_DISK_SERIAL` tier for a rotational disk (backups, registry blobs; never etcd or a database)
  after the first rebuild is verified.
- MAY make the administrator's sudo policy a site key (OQ1).
- MAY pin the container test image by digest.

## Open questions (`OQ#`)

- **OQ1** — Passwordless sudo for the administrator: keep, or require the password? The tool keeps today's behaviour until
  the maintainer decides. A password hash that was exposed to an assistant session during the extraction must be replaced
  before the node is rebuilt.
- **OQ2** — Where do the repository key fingerprints for the container runtime and Kubernetes packages come from, and who
  verifies them out of band? (Gate for F15.)
- **OQ3** — Do installer logs on the target retain the password hash or the Pro token? **Answered 2026-10-22 by the VM matrix:** only
  the installer's root-only (0400) copy of the seed's user-data does (F19); `08-hardening.sh` redacts it. The Pro token path was not
  exercised (a fake token would make the installer attempt a real attach); it is the same file and the same redaction.
- **OQ4** — Should `AllowTcpForwarding` stay disabled by default? It is a site key (`SSH_ALLOW_TCP_FORWARDING`, default false).

## Risks

- **A subtly different install** from the old flow: mitigated by the equivalence comparisons and the VM matrix; accepted
  until a hardware run.
- **Installer behaviour that the documentation does not state** (serial string format of NVMe devices, `by-label`
  discovery): found and recorded by the VM matrix.
- **The destructive path rests on the VM, not on hardware** for real device enumeration.
- **Single maintainer**: the release and pin flow assumes the maintainer's keys and accounts.

## Re-verification log

- 2026-10-22 — first-pass baseline written during the extraction from the platform workspace (F1–F18). Hermetic evidence as
  listed; the old flow's rendering and node-script behaviour were compared with the new tool's (render: identical after
  stripping comment and blank lines, meta-data byte-identical; scripts 02–07: identical command logs and filesystem effects,
  differing only in the intended changes). VM matrix and hardware run pending.
- 2026-10-22 — history scan (`scripts/scan-history.sh`) with the site's own values as the denylist found one real hardware identifier in a
  test sample of the first local commit; it was replaced in all commits (history rewritten before any push) and the scan now reports a clean
  history. The scan is part of the pre-publication checklist.
- 2026-10-22/23 — VM matrix run on QEMU/KVM with Ubuntu Server 26.04.1 (ISO checksum verified against the GPG-signed
  `SHA256SUMS`): `probe` (the installer sees `ID_SERIAL` as `<model>_<serial>_<namespace>`), `install`, `setup`, `scrub`,
  `negative`, `reinstall`; all checks pass in the final runs (`docs/verification.md` says what each proves). Findings F19–F21
  came from these runs. **Evidence correction:** the first version of the harness compared disks through `qemu-img convert ... -`,
  which does not write to stdout (it created a stray file and hashed empty input), so the early "disk untouched" results were
  vacuous; the comparison was replaced by `qemu-img compare` against a pre-operation copy (sanity-checked: identical gives 0, a 4 KiB
  write gives 1) and every disk-dependent scenario was re-run. The stray file was removed from the tip commit before anything was pushed.
