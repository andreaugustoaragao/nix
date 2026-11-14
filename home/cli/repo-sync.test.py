#!/usr/bin/env python3
"""Exercise repo-sync against isolated local Git remotes. No network required."""

import fcntl
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parent / "repo-sync/scripts/repo-sync.py"


class RepoSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="repo sync tests ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.remote = self.root / "remote.git"
        self.repo = self.root / "checkout"
        self.peer = self.root / "peer"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_TERMINAL_PROMPT="0", GIT_AUTHOR_NAME="Fixture",
                        GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
                        GIT_TEMPLATE_DIR=str(self.root / "templates"), LC_ALL="C")
        (self.root / "templates").mkdir()
        self.git(self.root, "init", "--bare", "--initial-branch=main", str(self.remote))
        self.git(self.root, "clone", str(self.remote), str(self.repo))
        self.commit(self.repo, "initial")
        self.git(self.repo, "push", "--set-upstream", "origin", "main")
        self.git(self.root, "clone", str(self.remote), str(self.peer))
        self.initial = self.oid(self.repo)
        self.logs = set()
        self.addCleanup(self.remove_logs)

    def remove_logs(self):
        for directory in self.logs:
            shutil.rmtree(directory)

    def git(self, repo, *args, allowed=(0,)):
        process = subprocess.run(["git", "-C", str(repo), *args], env=self.env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertIn(process.returncode, allowed, process.stderr.decode(errors="replace"))
        return os.fsdecode(process.stdout).removesuffix("\n")

    def oid(self, repo, ref="HEAD"):
        return self.git(repo, "rev-parse", ref)

    def remote_oid(self, ref="refs/heads/main"):
        return self.oid(self.remote, ref)

    def commit(self, repo, text, filename="tracked.txt"):
        (repo / filename).write_text(text + "\n")
        self.git(repo, "add", "--", filename)
        self.git(repo, "-c", "commit.gpgSign=false", "commit", "-m", text)
        return self.oid(repo)

    def advance_remote(self):
        oid = self.commit(self.peer, "remote update")
        self.git(self.peer, "push", "origin", "main")
        return oid

    def sync(self, *args, repo=None, exit_code=0, checks=()):
        command = [sys.executable, "-B", str(SCRIPT), "--repo", str(repo or self.repo), *args]
        for check in checks:
            command.extend(("--check", json.dumps(check)))
        process = subprocess.run(command, env=self.env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, timeout=25)
        self.assertEqual(process.stderr, b"")
        result = json.loads(process.stdout)
        self.assertEqual(process.returncode, exit_code, result)
        self.assertEqual(result["schema_version"], 1)
        for record in result["diagnostics"] + result["checks"]["results"]:
            if record.get("log"):
                path = Path(record["log"])
                self.logs.add(path.parent)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
                self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
                self.assertFalse(path.is_relative_to(self.repo))
        self.assertNotIn(str(self.remote), process.stdout.decode())
        return result

    def py(self, source):
        return [sys.executable, "-c", source]

    def hook(self, repo, name, source):
        hooks = Path(self.git(repo, "rev-parse", "--path-format=absolute", "--git-path", "hooks"))
        hooks.mkdir(exist_ok=True)
        path = hooks / name
        path.write_text("#!" + sys.executable + "\n" + source + "\n")
        path.chmod(0o700)
        return path

    def test_up_to_date_and_repeat_safe(self):
        for _ in range(2):
            result = self.sync("--apply")
            self.assertEqual(result["outcome"], "synced")
            self.assertTrue(result["converged"])
            self.assertTrue(result["remote_verified"])
            self.assertEqual((result["ahead"], result["behind"]), (0, 0))
            self.assertEqual(result["checks"]["status"], "not_requested")
            self.assertEqual(result["actions"], ["fetch", "verify_remote"])
            self.assertEqual(result["repo"], str(self.repo.resolve()))

    def test_default_plan_fetches_without_mutating_checkout(self):
        remote = self.advance_remote()
        before_index = (self.repo / ".git/index").read_bytes()
        result = self.sync()
        self.assertEqual(result["outcome"], "planned")
        self.assertEqual(result["planned_actions"], ["fast_forward"])
        self.assertEqual(result["before"], {"head": self.initial, "remote": remote})
        self.assertEqual(result["after"], result["before"])
        self.assertEqual(self.oid(self.repo), self.initial)
        self.assertEqual((self.repo / "tracked.txt").read_text(), "initial\n")
        self.assertEqual((self.repo / ".git/index").read_bytes(), before_index)
        self.assertEqual(self.remote_oid(), remote)

    def test_plan_never_pushes_or_runs_checks(self):
        local = self.commit(self.repo, "local")
        result = self.sync(checks=[self.py("raise SystemExit(1)")])
        self.assertEqual(result["planned_actions"], ["check:0", "push"])
        self.assertEqual(result["checks"]["status"], "not_run")
        self.assertEqual(self.oid(self.repo), local)
        self.assertEqual(self.remote_oid(), self.initial)

    def test_fast_forward_then_check_sees_new_head(self):
        remote = self.advance_remote()
        check = self.py("from pathlib import Path; assert Path('tracked.txt').read_text() == 'remote update\\n'")
        result = self.sync("--apply", checks=[check])
        self.assertEqual(self.oid(self.repo), remote)
        self.assertEqual(result["actions"], ["fetch", "fast_forward", "check:0", "verify_remote"])
        self.assertEqual(result["checks"]["status"], "passed")
        self.assertTrue(result["converged"])

    def test_fast_forward_overrides_inherited_squash(self):
        remote = self.advance_remote()
        self.git(self.repo, "config", "branch.main.mergeOptions", "--squash")
        result = self.sync("--apply", "--direction", "pull")
        self.assertEqual(self.oid(self.repo), remote)
        self.assertEqual(result["after"]["head"], remote)
        self.assertEqual(self.git(self.repo, "status", "--porcelain=v1", "--untracked-files=all"), "")
        self.assertTrue(result["clean"])
        self.assertEqual(result["outcome"], "synced")

    def test_push_only_explicit_branch_and_no_follow_tags(self):
        local = self.commit(self.repo, "local")
        self.git(self.repo, "-c", "tag.gpgSign=false", "tag", "-a", "private", "-m", "private")
        self.git(self.repo, "config", "push.followTags", "true")
        self.git(self.repo, "config", "push.default", "matching")
        self.git(self.repo, "branch", "unrelated")
        result = self.sync("--apply", "--direction", "push", checks=[self.py("pass")])
        self.assertEqual(self.remote_oid(), local)
        self.assertEqual(result["checks"]["status"], "passed")
        self.assertTrue(result["converged"])
        self.assertEqual(self.git(self.remote, "for-each-ref", "--format=%(refname)"), "refs/heads/main")

    def test_directional_pull_does_not_push_ahead(self):
        local = self.commit(self.repo, "local")
        result = self.sync("--apply", "--direction", "pull")
        self.assertEqual(result["outcome"], "synced")
        self.assertEqual(result["reason"], "pull_complete_local_ahead")
        self.assertEqual((result["ahead"], result["behind"]), (1, 0))
        self.assertFalse(result["converged"])
        self.assertEqual(self.remote_oid(), self.initial)
        self.assertEqual(self.oid(self.repo), local)

    def test_directional_push_stops_when_behind(self):
        remote = self.advance_remote()
        result = self.sync("--apply", "--direction", "push", exit_code=2)
        self.assertEqual(result["reason"], "behind_push_only")
        self.assertEqual(self.oid(self.repo), self.initial)
        self.assertEqual(self.remote_oid(), remote)

    def test_divergence_requires_decision(self):
        local = self.commit(self.repo, "local")
        remote = self.advance_remote()
        result = self.sync("--apply", exit_code=2)
        self.assertEqual(result["reason"], "diverged")
        self.assertEqual((result["ahead"], result["behind"]), (1, 1))
        self.assertEqual(self.oid(self.repo), local)
        self.assertEqual(self.remote_oid(), remote)

    def test_dirty_files_preserved_even_with_untracked_hidden_in_config(self):
        self.git(self.repo, "config", "status.showUntrackedFiles", "no")
        self.advance_remote()
        for kind in ("unstaged", "staged", "untracked"):
            with self.subTest(kind=kind):
                path = self.repo / ("untracked.txt" if kind == "untracked" else "tracked.txt")
                path.write_text("user work\n")
                if kind == "staged":
                    self.git(self.repo, "add", "tracked.txt")
                before = self.git(self.repo, "status", "--porcelain=v1", "--untracked-files=all")
                result = self.sync("--apply", exit_code=2)
                self.assertEqual(result["reason"], "dirty_worktree")
                self.assertFalse(result["clean"])
                self.assertEqual(path.read_text(), "user work\n")
                self.assertEqual(self.git(self.repo, "status", "--porcelain=v1", "--untracked-files=all"), before)
                self.assertEqual(self.oid(self.repo), self.initial)
                if kind == "untracked":
                    path.unlink()
                else:
                    self.git(self.repo, "restore", "--staged", "--worktree", "tracked.txt")

    def test_dirty_submodule_is_not_hidden_by_git_config(self):
        self.git(self.repo, "-c", "protocol.file.allow=always", "submodule", "add", str(self.remote), "sub")
        self.git(self.repo, "-c", "commit.gpgSign=false", "commit", "-am", "submodule")
        self.git(self.repo, "config", "diff.ignoreSubmodules", "all")
        self.git(self.repo, "config", "submodule.sub.ignore", "all")
        (self.repo / "sub/unknown").write_text("user work")
        result = self.sync("--apply", exit_code=2)
        self.assertEqual(result["reason"], "dirty_worktree")
        self.assertEqual((self.repo / "sub/unknown").read_text(), "user work")

    def test_detached_unborn_missing_and_local_upstream(self):
        self.git(self.repo, "switch", "--detach")
        self.assertEqual(self.sync("--apply", exit_code=2)["reason"], "detached_head")
        self.git(self.repo, "switch", "main")
        self.git(self.repo, "branch", "--unset-upstream")
        self.assertEqual(self.sync("--apply", exit_code=2)["reason"], "missing_upstream")
        self.git(self.repo, "config", "branch.main.remote", ".")
        self.git(self.repo, "config", "branch.main.merge", "refs/heads/main")
        self.assertEqual(self.sync("--apply", exit_code=2)["reason"], "unsupported_upstream")
        unborn = self.root / "unborn"
        self.git(self.root, "init", "--initial-branch=main", str(unborn))
        self.assertEqual(self.sync("--apply", repo=unborn, exit_code=2)["reason"], "unborn_head")

    def test_real_in_progress_operations(self):
        self.commit(self.repo, "local")
        self.advance_remote()
        self.git(self.repo, "fetch", "origin")
        operations = [
            (("merge", "origin/main"), ("merge", "--abort")),
            (("rebase", "origin/main"), ("rebase", "--abort")),
            (("cherry-pick", "origin/main"), ("cherry-pick", "--abort")),
            (("revert", "origin/main"), ("revert", "--abort")),
            (("bisect", "start"), ("bisect", "reset")),
        ]
        for start, abort in operations:
            with self.subTest(operation=start[0]):
                self.git(self.repo, *start, allowed=(0, 1))
                try:
                    result = self.sync("--apply", exit_code=2)
                    self.assertEqual(result["reason"], "operation_in_progress")
                    self.assertNotIn("fetch", result["actions"])
                finally:
                    self.git(self.repo, *abort)

    def test_git_locks(self):
        for relative in ("index.lock", "HEAD.lock", "refs/heads/main.lock"):
            with self.subTest(lock=relative):
                path = self.repo / ".git" / relative
                path.touch()
                result = self.sync("--apply", exit_code=2)
                self.assertEqual(result["reason"], "git_lock_present")
                self.assertTrue(path.exists())
                path.unlink()

    def test_linked_worktrees_share_nonblocking_sync_lock(self):
        linked = self.root / "linked worktree"
        self.git(self.repo, "worktree", "add", "-b", "linked", str(linked))
        self.git(linked, "branch", "--set-upstream-to=origin/main")
        with (self.repo / ".git/repo-sync.lock").open("a+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for checkout in (self.repo, linked):
                result = self.sync("--apply", repo=checkout, exit_code=2)
                self.assertEqual(result["reason"], "sync_in_progress")
            fcntl.flock(lock, fcntl.LOCK_UN)
        self.assertTrue(self.sync("--apply", repo=linked)["converged"])

    def test_failed_check_blocks_push_and_preserves_private_diagnostics(self):
        local = self.commit(self.repo, "local")
        secret = "credential-shaped-private-output"
        check = self.py("import sys; print(" + repr(secret) + "); print('failure detail', file=sys.stderr); sys.exit(7)")
        result = self.sync("--apply", checks=[check], exit_code=1)
        self.assertEqual(result["reason"], "check_failed")
        self.assertEqual(result["checks"]["status"], "failed")
        self.assertEqual(result["checks"]["results"][0]["exit_code"], 7)
        log = Path(result["checks"]["results"][0]["log"]).read_text()
        self.assertIn(secret, log)
        self.assertIn("failure detail", log)
        self.assertNotIn(secret, json.dumps(result))
        self.assertNotIn("failure detail", json.dumps(result))
        self.assertEqual(self.remote_oid(), self.initial)
        self.assertEqual(self.oid(self.repo), local)

    def test_check_changing_checkout_blocks_push(self):
        self.commit(self.repo, "local")
        result = self.sync("--apply", checks=[["git", "switch", "-c", "other"]], exit_code=2)
        self.assertEqual(result["reason"], "checkout_changed")
        self.assertEqual(self.git(self.repo, "branch", "--show-current"), "other")
        self.assertEqual(self.remote_oid(), self.initial)

    def test_check_changing_head_blocks_push_and_reports_new_oid(self):
        local = self.commit(self.repo, "local")
        check = ["git", "-c", "commit.gpgSign=false", "commit", "--allow-empty", "-m", "during-check"]
        result = self.sync("--apply", checks=[check], exit_code=2)
        self.assertEqual(result["reason"], "checkout_changed")
        self.assertEqual(result["after"]["head"], self.oid(self.repo))
        self.assertNotEqual(result["after"]["head"], local)
        self.assertEqual(result["checks"]["status"], "passed")
        self.assertEqual(self.remote_oid(), self.initial)

    def test_check_removing_repository_blocks_push_and_reports_unknown_state(self):
        self.commit(self.repo, "local")
        result = self.sync("--apply", checks=[self.py("from pathlib import Path; Path('.git').rename('../displaced.git')")], exit_code=2)
        self.assertEqual(result["reason"], "repository_changed")
        self.assertIsNone(result["after"]["head"])
        self.assertIsNone(result["clean"])
        self.assertEqual(self.remote_oid(), self.initial)

    def test_check_creating_dirty_file_blocks_push(self):
        self.commit(self.repo, "local")
        result = self.sync("--apply", checks=[self.py("from pathlib import Path; Path('user-file').write_text('keep')")], exit_code=2)
        self.assertEqual(result["reason"], "dirty_worktree")
        self.assertEqual((self.repo / "user-file").read_text(), "keep")
        self.assertEqual(self.remote_oid(), self.initial)

    def test_failed_check_after_fast_forward_reports_partial_progress(self):
        remote = self.advance_remote()
        result = self.sync("--apply", checks=[self.py("raise SystemExit(1)")], exit_code=1)
        self.assertEqual(result["before"]["head"], self.initial)
        self.assertEqual(result["after"]["head"], remote)
        self.assertIn("fast_forward", result["actions"])
        self.assertNotIn("push", result["actions"])
        self.assertEqual(self.oid(self.repo), remote)
        self.assertIsNone(result["converged"])

    def test_lost_remote_after_fast_forward_keeps_local_progress(self):
        remote = self.advance_remote()
        check = self.py("from pathlib import Path; Path(" + repr(str(self.remote)) + ").rename("
                        + repr(str(self.root / "displaced-remote.git")) + ")")
        result = self.sync("--apply", checks=[check], exit_code=1)
        self.assertEqual(result["reason"], "verify_remote_failed")
        self.assertEqual(result["after"]["head"], remote)
        self.assertFalse(result["remote_verified"])
        self.assertEqual(self.oid(self.repo), remote)
        self.assertIn("fast_forward", result["actions"])
        self.assertIsNone(result["converged"])

    def test_ignored_file_is_not_overwritten_by_fast_forward(self):
        self.commit(self.repo, "ignored.txt", filename=".gitignore")
        self.git(self.repo, "push", "origin", "main")
        self.git(self.peer, "pull", "--ff-only")
        (self.peer / "ignored.txt").write_text("remote data")
        self.git(self.peer, "add", "--force", "ignored.txt")
        self.git(self.peer, "-c", "commit.gpgSign=false", "commit", "-m", "add previously ignored file")
        self.git(self.peer, "push", "origin", "main")
        (self.repo / "ignored.txt").write_text("user data")
        local = self.oid(self.repo)
        result = self.sync("--apply", exit_code=1)
        self.assertEqual(result["reason"], "fast_forward_failed")
        self.assertEqual((self.repo / "ignored.txt").read_text(), "user data")
        self.assertEqual(self.oid(self.repo), local)

    def test_failing_remote_has_json_and_private_log(self):
        self.git(self.repo, "remote", "set-url", "origin", str(self.root / "missing.git"))
        result = self.sync("--apply", exit_code=1)
        self.assertEqual(result["reason"], "fetch_failed")
        self.assertEqual(self.oid(self.repo), self.initial)
        self.assertEqual(result["after"]["head"], self.initial)
        self.assertIsNotNone(result["diagnostics"][0]["log"])
        self.assertNotIn("missing.git", json.dumps(result))

    def test_missing_remote_branch_does_not_use_stale_tracking_ref(self):
        self.git(self.remote, "update-ref", "-d", "refs/heads/main")
        result = self.sync("--apply", exit_code=1)
        self.assertEqual(result["reason"], "fetch_failed")
        self.assertEqual(self.oid(self.repo), self.initial)
        self.assertNotIn("push", result["actions"])

    def test_arbitrary_branch_names_and_distinct_remote_branch(self):
        branch, remote_ref = "topic/naïve-$odd", "refs/heads/release/β"
        self.git(self.repo, "switch", "-c", branch)
        self.git(self.repo, "push", "origin", "HEAD:" + remote_ref)
        self.git(self.repo, "config", "branch." + branch + ".remote", "origin")
        self.git(self.repo, "config", "branch." + branch + ".merge", remote_ref)
        local = self.commit(self.repo, "local")
        result = self.sync("--apply")
        self.assertEqual(result["branch"], branch)
        self.assertEqual(result["upstream"], {"remote": "origin", "ref": remote_ref})
        self.assertEqual(self.remote_oid(remote_ref), local)
        self.assertEqual(self.remote_oid(), self.initial)

    def test_destination_mismatch_and_multiple_urls_are_refused(self):
        self.git(self.repo, "config", "remote.origin.pushurl", str(self.peer))
        self.assertEqual(self.sync("--apply", exit_code=2)["reason"], "destination_mismatch")
        self.git(self.repo, "config", "--replace-all", "remote.origin.pushurl", str(self.remote))
        self.git(self.repo, "config", "--add", "remote.origin.pushurl", str(self.remote))
        self.assertEqual(self.sync("--apply", exit_code=2)["reason"], "destination_mismatch")
        self.assertEqual(self.remote_oid(), self.initial)

    def test_custom_and_negative_refspecs_are_refused(self):
        for mapping in ("+refs/heads/*:refs/custom/*", "^refs/heads/private"):
            with self.subTest(mapping=mapping):
                self.git(self.repo, "config", "--replace-all", "remote.origin.fetch", mapping)
                self.assertEqual(self.sync("--apply", exit_code=2)["reason"], "unsupported_fetch_mapping")
        self.git(self.repo, "config", "--replace-all", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main")
        self.assertTrue(self.sync("--apply")["converged"])
        self.git(self.repo, "config", "remote.origin.push", "HEAD:refs/heads/surprise")
        self.assertEqual(self.sync("--apply", exit_code=2)["reason"], "unsupported_push_mapping")

    def test_remote_movement_during_check_blocks_push(self):
        self.commit(self.repo, "local")
        self.commit(self.peer, "remote change")
        result = self.sync("--apply", checks=[["git", "-C", str(self.peer), "push", "origin", "main"]], exit_code=2)
        self.assertEqual(result["reason"], "remote_changed")
        self.assertNotIn("push", result["actions"])
        self.assertEqual(result["after"]["remote"], self.oid(self.peer))

    def test_hooks_are_preserved_and_push_failure_is_honest(self):
        self.commit(self.repo, "local")
        marker = self.root / "hook-ran"
        self.hook(self.repo, "pre-push", "from pathlib import Path\nPath(" + repr(str(marker)) + ").touch()\nraise SystemExit(1)")
        result = self.sync("--apply", exit_code=1)
        self.assertEqual(result["reason"], "push_failed")
        self.assertTrue(marker.exists())
        self.assertNotIn("push", result["actions"])
        self.assertEqual(result["after"]["remote"], self.initial)

    def test_remote_movement_after_push_prevents_success_claim(self):
        self.commit(self.repo, "local")
        self.hook(self.remote, "post-receive", "import subprocess\nsubprocess.run(['git', '--git-dir', "
                  + repr(str(self.remote)) + ", 'update-ref', 'refs/heads/main', " + repr(self.initial) + "], check=True)")
        result = self.sync("--apply", exit_code=2)
        self.assertEqual(result["reason"], "remote_changed")
        self.assertIn("push", result["actions"])
        self.assertEqual(result["after"]["remote"], self.initial)
        self.assertIsNone(result["converged"])

    def test_push_timeout_after_acceptance_reports_observed_remote(self):
        local = self.commit(self.repo, "local")
        self.hook(self.remote, "post-receive", "import time\ntime.sleep(5)")
        result = self.sync("--apply", "--timeout", "1", exit_code=1)
        self.assertEqual(result["reason"], "push_timed_out")
        self.assertEqual(self.remote_oid(), local)
        self.assertEqual(result["after"], {"head": local, "remote": local})
        self.assertTrue(result["remote_verified"])
        self.assertIsNone(result["converged"])
        self.assertNotIn("push", result["actions"])

    def test_fast_forward_timeout_after_head_update_keeps_partial_state(self):
        remote = self.advance_remote()
        self.hook(self.repo, "post-merge", "import time\ntime.sleep(5)")
        result = self.sync("--apply", "--timeout", "1", exit_code=1)
        self.assertEqual(result["reason"], "fast_forward_timed_out")
        self.assertEqual(self.oid(self.repo), remote)
        self.assertEqual(result["after"]["head"], remote)
        self.assertIn("fast_forward", result["actions"])

    def test_invalid_arguments_are_json(self):
        for argv in (("--timeout", "nan"), ("--check", "echo unsafe"),
                     ("--check", '["ok", 1]'), ("--direction", "surprise")):
            with self.subTest(argv=argv):
                result = self.sync(*argv, exit_code=1)
                self.assertEqual(result["outcome"], "failed")


if __name__ == "__main__":
    unittest.main()
