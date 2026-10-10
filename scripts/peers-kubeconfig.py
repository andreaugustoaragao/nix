"""Import certificate-based kubeconfig data from an untrusted cluster host."""

import base64
import binascii
import json
import sys

import yaml

MAX_BYTES = 1024 * 1024


class InvalidConfig(ValueError):
    pass


def named_entry(config, collection, name, field):
    if not isinstance(name, str) or not name:
        raise InvalidConfig("missing context reference")
    entries = config.get(collection)
    if not isinstance(entries, list):
        raise InvalidConfig("missing kubeconfig entries")
    matches = [
        entry
        for entry in entries
        if isinstance(entry, dict) and entry.get("name") == name
    ]
    if len(matches) != 1 or not isinstance(matches[0].get(field), dict):
        raise InvalidConfig("missing or ambiguous kubeconfig entry")
    return matches[0][field]


def embedded_data(entry, field):
    value = entry.get(field)
    if not isinstance(value, str) or not value:
        raise InvalidConfig("embedded certificates and key are required")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise InvalidConfig("invalid embedded credential encoding") from None
    if not decoded:
        raise InvalidConfig("empty embedded credential")
    return base64.b64encode(decoded).decode("ascii")


def sanitize(raw, name, server):
    if len(raw) > MAX_BYTES:
        raise InvalidConfig("kubeconfig exceeds size limit")
    try:
        config = yaml.safe_load(raw)
    except (yaml.YAMLError, UnicodeError, RecursionError):
        # Parser errors may quote credential material: never forward them.
        raise InvalidConfig("invalid kubeconfig data") from None
    if (
        not isinstance(config, dict)
        or config.get("apiVersion") != "v1"
        or config.get("kind") != "Config"
    ):
        raise InvalidConfig("expected a v1 kubeconfig")
    context = named_entry(config, "contexts", config.get("current-context"), "context")
    cluster = named_entry(config, "clusters", context.get("cluster"), "cluster")
    user = named_entry(config, "users", context.get("user"), "user")
    if set(user) != {"client-certificate-data", "client-key-data"}:
        raise InvalidConfig(
            "only embedded client certificate and key authentication is supported"
        )

    # Construct new data. Never preserve exec/auth-provider plugins, paths,
    # proxy URLs, TLS overrides, or arbitrary fields from the remote host.
    return {
        "apiVersion": "v1",
        "kind": "Config",
        "clusters": [
            {
                "name": name,
                "cluster": {
                    "server": server,
                    "certificate-authority-data": embedded_data(
                        cluster, "certificate-authority-data"
                    ),
                },
            }
        ],
        "users": [
            {
                "name": name,
                "user": {
                    "client-certificate-data": embedded_data(
                        user, "client-certificate-data"
                    ),
                    "client-key-data": embedded_data(user, "client-key-data"),
                },
            }
        ],
        "contexts": [{"name": name, "context": {"cluster": name, "user": name}}],
        "current-context": name,
    }


def main():
    if len(sys.argv) != 3:
        print("usage: peers-kubeconfig.py NAME SERVER", file=sys.stderr)
        return 2
    try:
        result = sanitize(
            sys.stdin.buffer.read(MAX_BYTES + 1), sys.argv[1], sys.argv[2]
        )
    except InvalidConfig as error:
        print(f"kubeconfig import rejected: {error}", file=sys.stderr)
        return 1
    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
