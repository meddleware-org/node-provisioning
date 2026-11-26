#!/usr/bin/env python3
"""Validators for rendered seed files and site fragments. Never prints values from the files."""
# Usage: validate.py user-data <file> [--schema <autoinstall-schema.json>]
# #        validate.py fragment <file> --node-ip <ip> [--require-address]
# # Exit status 0 when the file passes, 1 when any check fails (one line per problem on stderr). Messages name the key and the
# # position, never a value from the file, because a rendered seed holds credentials.
# # Needs PyYAML, and `jsonschema` when --schema is given.
import argparse
import json
import re
import sys

# PyYAML: `safe_load` only, so a seed file can never construct arbitrary objects.
import yaml


# load_yaml(path): the parsed YAML document in a file (a YAMLError is the caller's to handle).
def load_yaml(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


# walk_addresses(node, found): collect every string under an `addresses` list anywhere in a netplan document into `found` (a netplan file may nest them under any interface type).
def walk_addresses(node, found):
    if isinstance(node, dict):
        for key, value in node.items():
            # An `addresses` entry that is a list: keep its strings.
            if key == "addresses" and isinstance(value, list):
                for item in value:
                    if isinstance(item, str):
                        found.append(item)
            # Recurse into every value, since interfaces nest several levels deep.
            walk_addresses(value, found)
    # A list: recurse into each item.
    elif isinstance(node, list):
        for item in node:
            walk_addresses(item, found)


# check_disk_identity(auto): the safety rules for the autoinstall storage section; returns a list of problems. The installer erases disks, so each disk must be chosen by serial and the swap rules must hold.
def check_disk_identity(auto):
    """Every disk action the installer may erase is selected by serial; none by device path or glob."""
    errors = []
    # The storage section and its disk actions.
    storage = auto.get("storage") or {}
    disks = [a for a in storage.get("config", []) if isinstance(a, dict) and a.get("type") == "disk"]
    # A seed with no disk action would leave the choice to the installer's defaults.
    if not disks:
        errors.append("storage.config has no disk action")
    for disk in disks:
        # A disk chosen by device path or a plain serial key is refused: only `match.serial` is exact (a path can change between boots).
        if "path" in disk or "serial" in disk:
            errors.append("disk %s is selected by path or plain serial: use match.serial" % disk.get("id"))
        # The serial must be a non-empty string without glob characters, so it can match exactly one disk.
        serial = (disk.get("match") or {}).get("serial")
        if not isinstance(serial, str) or not serial or any(c in serial for c in "*?[]"):
            errors.append("disk %s has no exact match.serial" % disk.get("id"))
    # Kubernetes needs swap off, so the installer's swap size must be zero and no swap partition may be defined.
    swap = storage.get("swap") or {}
    if swap.get("size") != 0:
        errors.append("storage.swap.size must be 0 (Kubernetes requires swap off)")
    # Reject a swap partition by file system or by id.
    for action in storage.get("config", []):
        if isinstance(action, dict) and (action.get("fstype") == "swap" or str(action.get("id", "")).endswith("swap")):
            errors.append("storage.config must not define a swap partition")
    # The time zone must be set explicitly, never inherited from a default.
    if not auto.get("timezone"):
        errors.append("autoinstall.timezone must be set explicitly")
    # The early-commands guard (which checks disk serials before anything is touched) must be present.
    cmds = auto.get("early-commands") or []
    if not any(isinstance(c, str) and "ID_SERIAL" in c for c in cmds):
        errors.append("early-commands identity guard is missing")
    return errors


# check_user_data(path, schema): the checks for a rendered user-data file; returns a list of problems. With a schema, the autoinstall section is also validated against it.
def check_user_data(path, schema):
    errors = []
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    # cloud-init only treats a file as a config when its first line is exactly this.
    if not text.startswith("#cloud-config\n"):
        errors.append("first line must be exactly '#cloud-config'")
    # A leftover template marker means a value was never substituted.
    if re.search(r"@@[A-Z][A-Z0-9_]*@@", text):
        errors.append("unreplaced @@MARKER@@ in rendered user-data")
    try:
        # Parse; a parse error is reported by its type only (a message could quote the credentials in the line).
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return ["user-data is not valid YAML: %s" % type(exc).__name__]
    # The document must be a mapping with an `autoinstall` key.
    if not isinstance(doc, dict) or "autoinstall" not in doc:
        return errors + ["top-level 'autoinstall' key missing"]
    # The autoinstall section: version 1 is the only one this tool knows.
    auto = doc["autoinstall"]
    if auto.get("version") != 1:
        errors.append("autoinstall.version must be 1")
    # The disk, swap, time zone and guard rules.
    errors += check_disk_identity(auto)
    # With a schema: validate against it. Each error is reported by its rule and its location (the path to the key), never its value.
    if schema:
        import jsonschema

        with open(schema, encoding="utf-8") as fh:
            sch = json.load(fh)
        for err in jsonschema.Draft7Validator(sch).iter_errors(auto):
            loc = "/".join(str(p) for p in err.absolute_path) or "(root)"
            errors.append("autoinstall schema: %s at %s" % (err.validator, loc))
    return errors


# check_fragment(path, node_ip, require_address): the checks for a site network fragment; returns a list of problems.
def check_fragment(path, node_ip, require_address):
    errors = []
    try:
        # A fragment that is not YAML is reported by type only.
        doc = load_yaml(path)
    except yaml.YAMLError as exc:
        return ["fragment is not valid YAML: %s" % type(exc).__name__]
    # A netplan fragment is a mapping: either a full `network:` document or its body (which has `version`).
    if not isinstance(doc, dict) or "network" not in doc and "version" not in doc:
        errors.append("fragment must be a YAML mapping (a netplan 'network:' document or its body)")
        return errors
    # The node's own address must appear in the fragment, or the machine would come up on the wrong one.
    if require_address:
        found = []
        walk_addresses(doc, found)
        if not any(a.split("/")[0] == node_ip for a in found):
            errors.append("no 'addresses' entry equals NODE_IP")
    return errors


# main(): parse the command line, run the chosen check and print each problem; returns the exit status.
def main():
    ap = argparse.ArgumentParser()
    # Two subcommands: one for rendered user-data, one for a network fragment.
    sub = ap.add_subparsers(dest="cmd", required=True)
    ud = sub.add_parser("user-data")
    ud.add_argument("file")
    ud.add_argument("--schema")
    fr = sub.add_parser("fragment")
    fr.add_argument("file")
    fr.add_argument("--node-ip", required=True)
    fr.add_argument("--require-address", action="store_true")
    # Run the check the subcommand names.
    args = ap.parse_args()
    if args.cmd == "user-data":
        errors = check_user_data(args.file, args.schema)
    else:
        errors = check_fragment(args.file, args.node_ip, args.require_address)
    # One problem per line on stderr; the exit status says whether there were any.
    for e in errors:
        print("  [FAIL] %s" % e, file=sys.stderr)
    return 1 if errors else 0


# Run as a command.
if __name__ == "__main__":
    sys.exit(main())
