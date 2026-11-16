"""Enroll authenticated public worker keys and encrypt its selected credentials."""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

import yaml


SECRET_NAMES = tuple(json.loads(Path(os.environ.get(
    "WORKER_CREDENTIAL_NAMES_FILE",
    Path(__file__).resolve().parents[1] / "secrets/workers/credential-names.json",
)).read_text()))
WORKER_FILE = "secrets/workers/workstation-worker.yaml"


def public_identities(value):
    if set(value) != {"ssh", "age", "cache"} or not all(
        isinstance(v, str) for v in value.values()
    ):
        raise ValueError("Expected only SSH, age and cache public identities")
    ssh = value["ssh"].split()
    if (
        len(ssh) < 2
        or ssh[0] != "ssh-ed25519"
        or any(character in value["ssh"] for character in "\r\n")
    ):
        raise ValueError("Expected an Ed25519 SSH host key")
    decoded = base64.b64decode(ssh[1], validate=True)
    if len(decoded) != 51 or not decoded.startswith(
        b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
    ):
        raise ValueError("Invalid SSH host public key")
    if not re.fullmatch(r"age1[023456789acdefghjklmnpqrstuvwxyz]{58}", value["age"]):
        raise ValueError("Invalid worker age recipient")
    prefix, separator, key = value["cache"].partition(":")
    if (
        prefix != "workstation-worker-1"
        or not separator
        or len(base64.b64decode(key, validate=True)) != 32
    ):
        raise ValueError("Invalid worker cache public key")
    return {name: text.strip() for name, text in value.items()}


def sops(arguments, data=None):
    environment = (
        {key: value for key, value in os.environ.items() if not key.startswith("SOPS_")}
        if arguments[0] == "--encrypt"
        else None
    )
    result = subprocess.run(
        ["sops", *arguments],
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
    )
    if result.returncode:
        raise RuntimeError("SOPS failed; no plaintext was written or logged")
    return result.stdout


def check_bundle(encrypted, recipients):
    value = yaml.safe_load(encrypted)
    if set(value) != {*SECRET_NAMES, "sops"}:
        raise ValueError("Worker bundle must contain exactly the selected development secrets")
    if not all(
        isinstance(value[name], str) and value[name].startswith("ENC[AES256_GCM,")
        for name in SECRET_NAMES
    ):
        raise ValueError("Every worker credential must be encrypted")
    if any(
        value["sops"].get(name)
        for name in ("pgp", "kms", "gcp_kms", "azure_kv", "hc_vault", "hckms")
    ):
        raise ValueError("Worker bundle has unexpected non-age recipients")
    actual = {item["recipient"] for item in value["sops"]["age"]}
    if actual != set(recipients):
        raise ValueError("Worker bundle has unexpected recipients")


