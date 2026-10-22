#!/usr/bin/env python3
"""Validators for rendered seed files and site fragments. Never prints values from the files."""
import argparse
import json
import re
import sys

import yaml


def load_yaml(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)


def walk_addresses(node, found):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "addresses" and isinstance(value, list):
                for item in value:
                    if isinstance(item, str):
                        found.append(item)
            walk_addresses(value, found)
    elif isinstance(node, list):
        for item in node:
            walk_addresses(item, found)


def check_disk_identity(auto):
    """Every disk action the installer may erase is selected by serial; none by device path or glob."""
    errors = []
    storage = auto.get("storage") or {}
    disks = [a for a in storage.get("config", []) if isinstance(a, dict) and a.get("type") == "disk"]
    if not disks:
        errors.append("storage.config has no disk action")
    for disk in disks:
        if "path" in disk or "serial" in disk:
            errors.append("disk %s is selected by path or plain serial: use match.serial" % disk.get("id"))
        serial = (disk.get("match") or {}).get("serial")
        if not isinstance(serial, str) or not serial or any(c in serial for c in "*?[]"):
            errors.append("disk %s has no exact match.serial" % disk.get("id"))
    cmds = auto.get("early-commands") or []
    if not any(isinstance(c, str) and "ID_SERIAL" in c for c in cmds):
        errors.append("early-commands identity guard is missing")
    return errors


def check_user_data(path, schema):
    errors = []
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("#cloud-config\n"):
        errors.append("first line must be exactly '#cloud-config'")
    if re.search(r"@@[A-Z][A-Z0-9_]*@@", text):
        errors.append("unreplaced @@MARKER@@ in rendered user-data")
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return ["user-data is not valid YAML: %s" % type(exc).__name__]
    if not isinstance(doc, dict) or "autoinstall" not in doc:
        return errors + ["top-level 'autoinstall' key missing"]
    auto = doc["autoinstall"]
    if auto.get("version") != 1:
        errors.append("autoinstall.version must be 1")
    errors += check_disk_identity(auto)
    if schema:
        import jsonschema

        with open(schema, encoding="utf-8") as fh:
            sch = json.load(fh)
        for err in jsonschema.Draft7Validator(sch).iter_errors(auto):
            loc = "/".join(str(p) for p in err.absolute_path) or "(root)"
            errors.append("autoinstall schema: %s at %s" % (err.validator, loc))
    return errors


def check_fragment(path, node_ip, require_address):
    errors = []
    try:
        doc = load_yaml(path)
    except yaml.YAMLError as exc:
        return ["fragment is not valid YAML: %s" % type(exc).__name__]
    if not isinstance(doc, dict) or "network" not in doc and "version" not in doc:
        errors.append("fragment must be a YAML mapping (a netplan 'network:' document or its body)")
        return errors
    if require_address:
        found = []
        walk_addresses(doc, found)
        if not any(a.split("/")[0] == node_ip for a in found):
            errors.append("no 'addresses' entry equals NODE_IP")
    return errors


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    ud = sub.add_parser("user-data")
    ud.add_argument("file")
    ud.add_argument("--schema")
    fr = sub.add_parser("fragment")
    fr.add_argument("file")
    fr.add_argument("--node-ip", required=True)
    fr.add_argument("--require-address", action="store_true")
    args = ap.parse_args()
    if args.cmd == "user-data":
        errors = check_user_data(args.file, args.schema)
    else:
        errors = check_fragment(args.file, args.node_ip, args.require_address)
    for e in errors:
        print("  [FAIL] %s" % e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
