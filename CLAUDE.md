# CLAUDE.md — node-provisioning

Instructions for coding agents. See [README.md](README.md) for usage.

## Project identity

- Shell tooling (bash + awk) that renders and validates an Ubuntu Server autoinstall NoCloud seed and runs idempotent node-setup scripts. All site-specific data is external.
- **License:** BSD Zero Clause (0BSD). Public repository: nothing in it may identify a site.
- Version in `VERSION`; patch-only bumps until the platform's mainnet release.

## Invariants

1. **No destructive defaults.** The OS disk, the data disk, the firewall LAN and pod CIDRs and the output format have no
   default. A missing value is an error, never a guess.
2. **Disks are identified by serial** (`ID_SERIAL`), never by `/dev/nvmeXnY` or "largest disk". A serial containing
   `*`, `?` or `[` is refused. Zero or two matches abort before storage is touched.
3. **No secrets in the repository, argv, logs or generated docs.** Secrets arrive by file path (mode 0600, caller-owned)
   or environment variable, and reach `awk` only through `ENVIRON`. Tools print paths, never values.
4. **One renderer.** Site values enter templates only through `lib/render.sh`/`lib/render.awk`. Output is deterministic
   (same inputs, same bytes). No `eval`, no `source` of site files; configuration is strict `KEY=value`.
5. **Fail closed.** Missing keys, unknown keys, ill-typed values, unreplaced `@@MARKER@@`s, a fragment address that
   disagrees with `NODE_IP`, and failing validators all stop the build. A guard that is skipped is reported as skipped,
   never as passed.
6. **Reproducible images.** `SOURCE_DATE_EPOCH`, fixed volume identifiers, normalised ownership. Two builds are
   byte-identical (tested).
7. **Idempotent node scripts.** Re-running changes nothing; destructive paths need an explicit serial and a
   "no unrecognised data" check.

## Layout

```text
bin/node-provisioning        CLI: render | validate | build-seed | node-setup | check-hygiene | version
lib/                         log.sh, config.sh (strict KEY=value), render.sh + render.awk, validate.py, seed.sh
schema/*.schema.tsv          key | type | required | default | secret | description
targets/<distro>/autoinstall user-data template (the only file with @@MARKER@@s)
targets/<distro>/node-setup  run.sh and numbered scripts
examples/site/               documentation-only example site (RFC 5737 addresses)
tests/                       run.sh and *.test.sh (container suites need podman or docker); golden/ expected renders;
                             data-disk/ stubs for the container tests; vm/ manual QEMU/KVM harness and VM-only site
scripts/                     check-versions.sh, check-public-hygiene.sh, scan-history.sh, fetch-subiquity-schema.sh, hooks/
docs/                        configuration, inventory, seed-delivery, node-setup, verification, audit/
```

## Tests and commands

`bash tests/run.sh` (runs every `tests/*.test.sh`, offline) must pass before any commit; CI also runs shellcheck.

```bash
bash tests/run.sh
shellcheck -S warning -x -P SCRIPTDIR bin/node-provisioning lib/*.sh scripts/*.sh tests/*.sh targets/*/node-setup/*.sh
bash scripts/check-public-hygiene.sh # secrets and identifying values of the working tree
bash scripts/scan-history.sh --site <your-private-site>   # the same scan over EVERY commit (history keeps removed values)
bash scripts/check-public-hygiene.sh --site <your-private-site> --print-denylist | gh secret set HYGIENE_DENYLIST --repo <org>/<repo>   # CI denylist, never printed
git config core.hooksPath scripts/hooks   # pre-commit hook; set NP_HYGIENE_SITE to your private site for the denylist
bash scripts/check-versions.sh       # VERSION vs tag (on a tag push also needs a CHANGELOG heading)
bash tests/vm/run-vm-test.sh <ubuntu-live-server.iso> [probe install negative reinstall]   # manual: KVM, OVMF, QEMU
```

## Conventions

- `set -euo pipefail`; quote everything; no `eval`; no `set -x`.
- Configuration is strict `KEY=value`; types are declared in `schema/*.schema.tsv`.
- Every behaviour change updates README/docs, CHANGELOG and tests; a new key updates the schema and `docs/inventory.md`.
- Commit style: one short subject line, no body.

## Release

Tag `vX.Y.Z` equals `VERSION` (`scripts/check-versions.sh`). The release workflow builds the tarball with `git archive`,
signs it keylessly, attests it and publishes the same bytes to GitHub and the OCI registries.

## What not to do

- Do not add real hostnames, IPs, serials, keys, hashes or tokens, even in tests or examples (RFC 5737 addresses,
  `example.invalid`, generated fixtures only).
- Do not vendor the Subiquity schema (AGPL); fetch it pinned by commit and checksum.
- Do not add a default for anything that can destroy data or lock an operator out.
- Do not amend published commits.
