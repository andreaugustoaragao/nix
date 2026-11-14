#!/usr/bin/env python3
"""Conservative, noninteractive Git synchronization. Python standard library only."""

import argparse
from dataclasses import dataclass
import fcntl
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile


class Stop(Exception):
    def __init__(self, reason, outcome="needs_decision", **diagnostic):
        self.reason = reason
        self.outcome = outcome
        self.diagnostic = diagnostic


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Stop("invalid_arguments", "failed")


def arguments():
    parser = Parser(description=__doc__)
    parser.add_argument("--repo", required=True, help="Worktree directory (or a subdirectory)")
    parser.add_argument("--direction", choices=("pull", "push", "both"), default="both")
    parser.add_argument("--apply", action="store_true", help="Authorize fast-forward/push mutations")
    parser.add_argument("--check", action="append", default=[], metavar="JSON_ARGV",
                        help='Repeatable check, e.g. \'["python3", "-m", "unittest"]\'')
    parser.add_argument("--timeout", type=float, default=60, help="Seconds per subprocess (default: 60)")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        raise Stop("invalid_arguments", "failed")
    checks = []
    for item in args.check:
        try:
            argv = json.loads(item)
        except (ValueError, TypeError):
            raise Stop("invalid_check", "failed") from None
        if (not isinstance(argv, list) or not argv
                or any(not isinstance(arg, str) or "\0" in arg for arg in argv)
                or not argv[0]):
            raise Stop("invalid_check", "failed")
        checks.append(argv)
    args.check = checks
    return args


@dataclass(frozen=True)
class Destination:
    remote: str
    ref: str
    tracking: str
    url: str
    fetch: tuple


def result_template():
    return {
        "schema_version": 1, "outcome": "failed", "reason": "not_started",
        "repo": None, "direction": None, "apply": False, "branch": None, "upstream": None,
        "before": {"head": None, "remote": None},
        "after": {"head": None, "remote": None},
        "ahead": None, "behind": None, "converged": None,
        "remote_verified": False, "clean": None,
        "actions": [], "planned_actions": [],
        "checks": {"status": "not_requested", "results": []},
        "diagnostics": [], "next_action": None,
    }


