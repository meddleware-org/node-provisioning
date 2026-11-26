# Contributing to node-provisioning

Thank you for looking. node-provisioning is part of [Meddleware](https://meddleware.co.uk): open tools you can use, take everything when you leave,
and run yourself. This file says how to run its checks and propose a change.

## Build and test

There is nothing to build: the tool is shell, awk and Python. The checks are:

```bash
bash tests/run.sh                                         # every tests/*.test.sh, offline; the container suites need podman or docker
shellcheck -S warning -x -P SCRIPTDIR bin/node-provisioning lib/*.sh scripts/*.sh tests/*.sh tests/data-disk/*.sh tests/vm/*.sh targets/*/node-setup/*.sh
bash scripts/check-public-hygiene.sh                      # no identifying or secret-shaped value anywhere in the working tree
bash scripts/check-versions.sh                            # VERSION is X.Y.Z (on a tag push it must equal the tag, and CHANGELOG needs its heading)
git config core.hooksPath scripts/hooks                   # optional pre-commit hook that runs the hygiene check
```

The tests that need a container runtime skip with a message when there is none, so run them where one exists before you propose a change.
`tests/vm/run-vm-test.sh <ubuntu-live-server.iso>` is a manual QEMU/KVM matrix for changes to the installer seed or the node-setup scripts; it is not part of CI.
The README ("Runtime requirements") lists the tools the checks use. CI runs them on every push and pull request (`.github/workflows/ci.yml`), and the
release workflow runs them again on the tagged commit. A change is ready when they all pass locally.

## Proposing a change

1. Open an issue first for anything larger than a fix, so the design can be agreed before the work.
2. Keep a change to one purpose. Write a short subject line in the imperative ("Refuse a serial with a glob character"), and say why in the pull request.
3. Add or update tests with the behaviour they cover. A bug fix comes with a test that failed before it.
4. A behaviour change updates the README or `docs/`, the changelog and the tests; a new configuration key updates `schema/*.schema.tsv` and `docs/inventory.md`.
5. A change to what a seed contains regenerates the golden files (`UPDATE_GOLDEN=1 bash tests/render.test.sh`); read the diff before committing it.
6. Add a line to `CHANGELOG.md`.
7. Security problems go to the address in [`SECURITY.md`](SECURITY.md), never to a public issue.

## House rules

- **Licence.** Everything here is [0BSD](LICENSE). By contributing you agree your contribution is released under it.
- **Versions.** Until the platform's mainnet launch, every release is a patch bump, breaking changes included; the changelog says what broke.
- **Public repository.** Never add a real host name, address, serial, key, hash or token, even in a test or an example. Use documentation ranges (RFC 5737), `example.invalid` and generated fixtures. `scripts/check-public-hygiene.sh` enforces it.
- **No destructive defaults.** The OS disk, the data disk, the firewall networks and the output format have no default: a missing value is an error, never a guess. Disks are identified by serial, never by device name.
- **No echo.** A message, log line or error never repeats a secret or a configured value that could carry one. Name the key or the position instead.
- **Strict configuration.** Site files are `KEY=value` data with declared types; they are never sourced or evaluated, and site values enter templates only through the one renderer.
- **Shell style.** `set -euo pipefail`, quote everything, no `eval`, no `set -x`.
- **Open standards.** Where a standard exists and fits, use it; the standards inventory in the audit (`docs/audit/node-provisioning-audit.md`) lists the ones this project speaks.

## Documentation

Every file explains itself, line by line where the code is not self-evident:

- a header on every file saying what it is for (and, for a script, its usage, environment, exit codes and side effects);
- a comment above every shell function or Python function saying what it does and what its arguments are;
- comments that say **why**, cite the decision, issue or standard behind a choice, and are updated with the code;
- no `TODO` or `FIXME` without an issue or follow-up reference on the same line;
- every command a document shows has been run, and every link resolves.
