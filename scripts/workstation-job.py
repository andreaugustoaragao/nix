"""Submit source copies to the isolated workstation worker."""

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import uuid


SYSTEMS = ("x86_64-linux", "aarch64-linux")
KINDS = ("nix", "cargo", "agent", "run")
AGENTS = ("codex", "pi", "cursor-agent", "opencode2")
HOST = "workstation-worker"


@dataclass(frozen=True)
class Job:
    identifier: str
    kind: str
    system: str
    command: tuple[str, ...]
    category: str = "personal"

    @classmethod
    def parse(cls, value):
        identifier = str(uuid.UUID(value["identifier"]))
        if identifier != value["identifier"] or value["kind"] not in KINDS or value["system"] not in SYSTEMS:
            raise ValueError("Invalid job identity, kind, or system")
        category = value.get("category", "personal")
        if category not in ("personal", "work"):
            raise ValueError("Project category must be personal or work")
        command = value["command"]
        if not isinstance(command, list) or any(not isinstance(a, str) or "\0" in a for a in command):
            raise ValueError("Command arguments must be strings without NUL bytes")
        if value["kind"] in ("agent", "run") and not command:
            raise ValueError("This job requires a command")
        if value["kind"] == "agent" and command[0] not in AGENTS:
            raise ValueError("Select a supported agent, or use a run job")
        return cls(identifier, value["kind"], value["system"], tuple(command), category)

    def as_json(self):
        return {"identifier": self.identifier, "kind": self.kind, "system": self.system, "command": list(self.command), "category": self.category}


def atomic_json(path, value):
    temporary = path.with_suffix(".new")
    with temporary.open("w") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")
    temporary.replace(path)


