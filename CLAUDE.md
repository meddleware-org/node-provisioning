# CLAUDE.md — node-provisioning

Instructions for Claude Code. See [AGENTS.md](AGENTS.md) for layout and commands.

## Project identity

- Shell tooling (bash + awk) that renders an Ubuntu autoinstall NoCloud seed and runs node-setup scripts.
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

## Tests

`bash tests/run.sh` must pass before any commit. shellcheck (`-x`) and the hygiene check are part of it.

## Release

Tag `vX.Y.Z` equals `VERSION` (`scripts/check-versions.sh`). The release workflow builds the tarball with `git archive`,
signs it keylessly, attests it and publishes the same bytes to GitHub and the OCI registries.

## What not to do

- Do not add real hostnames, IPs, serials, keys, hashes or tokens, even in tests or examples (RFC 5737 addresses,
  `example.invalid`, generated fixtures only).
- Do not vendor the Subiquity schema (AGPL); fetch it pinned by commit and checksum.
- Do not add a default for anything that can destroy data or lock an operator out.
- Do not amend published commits.
