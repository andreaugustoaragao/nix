#!/usr/bin/env python3
"""Reconcile Nix-managed OMP settings and MCP servers into writable config files."""

import argparse
import copy
import json
import os
from pathlib import Path
import sys
import tempfile
import yaml

MCP_SCHEMA_URL = (
    "https://raw.githubusercontent.com/can1357/oh-my-pi/main/"
    "packages/coding-agent/src/config/mcp-schema.json"
)
SENTINEL = object()


def flatten_leaves(node, prefix=()):
    """Flatten nested dicts into {(key_tuple): leaf_value}."""
    if isinstance(node, dict) and node:
        leaves = {}
        for key, value in node.items():
            leaves.update(flatten_leaves(value, prefix + (str(key),)))
        return leaves
    if prefix:
        return {prefix: node}
    return {}


def get_path(doc, path):
    cur = doc
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return SENTINEL
        cur = cur[key]
    return cur


def set_path(doc, path, value):
    cur = doc
    for key in path[:-1]:
        nxt = cur.get(key)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[key] = nxt
        cur = nxt
    cur[path[-1]] = copy.deepcopy(value)


def del_path(doc, path):
    if not path or not isinstance(doc, dict):
        return
    key = path[0]
    if key not in doc:
        return
    if len(path) == 1:
        doc.pop(key, None)
        return
    child = doc[key]
    if isinstance(child, dict):
        del_path(child, path[1:])
        if not child:
            doc.pop(key, None)


def encode_path(path):
    return json.dumps(list(path), separators=(",", ":"))


def decode_path(encoded):
    return tuple(json.loads(encoded))


def reconcile_config(desired_config, existing_config, prev_receipt_entries):
    """Three-way merge Nix-desired config into writable config.yml mapping."""
    result = copy.deepcopy(existing_config) if isinstance(existing_config, dict) else {}
    desired_leaves = flatten_leaves(desired_config)
    prev_leaves = {
        decode_path(k): v for k, v in (prev_receipt_entries or {}).items()
    }

    for path, desired_val in desired_leaves.items():
        current_val = get_path(result, path)
        prev_val = prev_leaves.get(path, SENTINEL)
        if current_val is SENTINEL or prev_val is SENTINEL or desired_val != prev_val:
            set_path(result, path, desired_val)

    for path, prev_val in prev_leaves.items():
        if path not in desired_leaves:
            current_val = get_path(result, path)
            if current_val is not SENTINEL and current_val == prev_val:
                del_path(result, path)

    next_receipt = {
        encode_path(path): copy.deepcopy(val) for path, val in desired_leaves.items()
    }
    return result, next_receipt


def reconcile_mcp(desired_servers, existing_mcp, prev_mcp_receipt):
    """Three-way merge Nix-managed MCP servers into writable mcp.json."""
    result = copy.deepcopy(existing_mcp) if isinstance(existing_mcp, dict) else {}
    if "$schema" not in result:
        result["$schema"] = MCP_SCHEMA_URL
    servers = result.get("mcpServers")
    if not isinstance(servers, dict):
        servers = {}
        result["mcpServers"] = servers

    prev_servers = prev_mcp_receipt or {}

    for name, desired_entry in desired_servers.items():
        prev_entry = prev_servers.get(name, SENTINEL)
        cur_entry = servers.get(name, SENTINEL)
        if cur_entry is SENTINEL or prev_entry is SENTINEL or desired_entry != prev_entry:
            entry = copy.deepcopy(desired_entry)
            if (
                isinstance(cur_entry, dict)
                and "enabled" in cur_entry
                and "enabled" not in entry
            ):
                entry["enabled"] = cur_entry["enabled"]
            servers[name] = entry

    for name, prev_entry in prev_servers.items():
        if name not in desired_servers and name in servers:
            cur_entry = servers[name]
            if isinstance(cur_entry, dict):
                comparable = {
                    k: v
                    for k, v in cur_entry.items()
                    if not (k == "enabled" and "enabled" not in prev_entry)
                }
                if comparable == prev_entry:
                    servers.pop(name, None)

    next_receipt = copy.deepcopy(desired_servers)
    return result, next_receipt


def load_yaml_mapping(path):
    if not path.exists():
        return {}
    raw = path.read_text(encoding="utf-8")
    if not raw.strip():
        return {}
    loaded = yaml.safe_load(raw)
    if loaded is None:
        return {}
    if not isinstance(loaded, dict):
        raise ValueError(f"{path} must contain a YAML mapping")
    return loaded


def load_json_mapping(path):
    if not path.exists():
        return {}
    raw = path.read_text(encoding="utf-8")
    if not raw.strip():
        return {}
    loaded = json.loads(raw)
    if not isinstance(loaded, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return loaded


def atomic_write_text(path, text, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.tmp.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--desired-config", type=Path, required=True)
    parser.add_argument("--desired-mcp", type=Path, required=True)
    parser.add_argument("--config-file", type=Path, required=True)
    parser.add_argument("--mcp-file", type=Path, required=True)
    parser.add_argument("--receipt-file", type=Path, required=True)
    args = parser.parse_args()

    desired_config = load_json_mapping(args.desired_config)
    desired_mcp = load_json_mapping(args.desired_mcp)

    existing_config = load_yaml_mapping(args.config_file)
    existing_mcp = load_json_mapping(args.mcp_file)
    receipt = load_json_mapping(args.receipt_file)

    next_config, next_config_receipt = reconcile_config(
        desired_config, existing_config, receipt.get("config", {})
    )
    next_mcp, next_mcp_receipt = reconcile_mcp(
        desired_mcp, existing_mcp, receipt.get("mcpServers", {})
    )
    next_receipt = {
        "version": 1,
        "config": next_config_receipt,
        "mcpServers": next_mcp_receipt,
    }

    if args.config_file.is_symlink() or next_config != existing_config or not args.config_file.exists():
        rendered_yaml = yaml.safe_dump(
            next_config, sort_keys=False, default_flow_style=False, allow_unicode=True
        )
        atomic_write_text(args.config_file, rendered_yaml)

    if args.mcp_file.is_symlink() or next_mcp != existing_mcp or not args.mcp_file.exists():
        rendered_mcp = json.dumps(next_mcp, indent=2) + "\n"
        atomic_write_text(args.mcp_file, rendered_mcp)

    if args.receipt_file.is_symlink() or next_receipt != receipt or not args.receipt_file.exists():
        atomic_write_text(args.receipt_file, json.dumps(next_receipt, indent=2) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"omp-configure: {exc}", file=sys.stderr)
        sys.exit(1)