def source_files(repository):
    result = subprocess.check_output(["git", "-C", str(repository), "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    files = sorted(set(p for p in result.split(b"\0") if p))
    if any(p.endswith(b"/") or (repository / os.fsdecode(p)).is_dir() for p in files):
        raise ValueError("Submit nested Git repositories separately")
    if any(b".." in p.split(b"/") or p.startswith(b"/") for p in files):
        raise ValueError("Source paths must stay inside the selected repository")
    files = [p for p in files if (repository / os.fsdecode(p)).exists() or (repository / os.fsdecode(p)).is_symlink()]
    return b"\0".join(files) + b"\0"


def remote(*arguments, tty=False, capture=False):
    command = ["ssh", "-o", "BatchMode=yes"]
    if tty:
        command.append("-t")
    command.extend([HOST, shlex.join(["workstation-worker-exec", *arguments])])
    return subprocess.run(command, text=True, stdout=subprocess.PIPE if capture else None, check=True)


def job_directory(identifier, category=None):
    if str(uuid.UUID(identifier)) != identifier:
        raise ValueError("Invalid job identifier")
    roots = {name: Path.home() / "projects" / name / "worker-jobs" for name in ("personal", "work")}
    if category is not None:
        if category not in roots:
            raise ValueError("Invalid project category")
        roots[category].mkdir(mode=0o700, parents=True, exist_ok=True)
        directory = roots[category] / identifier
    else:
        matches = [root / identifier for root in roots.values() if (root / identifier).exists() or (root / identifier).is_symlink()]
        if len(matches) != 1:
            raise ValueError("Cannot identify a unique worker job")
        directory = matches[0]
    if directory.is_symlink():
        raise ValueError("A job directory must not be a symlink")
    return directory


def unit_name(identifier):
    return "workstation-job-" + identifier


def review_diff(directory, output=None):
    source = directory / "source"
    baseline = (directory / "baseline").read_text().strip()
    prefix = ["git", "-C", str(source), "diff", "--binary"]
    subprocess.run([*prefix, baseline, "--"], stdout=output, check=True)
    new_files = subprocess.check_output(["git", "-C", str(source), "ls-files", "--others", "--exclude-standard", "-z"])
    for filename in filter(None, new_files.split(b"\0")):
        result = subprocess.run([*prefix, "--no-index", "--", "/dev/null", os.fsdecode(filename)], stdout=output)
        if result.returncode not in (0, 1):
            raise subprocess.CalledProcessError(result.returncode, result.args)
    return 0


def execute(directory):
    job = Job.parse(json.loads((directory / "job.json").read_text()))
    source = directory / "source"
    environment = os.environ.copy()
    environment.update({
        "WORKSTATION_JOB_ID": job.identifier,
        "WORKSTATION_BUILD_SYSTEM": job.system,
        "CARGO_TARGET_DIR": str(directory / "target"),
        "CARGO_INCREMENTAL": "0",
        "RUSTC_WRAPPER": shutil.which("sccache"),
        "SCCACHE_BASEDIRS": str(source),
    })
    for variable, filename in (("ANTHROPIC_API_KEY", "anthropic_api_key"), ("OPENAI_API_KEY", "open_ai_key")):
        secret = Path("/run/secrets") / filename
        if secret.is_file() and variable not in environment:
            value = secret.read_text().strip()
            environment[variable] = value.removeprefix(variable + "=")
    arguments = list(job.command)
    if job.kind == "cargo":
        flake = "." if (source / "flake.nix").is_file() else "/etc/workstation-worker/source#rust-worker"
        arguments = ["nix", "develop", "--system", job.system, flake, "--command", "cargo", *arguments]
    elif job.kind == "nix":
        arguments = ["nix", "build", "--system", job.system, "--print-out-paths", *(arguments or ["."])]
    atomic_json(directory / "state.json", {"state": "running", "started": datetime.now(timezone.utc).isoformat()})
    code = 125
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        code = subprocess.call(arguments, cwd=source, env=environment)
    except KeyboardInterrupt:
        code = 130
    finally:
        atomic_json(directory / "state.json", {"state": "completed" if code == 0 else "failed", "exitCode": code, "ended": datetime.now(timezone.utc).isoformat()})
    return code


def worker(args):
    if socket.gethostname() != HOST:
        raise ValueError("Worker commands can run only inside the dedicated worker VM")
    directory = job_directory(args.identifier, args.category if args.operation == "allocate" else None)
    if args.operation == "allocate":
        directory.mkdir(mode=0o700)
        (directory / "source").mkdir()
        atomic_json(directory / "state.json", {"state": "allocated"})
        print(json.dumps({"identifier": args.identifier}))
    elif args.operation == "start":
        job = Job.parse(json.loads(args.spec))
        if job.category != directory.parent.parent.name:
            raise ValueError("The job category does not match its allocated workspace")
        if job.identifier != args.identifier or (directory / "job.json").exists():
            raise ValueError("This job has already been started; submit a new job to run again")
        atomic_json(directory / "job.json", job.as_json())
        source = directory / "source"
        subprocess.run(["git", "init", "-q", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "add", "-f", "--all"], check=True)
        subprocess.run(["git", "-C", str(source), "-c", "user.name=Worker snapshot", "-c", "user.email=worker@localhost", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "Source snapshot"], check=True)
        for key, value in (("user.name", "Worker snapshot"), ("user.email", "worker@localhost"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false")):
            subprocess.run(["git", "-C", str(source), "config", "--local", key, value], check=True)
        (directory / "baseline").write_bytes(subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"]))
        command = ["systemd-run", "--user", "--wait", "--unit=" + unit_name(job.identifier), "--property=Slice=build-jobs.slice", "--property=CPUQuota=1200%", "--property=MemoryHigh=24G", "--property=MemoryMax=32G", "--property=TasksMax=4096", "--property=Nice=10", "--property=IOWeight=50", "--property=UMask=0077", "--property=RuntimeMaxSec=12h", "--property=TimeoutStopSec=30s", "--pty" if args.tty else "--pipe", shutil.which("workstation-worker-exec"), "execute", job.identifier]
        return subprocess.call(command)
    elif args.operation == "execute":
        return execute(directory)
    elif args.operation == "status":
        print((directory / "state.json").read_text())
    elif args.operation == "diff":
        return review_diff(directory)
    elif args.operation == "artifact":
        selected = (directory / args.path).resolve(strict=True)
        if not selected.is_relative_to(directory) and not selected.is_relative_to("/nix/store"):
            raise ValueError("Artifacts must be inside this job or the Nix store")
        print(selected)
    elif args.operation == "remove":
        state = subprocess.run(["systemctl", "--user", "show", unit_name(args.identifier), "-p", "ActiveState", "--value"], capture_output=True, text=True).stdout.strip()
        if state in ("active", "activating", "deactivating"):
            raise ValueError("Stop the job before removing its workspace")
        shutil.rmtree(directory)
    return 0


def client(args):
    if args.operation in KINDS:
        repository = args.repository.resolve(strict=True)
        files = source_files(repository)
        arguments = args.command[1:] if args.command[:1] == ["--"] else args.command
        category = args.category or ("work" if repository.is_relative_to(Path.home() / "projects/work") else "personal")
        job = Job.parse({"identifier": str(uuid.uuid4()), "kind": args.operation, "system": args.system, "command": arguments, "category": category})
        remote("allocate", job.identifier, "--category", job.category, capture=True)
        print("Worker job " + job.identifier, flush=True)
        subprocess.run(["rsync", "--archive", "--no-owner", "--no-group", "--protect-args", "--from0", "--files-from=-", "--", str(repository) + "/", HOST + ":projects/" + job.category + "/worker-jobs/" + job.identifier + "/source/"], input=files, check=True)
        tty = args.operation == "agent" and sys.stdin.isatty()
        arguments = ["start", job.identifier, "--spec", json.dumps(job.as_json())]
        if tty:
            arguments.append("--tty")
        remote(*arguments, tty=tty)
    elif args.operation == "fetch":
        destination = args.destination.resolve()
        if destination.exists():
            raise ValueError("Select a new destination for the artifact")
        result = remote("artifact", args.identifier, "--path", args.path, capture=True)
        subprocess.run(["rsync", "--archive", "--copy-links", "--protect-args", "--", HOST + ":" + result.stdout.strip(), str(destination)], check=True)
    else:
        remote(args.operation, args.identifier)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("role", choices=("client", "worker"))
    subparsers = parser.add_subparsers(dest="operation", required=True)
    if len(sys.argv) > 1 and sys.argv[1] == "worker":
        for name in ("allocate", "start", "execute", "status", "diff", "artifact", "remove"):
            item = subparsers.add_parser(name)
            item.add_argument("identifier")
            if name == "allocate":
                item.add_argument("--category", choices=("personal", "work"), default="personal")
            if name == "start":
                item.add_argument("--spec", required=True)
                item.add_argument("--tty", action="store_true")
            if name == "artifact":
                item.add_argument("--path", required=True)
    else:
        for name in KINDS:
            item = subparsers.add_parser(name)
            item.add_argument("--system", choices=SYSTEMS, default="x86_64-linux")
            item.add_argument("--category", choices=("personal", "work"))
            item.add_argument("repository", type=Path)
            item.add_argument("command", nargs=argparse.REMAINDER)
        for name in ("status", "diff", "remove", "fetch"):
            item = subparsers.add_parser(name)
            item.add_argument("identifier")
            if name == "fetch":
                item.add_argument("path")
                item.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        return worker(args) if args.role == "worker" else client(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
