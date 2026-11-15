#!/usr/bin/env python3
"""Retire the disposable host cluster and seed its prepared KVM guest once."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import stat
import subprocess


STATE = Path("/var/lib/workstation-kubernetes-retirement")
DISKS = Path("/var/lib/workstation-kubernetes")
RETIRED = (
    "/var/lib/rancher/k3s",
    "/var/lib/kubelet",
    "/var/lib/cni",
    "/etc/rancher/k3s",
    "/etc/rancher/node",
    "/run/k3s",
    "/run/flannel",
)


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def atomic_json(path, value):
    temporary = path.with_suffix(".new")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)
    directory = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def protected_processes():
    names = ("docker.service", "greetd.service", "fancontrol.service")
    result = {}
    for name in names:
        pid = run("systemctl", "show", name, "-p", "MainPID", "--value")
        require(pid != "0", f"Protected service {name} is not running")
        result[name] = [pid, Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]]
    for pid in run("pgrep", "-x", "niri").splitlines():
        result[f"niri-{pid}"] = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    containers = run("/run/current-system/sw/bin/docker", "-H", "unix:///run/docker.sock", "ps", "-q")
    result["containers"] = []
    for identifier in containers.splitlines():
        result["containers"].append(run(
            "/run/current-system/sw/bin/docker", "-H", "unix:///run/docker.sock", "inspect",
            "--format", "{{.Id}} {{.Name}} {{.State.Pid}} {{.State.StartedAt}}", identifier,
        ))
    result["containers"].sort()
    return result


def retire(args):
    require(os.geteuid() == 0, "GUI-authenticated root execution is required")
    require(socket.gethostname() == "workstation", "This command is only for workstation")
    require(re.fullmatch(r"/nix/store/[a-z0-9]{32}-nixos-system-workstation-.+", args.system), "Invalid target")
    require(str(Path("/run/current-system").resolve()) == args.system, "The checked host target is not active")
    for name in ("k3s.service", "k3s-lazy.service"):
        require(run("systemctl", "show", name, "-p", "LoadState", "--value") == "not-found", f"{name} still installed")
        require(run("systemctl", "show", name, "-p", "MainPID", "--value") in ("", "0"), f"{name} still running")
    require(not STATE.is_symlink(), "Retirement state must not be a symlink")
    STATE.mkdir(mode=0o700, exist_ok=True)
    require(STATE.stat().st_uid == 0 and stat.S_IMODE(STATE.stat().st_mode) == 0o700, "Unsafe retirement state")
    with (STATE / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        baseline = protected_processes()
        atomic_json(STATE / "protected-before.json", baseline)
        if not (STATE / "host-retired.json").exists():
            subprocess.run([args.cleanup], check=True)
            for line in Path("/proc/self/mountinfo").read_text().splitlines():
                mount = line.split()[4]
                require(not any(mount == p or mount.startswith(p + "/") for p in RETIRED), f"Still mounted: {mount}")
                require(not mount.startswith("/run/netns/cni-"), f"Still mounted: {mount}")
            require(protected_processes() == baseline, "Cleanup changed a protected process")
            for path in map(Path, RETIRED):
                if path.is_symlink():
                    path.unlink()
                elif path.exists():
                    shutil.rmtree(path)
            atomic_json(STATE / "host-retired.json", {"system": args.system})
        if not (STATE / "guest-root-installed.json").exists():
            subprocess.run(["systemctl", "stop", "workstation-kubernetes.service"], check=True)
            require(run("systemctl", "show", "workstation-kubernetes.service", "-p", "MainPID", "--value") == "0", "Guest still running")
            require(not DISKS.is_symlink() and DISKS.is_dir(), "Unsafe guest disk directory")
            for path in (DISKS / "root.qcow2", DISKS / "data.raw"):
                require(not path.is_symlink() and path.is_file(), f"Unsafe guest disk: {path}")
            identity = STATE / "installed-root.identity"
            root = DISKS / "root.qcow2"
            # The hard link records the installed inode across a crash before the marker.
            if not identity.exists() or not os.path.samefile(identity, root):
                temporary = STATE / "root.qcow2.new"
                temporary.unlink(missing_ok=True)
                subprocess.run(["cp", "--sparse=always", "--reflink=auto", "--no-preserve=mode", args.image, str(temporary)], check=True)
                subprocess.run(["qemu-img", "resize", str(temporary), "64G"], check=True)
                user = pwd.getpwnam("kubernetes-vm")
                os.chown(temporary, user.pw_uid, user.pw_gid)
                temporary.chmod(0o600)
                subprocess.run(["sync", "-f", str(temporary)], check=True)
                identity.unlink(missing_ok=True)
                os.link(temporary, identity)
                subprocess.run(["sync", "-f", str(STATE)], check=True)
                temporary.replace(root)
                subprocess.run(["sync", "-f", str(DISKS)], check=True)
            atomic_json(STATE / "guest-root-installed.json", {"image": args.image, "system": args.system})
        subprocess.run(["systemctl", "start", "workstation-kubernetes.service"], check=True)
        require(protected_processes() == baseline, "A protected process changed during retirement")
        require(all(not Path(p).exists() for p in RETIRED), "Retired host data remains")
        atomic_json(STATE / "complete.json", {"system": args.system, "protected": baseline})
        print("Host K3s retired; fresh guest started; desktop and Docker processes preserved.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--cleanup", required=True)
    parser.add_argument("--system", required=True)
    retire(parser.parse_args())
