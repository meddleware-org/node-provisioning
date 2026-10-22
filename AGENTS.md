# AGENTS.md — node-provisioning

## Project overview

Renders and validates an Ubuntu Server autoinstall NoCloud seed and runs idempotent node-setup scripts. All
site-specific data is external. See [README.md](README.md) and [CLAUDE.md](CLAUDE.md).

## Repository layout

```text
bin/node-provisioning        CLI: render | validate | build-seed | node-setup | check-hygiene | version
lib/                         log, config (strict KEY=value), render (+ render.awk), validate, seed, hygiene
schema/*.schema.tsv          key | type | required | default | secret | description
targets/<distro>/autoinstall user-data template (the only file with @@MARKER@@s)
targets/<distro>/node-setup  run.sh and numbered scripts
examples/site/               documentation-only example site (RFC 5737 addresses)
tests/                       run.sh and *.test.sh (15 suites; container suites need podman or docker); golden/ expected renders;
                             data-disk/ stubs for the container tests; vm/ manual QEMU/KVM harness and VM-only site
scripts/                     check-versions.sh, check-public-hygiene.sh, fetch-subiquity-schema.sh
docs/                        configuration, inventory, seed-delivery, node-setup, verification, audit/
```

## Commands

```bash
bash tests/run.sh                    # everything below that runs offline
shellcheck -S warning -x -P SCRIPTDIR bin/node-provisioning lib/*.sh scripts/*.sh tests/*.sh targets/*/node-setup/*.sh
bash scripts/check-public-hygiene.sh # secrets and identifying values of the working tree
bash scripts/scan-history.sh --site <your-private-site>   # the same scan over EVERY commit (history keeps removed values)
git config core.hooksPath scripts/hooks   # pre-commit hook; set NP_HYGIENE_SITE to your private site for the denylist
bash scripts/check-versions.sh       # VERSION vs tag (on a tag push also needs a CHANGELOG heading)
bash tests/vm/run-vm-test.sh <ubuntu-live-server.iso> [probe install negative reinstall]   # manual: KVM, OVMF, QEMU
```

## Conventions

- `set -euo pipefail`; quote everything; no `eval`; no `set -x`.
- Configuration is strict `KEY=value`; types are declared in `schema/*.schema.tsv`.
- Every behaviour change updates README/docs, CHANGELOG and tests; a new key updates the schema and `docs/inventory.md`.
- Commit style: one short subject line, no body.
