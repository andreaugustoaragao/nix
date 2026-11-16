"""Prepare the SSH directory and refresh only SOPS-managed agent identities."""

import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile


IDENTITIES = ("personal", "work")


def prepare(home, uid, gid):
    target = home / ".ssh"
    target.mkdir(mode=0o700, exist_ok=True)
    if not stat.S_ISDIR(target.lstat().st_mode):
        raise ValueError("Worker SSH directory must be a real directory")
    descriptor = os.open(target, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fchown(descriptor, uid, gid)
        os.fchmod(descriptor, 0o700)
    finally:
        os.close(descriptor)


def public_key(value):
    parts = value.split()
    if len(parts) < 2:
        raise ValueError("Invalid SSH public key")
    try:
        base64.b64decode(parts[1], validate=True)
    except ValueError as error:
        raise ValueError("Invalid SSH public key") from error
    return " ".join(parts[:2])


def invoke(arguments, environment):
    return subprocess.run(arguments, env=environment, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, timeout=30)


def loaded_keys(ssh_add, environment):
    result = invoke([ssh_add, "-L"], environment)
    if result.returncode == 1:
        return set()
    if result.returncode:
        raise RuntimeError("Cannot contact the worker SSH agent")
    return {public_key(line) for line in result.stdout.splitlines() if line.strip()}



def write_ledger(ledger, desired, pending=None):
    value = {"version": 1, "keys": desired}
    if pending is not None:
        value["pending"] = sorted(pending)
    with tempfile.NamedTemporaryFile(mode="w", dir=ledger.parent, delete=False) as temporary:
        temporary.write(json.dumps(value) + "\n")
        temporary_path = Path(temporary.name)
    try:
        temporary_path.replace(ledger)
    finally:
        temporary_path.unlink(missing_ok=True)


def refresh(home, state, secret_directory, ssh_add, ssh_keygen, askpass):
    environment = dict(os.environ)
    if not environment.get("SSH_AUTH_SOCK"):
        raise ValueError("Worker SSH agent socket must be explicit")
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    state.chmod(0o700)
    with (state / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        desired = {}
        environments = {}
        for identity in IDENTITIES:
            key = home / ".ssh" / ("id_rsa_" + identity)
            expected = public_key(key.with_suffix(".pub").read_text())
            local_environment = {
                **environment, "SSH_ASKPASS": askpass, "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": "worker-git", "WORKER_GIT_SSH_PASSPHRASE_FILE": str(
                    secret_directory / ("ssh_passphrase_" + identity)),
            }
            actual = invoke([ssh_keygen, "-y", "-f", str(key)], local_environment)
            if actual.returncode or public_key(actual.stdout) != expected:
                raise RuntimeError("Invalid worker SSH identity: " + identity)
            desired[identity] = expected
            environments[identity] = local_environment
        ledger = state / "managed-ssh.json"
        previous = set()
        if ledger.exists():
            value = json.loads(ledger.read_text())
            if value.get("version") != 1 or set(value.get("keys", {})) != set(IDENTITIES):
                raise ValueError("Invalid managed SSH identity ledger")
            pending = value.get("pending", [])
            if not isinstance(pending, list):
                raise ValueError("Invalid pending SSH identity ledger")
            previous = {public_key(key) for key in [*value["keys"].values(), *pending]}
        loaded = loaded_keys(ssh_add, environment)
        write_ledger(ledger, desired, previous | set(desired.values()))
        for identity in IDENTITIES:
            if desired[identity] not in loaded:
                key = home / ".ssh" / ("id_rsa_" + identity)
                if invoke([ssh_add, str(key)], environments[identity]).returncode:
                    raise RuntimeError("Cannot load worker SSH identity: " + identity)
        current = loaded_keys(ssh_add, environment)
        if not set(desired.values()) <= current:
            raise RuntimeError("Worker SSH agent did not accept the selected identities")
        for retired in previous - set(desired.values()):
            if retired not in current:
                continue
            with tempfile.NamedTemporaryFile(mode="w", dir=state) as temporary:
                temporary.write(retired + "\n")
                temporary.flush()
                if invoke([ssh_add, "-d", temporary.name], environment).returncode:
                    raise RuntimeError("Cannot remove a retired managed SSH identity")
        write_ledger(ledger, desired)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="command", required=True)
    preparation = subcommands.add_parser("prepare")
    preparation.add_argument("--home", type=Path, required=True)
    preparation.add_argument("--uid", type=int, required=True)
    preparation.add_argument("--gid", type=int, required=True)
    loading = subcommands.add_parser("refresh")
    loading.add_argument("--home", type=Path, required=True)
    loading.add_argument("--state", type=Path, required=True)
    loading.add_argument("--secret-directory", type=Path, required=True)
    loading.add_argument("--ssh-add", required=True)
    loading.add_argument("--ssh-keygen", required=True)
    loading.add_argument("--askpass", required=True)
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.home, args.uid, args.gid)
    else:
        refresh(args.home, args.state, args.secret_directory,
                args.ssh_add, args.ssh_keygen, args.askpass)


if __name__ == "__main__":
    main()