def enroll(repository, identities, runtime_secrets=None, *, refresh=False,
           runtime_home=None, github_token=None):
    repository = repository.resolve()
    root = subprocess.check_output(
        ["git", "-C", str(repository), "rev-parse", "--show-toplevel"], text=True
    ).strip()
    if root != str(repository):
        raise ValueError("Select the Nix repository root")
    identities = public_identities(identities)
    rule_path = repository / ".sops.yaml"
    rules = rule_path.read_text()
    admin = re.search(r"(?m)^  - &admin_key (age1[0-9a-z]+)\s*$", rules)
    if not admin or rules.count("creation_rules:\n") != 1:
        raise ValueError("Expected the existing admin age key and creation_rules")
    recipients = [admin[1], identities["age"]]
    if recipients[0] == recipients[1]:
        raise ValueError("Worker and recovery identities must be separate")
    rule = (
        "  - path_regex: secrets/workers/workstation-worker\\.yaml$\n"
        "    key_groups:\n      - age:\n          - *admin_key\n"
        f"          - {identities['age']}\n"
    )
    if rule not in rules:
        if "path_regex: secrets/workers/" in rules:
            raise ValueError(
                "Worker recipient rule already exists; review key rotation explicitly"
            )
        rules = rules.replace("creation_rules:\n", "creation_rules:\n" + rule)
    elif not rules.split("creation_rules:\n", 1)[1].startswith(rule):
        raise ValueError("Specific worker recipient rule must precede general rules")
    yaml.safe_load(rules)
    public = {
        "secrets/workers/host-ed25519.pub": identities["ssh"] + "\n",
        "secrets/workers/cache.pub": identities["cache"] + "\n",
        "secrets/workers/age.pub": identities["age"] + "\n",
    }
    for path, desired in public.items():
        target = repository / path
        if target.exists() and target.read_text() != desired:
            raise ValueError(
                "Pinned worker identity differs; review key rotation explicitly"
            )
    bundle = repository / WORKER_FILE
    if refresh and runtime_secrets is None:
        raise ValueError("Credential refresh requires explicit runtime-secret sources")
    if bundle.exists() and not refresh:
        encrypted = bundle.read_bytes()
    else:
        if runtime_secrets is not None:
            ssh_files = {
                "ssh_key_github_personal": "id_rsa_personal",
                "ssh_key_github_work": "id_rsa_work",
                "ssh_pubkey_github_personal": "id_rsa_personal.pub",
                "ssh_pubkey_github_work": "id_rsa_work.pub",
            }
            source = {}
            for name in SECRET_NAMES:
                if name == "github_token" and github_token is not None:
                    source[name] = github_token
                else:
                    path = runtime_secrets / name
                    if runtime_home is not None and name in ssh_files:
                        path = runtime_home / ".ssh" / ssh_files[name]
                    source[name] = path.read_text()
        else:
            source = json.loads(
                sops(
                    [
                        "--decrypt",
                        "--output-type",
                        "json",
                        str(repository / "secrets/secrets.yaml"),
                    ]
                )
            )
        if not all(name in source for name in SECRET_NAMES):
            raise ValueError("Selected development credentials are missing from the explicit source")
        selected = {name: source[name] for name in SECRET_NAMES}
        if not all(isinstance(value, str) and value for value in selected.values()):
            raise ValueError("Each selected credential must be a nonempty string")
        encrypted = sops(
            [
                "--encrypt",
                "--config",
                "/dev/null",
                "--input-type",
                "json",
                "--output-type",
                "yaml",
                "--age",
                ",".join(recipients),
                "/dev/stdin",
            ],
            json.dumps(selected).encode(),
        )
    check_bundle(encrypted, recipients)
    desired = {**public, WORKER_FILE: encrypted, ".sops.yaml": rules}
    for path, content in desired.items():
        target = repository / path
        content = content.encode() if isinstance(content, str) else content
        if target.exists() and target.read_bytes() == content:
            continue
        tracked = (
            subprocess.run(
                ["git", "-C", root, "ls-files", "--error-unmatch", "--", path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode
            == 0
        )
        target.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
        try:
            os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)
        if not tracked:
            subprocess.run(["git", "-C", root, "add", "-f", "--", path], check=True)
    return {"enrolled": True, "secrets": list(SECRET_NAMES), "bundle": WORKER_FILE}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path.cwd())
    parser.add_argument(
        "--identities",
        type=Path,
        required=True,
        help="Public JSON exported through authenticated workstation-worker-identities",
    )
    parser.add_argument(
        "--runtime-secrets",
        type=Path,
        help="Read only selected already-decrypted files instead of decrypting the source bundle",
    )
    parser.add_argument("--runtime-home", type=Path,
                        help="Explicit home containing the selected Git SSH identity files")
    parser.add_argument("--refresh-from-runtime", action="store_true",
                        help="Replace the encrypted bundle from explicit runtime sources")
    parser.add_argument("--github-token-from-gh", action="store_true",
                        help="Read the active github.com token from gh into memory only")
    args = parser.parse_args()
    token = None
    if args.github_token_from_gh:
        if args.runtime_secrets is None:
            parser.error("--github-token-from-gh requires --runtime-secrets")
        result = subprocess.run(["gh", "auth", "token", "--hostname", "github.com"],
                                capture_output=True, text=True)
        if result.returncode or not result.stdout.strip():
            parser.error("No active github.com token was available; no token was logged")
        token = result.stdout.strip()
    print(
        json.dumps(
            enroll(
                args.repository,
                json.loads(args.identities.read_text()),
                args.runtime_secrets,
                refresh=args.refresh_from_runtime,
                runtime_home=args.runtime_home,
                github_token=token,
            )
        )
    )
