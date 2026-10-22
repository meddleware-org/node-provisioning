# Security Policy

## Scope

This repository contains tooling that **erases disks** and produces **credential-bearing artefacts**. In scope: the
renderer and validators, the seed builder, the node-setup scripts, the release workflow and its provenance.

## Invariants

- The OS disk and the data disk are chosen by serial number with no default; zero or ambiguous matches abort the
  install before storage is touched.
- Secrets (password hash, Ubuntu Pro token) are read from files (mode 0600, owned by the caller) or the environment,
  are never placed on a command line, never logged and never written into tracked files.
- **A built seed contains a password hash, authorised keys and optionally an Ubuntu Pro token.** Treat it as a
  credential: write it with mode 0600, store it only where you keep credentials, never publish or commit it, and delete
  it after the install.
- Rendering is deterministic and validated; unknown or ill-typed input fails the build.
- The repository holds no site data; a hygiene check enforces this in CI.
- Releases are checked and signed. Verify a downloaded release tarball:

```bash
cosign verify-blob \
  --bundle node-provisioning-X.Y.Z.tar.gz.sigstore.json \
  --certificate-identity-regexp '^https://github\.com/meddleware-org/node-provisioning/\.github/workflows/release\.yml@refs/tags/v' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  node-provisioning-X.Y.Z.tar.gz
```

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Email <security@meddleware.co.uk>. We acknowledge within 3 business days and give a plan within 14 days. Do not open
a public issue for a vulnerability.

## Disclosure

Coordinated disclosure after a fix is released.
