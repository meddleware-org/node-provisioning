# Example site

Documentation-only example. Copy it outside this repository, replace every value, and generate your own secrets:

```bash
mkdir -p ~/.config/node-provisioning/site/node1
mkpasswd -m yescrypt > ~/.config/node-provisioning/site/node1/password-hash
chmod 600 ~/.config/node-provisioning/site/node1/password-hash
```

`site.env` holds site-wide values; `nodes/<name>.env` holds per-node values; the two YAML files are site-owned
network fragments embedded verbatim (re-indented) into the autoinstall; `authorized_keys.example` is a throwaway
public key. See [docs/configuration.md](../../docs/configuration.md).
