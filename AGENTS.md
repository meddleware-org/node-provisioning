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
tests/                       run.sh and *.test.sh; golden/ expected renders; vm/ manual KVM harness
scripts/                     check-versions.sh, check-public-hygiene.sh, fetch-subiquity-schema.sh
docs/                        configuration, inventory, seed-delivery, node-setup, verification, audit/
```

## Commands

```bash
bash tests/run.sh                    # everything below that runs offline
shellcheck -S warning -x -P SCRIPTDIR bin/node-provisioning lib/*.sh scripts/*.sh tests/*.sh targets/*/node-setup/*.sh
bash scripts/check-public-hygiene.sh # secrets and identifying values (also a pre-commit hook)
bash scripts/check-versions.sh       # VERSION vs tag
```

## Conventions

- `set -euo pipefail`; quote everything; no `eval`; no `set -x`.
- Configuration is strict `KEY=value`; types are declared in `schema/*.schema.tsv`.
- Every behaviour change updates README/docs, CHANGELOG and tests; a new key updates the schema and `docs/inventory.md`.
- Commit style: one short subject line, no body.
