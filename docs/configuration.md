# Configuration

A **site** is a directory you own and keep private. A **node** is one machine in it.

```text
my-site/
  site.env                  site-wide keys           (schema/site.schema.tsv)
  nodes/<name>.env          per-node keys            (schema/node.schema.tsv)
  installer-network.yaml    the installer's network section (embedded, re-indented)
  netplan.yaml              the installed system's netplan   (embedded, re-indented)
  authorized_keys           SSH public keys (public, but identifying)
```

Secrets are **not** part of the site directory: the password hash and the optional Ubuntu Pro token are files (or
environment variables) outside it.

## Rules

- Files are strict `KEY=value` data. They are never sourced or evaluated. Values are literal: no quotes, no variables,
  no leading or trailing spaces. `#` starts a comment line. Lists are comma-separated.
- Every key is declared in a schema with a type (`host`, `ipv4`, `cidr4`, `serial`, `user`, `size`, `int`, `bool`,
  `text`, `path`, `tz`, `version`, `enum:...`, `list:<type>`). Unknown keys, duplicate keys, wrong-scope keys (a node key in
  `site.env`) and ill-typed values stop the build. Error messages name the key and line, never the value of a secret.
- Required keys have **no default**. A required key that is present but empty counts as missing.
- Relative paths resolve against the site directory; `~/` expands to the invoking user's home.
- Precedence: schema default, then `site.env`, then `nodes/<name>.env`, then the environment (only `INSTANCE_ID`).

## Secrets

| Secret | Where | Checks |
| --- | --- | --- |
| Password hash | `PASSWORD_HASH_FILE` (default `~/.config/node-provisioning/<site>/<node>/password-hash`) | mode must not grant group/other access, owned by the caller, must be a crypt hash (`$y$`, `$6$`, ...). Only the first line is read. |
| Ubuntu Pro token | `UBUNTU_PRO_TOKEN_FILE`, or the `UBUNTU_PRO_TOKEN` environment variable (not both) | same file checks; must match the Subiquity token shape. Without one, the Pro block is removed from the seed. |

Generate a hash with `mkpasswd -m yescrypt`. Never put either value on a command line or in a tracked file.

## Fragments

The two YAML fragments are written by you with literal values; the tool re-indents them into the template and checks
that each is valid YAML, that an `addresses` entry equals `NODE_IP`, and that `netplan generate` accepts them.

## Commands

```bash
node-provisioning render      --site DIR --node NAME --out DIR
node-provisioning validate    --site DIR --node NAME [--strict]
node-provisioning build-seed  --site DIR --node NAME --format iso|img|floppy --out DIR
```

`validate` renders into a scratch directory and checks the result against the pinned Subiquity autoinstall schema
(`scripts/fetch-subiquity-schema.sh`) and `cloud-init schema`. `--strict` fails when the schema is not available
instead of skipping it. See [inventory.md](inventory.md) for what each key controls.

## Installer network and link aggregation

`installer-network.yaml` is the network the **installer** uses (to reach the package mirror and Ubuntu Pro). It must match what the
switch expects. If the node's switch ports form an LACP aggregate (802.3ad), a single bare NIC in the installer gets carrier and
an address but **no traffic** until LACP negotiates, so the mirror check fails (with `APT_FALLBACK=abort` the install stops there).
Describe the same bond, and the same VLAN on top of it, that the installed system uses (`netplan.yaml`): the bond negotiates in a
few seconds and the installer then reaches the network. Check with the installer log after an install:
`grep -i "Mirror checking" /var/log/installer/subiquity-server-debug.log*` should say `successful`.