class Sync:
    def __init__(self, args, result):
        self.args = args
        self.result = result
        self.repo = os.path.abspath(args.repo)
        self.env = os.environ.copy()
        # --repo must select the worktree, even when called from a Git hook.
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
                    "GIT_PREFIX", "GIT_NAMESPACE", "GIT_OBJECT_DIRECTORY",
                    "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_SHALLOW_FILE"):
            self.env.pop(key, None)
        self.env.update(GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="never",
                        GIT_ASKPASS="false", SSH_ASKPASS="false",
                        SSH_ASKPASS_REQUIRE="never", GIT_OPTIONAL_LOCKS="0",
                        GIT_NO_REPLACE_OBJECTS="1", LC_ALL="C")
        self.identity = None
        self.destination = None
        self.branch = None
        self.expected_head = None
        self.root = None
        self.gitdir = None
        self.common = None
        self.logdir = None
        self.ff_target = None
        self.partial_captured = False

    def failure_log(self, operation, output, errors):
        if self.logdir is None:
            self.logdir = tempfile.mkdtemp(prefix="repo-sync-", dir="/tmp")
        descriptor, path = tempfile.mkstemp(prefix=operation + "-", suffix=".log", dir=self.logdir)
        with os.fdopen(descriptor, "wb") as log:
            log.write(b"stdout:\n")
            output.seek(0)
            shutil.copyfileobj(output, log)
            log.write(b"\nstderr:\n")
            errors.seek(0)
            shutil.copyfileobj(errors, log)
        return path

    def run(self, argv, operation, *, git=True, allowed=(0,), discard=False):
        command = ["git", "-C", self.repo, *argv] if git else argv
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            try:
                process = subprocess.Popen(
                    command, cwd=self.root, env=self.env, stdin=subprocess.DEVNULL,
                    stdout=output, stderr=errors, start_new_session=True,
                )
            except OSError:
                raise Stop("command_unavailable", "failed", operation=operation) from None
            try:
                process.wait(timeout=self.args.timeout)
            except BaseException as error:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                if isinstance(error, subprocess.TimeoutExpired):
                    raise Stop(operation + "_timed_out", "failed", operation=operation,
                               timed_out=True, log=self.failure_log(operation, output, errors)) from None
                raise
            if process.returncode not in allowed:
                raise Stop(operation + "_failed", "failed", operation=operation,
                           exit_code=process.returncode, log=self.failure_log(operation, output, errors))
            if discard:
                return process.returncode, ""
            output.seek(0)
            data = output.read(1024 * 1024 + 1)
            if len(data) > 1024 * 1024:
                raise Stop("output_limit", "failed", operation=operation)
            return process.returncode, os.fsdecode(data)

    def git(self, *argv, operation="inspect", allowed=(0,)):
        return self.run(list(argv), operation, allowed=allowed)[1].removesuffix("\n")

    def config(self, key):
        _, value = self.run(["config", "--null", "--get-all", key], "config", allowed=(0, 1))
        return tuple(value.split("\0")[:-1])

    def identify(self):
        if self.git("rev-parse", "--is-inside-work-tree") != "true":
            raise Stop("worktree_required")
        return tuple(self.git("rev-parse", "--path-format=absolute", option)
                     for option in ("--show-toplevel", "--absolute-git-dir", "--git-common-dir"))

    def head(self):
        _, branch = self.run(["symbolic-ref", "--quiet", "HEAD"], "head", allowed=(0, 1))
        branch = branch.removesuffix("\n")
        if not branch.startswith("refs/heads/"):
            raise Stop("detached_head")
        code, head = self.run(["rev-parse", "--verify", "HEAD^{commit}"], "head", allowed=(0, 128))
        if code:
            raise Stop("unborn_head")
        return branch, head.removesuffix("\n")

    def resolve_destination(self, branch):
        short = branch.removeprefix("refs/heads/")
        remotes = self.config("branch." + short + ".remote")
        merges = self.config("branch." + short + ".merge")
        if not remotes or not merges:
            raise Stop("missing_upstream")
        if len(remotes) != 1 or len(merges) != 1:
            raise Stop("ambiguous_upstream")
        remote, ref = remotes[0], merges[0]
        if remote == "." or not remote or remote.startswith("-") or not ref.startswith("refs/heads/"):
            raise Stop("unsupported_upstream")
        tracking = "refs/remotes/" + remote + "/" + ref.removeprefix("refs/heads/")
        for name in (ref, tracking):
            code, _ = self.run(["check-ref-format", name], "ref_format", allowed=(0, 1))
            if code:
                raise Stop("unsupported_upstream")
        fetch = self.config("remote." + remote + ".fetch")
        supported = {"refs/heads/*:refs/remotes/" + remote + "/*", ref + ":" + tracking}
        if len(fetch) != 1 or fetch[0].removeprefix("+") not in supported:
            raise Stop("unsupported_fetch_mapping")
        if self.config("remote." + remote + ".push") or self.config("remote." + remote + ".vcs"):
            raise Stop("unsupported_push_mapping")
        mirror = self.git("config", "--type=bool", "--get", "remote." + remote + ".mirror",
                          allowed=(0, 1))
        if mirror == "true":
            raise Stop("unsupported_push_mapping")
        urls = self.git("remote", "get-url", "--all", "--", remote).splitlines()
        push_urls = self.git("remote", "get-url", "--push", "--all", "--", remote).splitlines()
        if len(urls) != 1 or len(push_urls) != 1 or urls != push_urls:
            raise Stop("destination_mismatch")
        url = urls[0]
        # Permit ordinary Git transports and local fixture/remotes; never remote helpers.
        if (not url or url.startswith("-") or re.match(r"^[A-Za-z][A-Za-z0-9+.-]*::", url)
                or "\r" in url or "\n" in url
                or ("://" in url and url.split("://", 1)[0] not in {"https", "http", "ssh", "git", "file"})):
            raise Stop("unsupported_transport")
        return Destination(remote, ref, tracking, url, fetch)

    def clean(self):
        if self.git("ls-files", "--unmerged", "-z"):
            self.result["clean"] = False
            raise Stop("unmerged_paths")
        status = self.git("status", "--porcelain=v1", "-z", "--untracked-files=all",
                          "--ignore-submodules=none")
        self.result["clean"] = not bool(status)
        if status:
            raise Stop("dirty_worktree")

    def idle(self):
        markers = ("MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD",
                   "REVERT_HEAD", "sequencer", "BISECT_LOG", "BISECT_START")
        for marker in markers:
            path = Path(self.git("rev-parse", "--path-format=absolute", "--git-path", marker))
            if path.exists():
                raise Stop("operation_in_progress", marker=marker)
        for directory in {self.gitdir, self.common}:
            for path in directory.glob("*.lock"):
                if path.name != "repo-sync.lock":
                    raise Stop("git_lock_present")
            for name in ("refs", "logs"):
                if next((directory / name).rglob("*.lock"), None) is not None:
                    raise Stop("git_lock_present")

    def guard(self):
        try:
            identity = self.identify()
        except Stop as error:
            raise Stop("repository_changed", **error.diagnostic) from None
        if identity != self.identity:
            raise Stop("repository_changed")
        branch, head = self.head()
        if branch != self.branch or head != self.expected_head:
            raise Stop("checkout_changed")
        if self.resolve_destination(branch) != self.destination:
            raise Stop("destination_changed")
        self.idle()
        self.clean()

    def counts(self, head, remote):
        self.result["ahead"], self.result["behind"] = map(
            int, self.git("rev-list", "--left-right", "--count", head + "..." + remote).split())

    def read_remote(self):
        destination = self.destination
        code, data = self.run(["ls-remote", "--refs", "--exit-code", "--", destination.remote,
                               destination.ref], "verify_remote", allowed=(0, 2))
        matches = [line.split("\t", 1)[0] for line in data.splitlines()
                   if "\t" in line and line.split("\t", 1)[1] == destination.ref]
        if code or len(matches) != 1:
            self.result["after"]["remote"] = None
            raise Stop("remote_branch_missing")
        return matches[0]

    def verify_remote(self, expected):
        self.result["remote_verified"] = False
        observed = self.read_remote()
        self.result["after"]["remote"] = observed
        if observed != expected:
            self.result["ahead"] = self.result["behind"] = None
            raise Stop("remote_changed")
        self.result["remote_verified"] = True
        self.result["actions"].append("verify_remote")

    def checks(self):
        for index, argv in enumerate(self.args.check):
            self.guard()
            self.result["checks"]["status"] = "incomplete"
            record = {"index": index, "outcome": "failed"}
            self.result["checks"]["results"].append(record)
            try:
                code, _ = self.run(argv, "check", git=False, discard=True)
                record["exit_code"] = code
            except Stop as error:
                record.update(error.diagnostic)
                self.result["checks"]["status"] = "failed"
                raise
            record["outcome"] = "passed"
            self.result["actions"].append("check:" + str(index))
            if index == len(self.args.check) - 1:
                self.result["checks"]["status"] = "passed"
            self.guard()

    def execute(self):
        self.identity = self.identify()
        self.root, gitdir, common = self.identity
        self.result["repo"] = self.root
        self.gitdir, self.common = Path(gitdir), Path(common)
        descriptor = os.open(self.common / "repo-sync.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "a+b") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Stop("sync_in_progress") from None
            try:
                self.locked_execute()
            except (Stop, OSError, KeyboardInterrupt):
                self.capture_partial()
                self.partial_captured = True
                raise

    def locked_execute(self):
        if self.identify() != self.identity:
            raise Stop("repository_changed")
        code, head = self.run(["rev-parse", "--verify", "HEAD^{commit}"], "head", allowed=(0, 128))
        self.result["before"]["head"] = self.result["after"]["head"] = (
            head.removesuffix("\n") if not code else None)
        self.idle()
        self.branch, self.expected_head = self.head()
        self.result["branch"] = self.branch.removeprefix("refs/heads/")
        self.result["before"]["head"] = self.result["after"]["head"] = self.expected_head
        self.clean()
        if self.git("rev-parse", "--is-shallow-repository") != "false":
            raise Stop("shallow_history")
        self.destination = self.resolve_destination(self.branch)
        destination = self.destination
        self.result["upstream"] = {"remote": destination.remote, "ref": destination.ref}
        self.guard()
        self.git("fetch", "--no-tags", "--no-prune", "--no-recurse-submodules", "--no-auto-gc",
                 "--no-write-fetch-head", "--refmap=", "--", destination.remote,
                 "+" + destination.ref + ":" + destination.tracking, operation="fetch")
        self.result["actions"].append("fetch")
        remote = self.git("rev-parse", "--verify", destination.tracking + "^{commit}")
        self.result["before"]["remote"] = self.result["after"]["remote"] = remote
        self.guard()
        self.counts(self.expected_head, remote)
        ahead, behind = self.result["ahead"], self.result["behind"]
        if ahead and behind:
            raise Stop("diverged")
        if behind and self.args.direction == "push":
            raise Stop("behind_push_only")
        fast_forward = bool(behind and self.args.direction in {"pull", "both"})
        push = bool(ahead and self.args.direction in {"push", "both"})
        self.result["planned_actions"] = (["fast_forward"] if fast_forward else []) + (
            ["check:" + str(index) for index in range(len(self.args.check))]) + (["push"] if push else [])
        if self.args.apply:
            if fast_forward:
                self.guard()
                self.ff_target = remote
                self.git("merge", "--ff-only", "--no-squash", "--no-edit", "--no-autostash", "--no-overwrite-ignore",
                         remote, operation="fast_forward")
                self.result["actions"].append("fast_forward")
                self.expected_head = remote
                self.result["after"]["head"] = remote
                self.guard()
                self.counts(remote, remote)
            self.checks()
            self.guard()
            if push:
                # Detect remote movement during checks, then push the checked OID, never mutable HEAD.
                self.verify_remote(remote)
                self.guard()
                self.result["remote_verified"] = False
                self.result["after"]["remote"] = None
                self.result["ahead"] = self.result["behind"] = None
                self.git("push", "--porcelain", "--no-force", "--no-follow-tags",
                         "--recurse-submodules=no", "--", destination.remote,
                         self.expected_head + ":" + destination.ref, operation="push")
                self.result["actions"].append("push")
                remote = self.expected_head
                self.counts(self.expected_head, remote)
            self.guard()
            self.verify_remote(remote)
            self.result["outcome"] = "synced"
            self.result["reason"] = "pull_complete_local_ahead" if ahead and not push else "direction_complete"
        else:
            self.guard()
            self.verify_remote(remote)
            self.result["outcome"] = "planned"
            self.result["reason"] = "apply_required" if fast_forward or push else (
                "pull_complete_local_ahead" if ahead else "up_to_date")
        self.result["converged"] = self.result["after"]["head"] == self.result["after"]["remote"]

    def capture_partial(self):
        # Never mutate/roll back on failure. Preserve completed actions and read what remains.
        self.result["converged"] = None
        self.result["remote_verified"] = False
        self.result["ahead"] = self.result["behind"] = None
        self.result["after"]["head"] = None
        self.result["clean"] = None
        if self.identity is None:
            return
        try:
            if self.identify() != self.identity:
                self.result["after"]["head"] = None
                self.result["clean"] = None
                return
            code, head = self.run(["rev-parse", "--verify", "HEAD^{commit}"], "head", allowed=(0, 128))
            self.result["after"]["head"] = head.removesuffix("\n") if not code else None
            if (self.ff_target and self.result["after"]["head"] == self.ff_target
                    and "fast_forward" not in self.result["actions"]):
                self.result["actions"].append("fast_forward")
            try:
                self.clean()
            except Stop as error:
                if error.reason not in {"dirty_worktree", "unmerged_paths"}:
                    raise
            if self.destination and self.resolve_destination(self.branch) == self.destination:
                observed = self.read_remote()
                self.result["after"]["remote"] = observed
                self.result["remote_verified"] = True
                code, _ = self.run(["cat-file", "-e", observed + "^{commit}"], "inspect", allowed=(0, 1, 128))
                if not code and self.result["after"]["head"]:
                    self.counts(self.result["after"]["head"], observed)
        except (Stop, OSError) as error:
            diagnostic = error.diagnostic if isinstance(error, Stop) else {}
            self.result["diagnostics"].append({"during": "read_partial_state", "available": False, **diagnostic})


def main():
    result = result_template()
    sync = None
    try:
        args = arguments()
        result.update(direction=args.direction, apply=args.apply)
        if args.check:
            result["checks"]["status"] = "not_run"
        sync = Sync(args, result)
        sync.execute()
    except Stop as error:
        result.update(outcome=error.outcome, reason=error.reason)
        if error.diagnostic:
            result["diagnostics"].insert(0, error.diagnostic)
        if sync and not sync.partial_captured:
            sync.capture_partial()
    except (OSError, KeyboardInterrupt):
        result.update(outcome="failed", reason="interrupted_or_io_error")
        if sync and not sync.partial_captured:
            sync.capture_partial()
    if result["outcome"] == "needs_decision":
        result["next_action"] = "Inspect the reported state; resolve within task scope before rerunning."
    elif result["outcome"] == "failed":
        result["next_action"] = "Inspect partial state and the failed operation; verify any uncertain push before retrying."
    elif result["outcome"] == "planned":
        result["next_action"] = "Use --apply only when these actions are authorized." if result["planned_actions"] else None
    print(json.dumps(result, ensure_ascii=True, separators=(",", ":")))
    return {"planned": 0, "synced": 0, "needs_decision": 2, "failed": 1}[result["outcome"]]


if __name__ == "__main__":
    sys.exit(main())
