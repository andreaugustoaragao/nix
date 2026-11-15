import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("worker_jobs", Path(__file__).with_name("workstation-job.py"))
jobs = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = jobs
spec.loader.exec_module(jobs)

class JobTests(unittest.TestCase):
    def test_arguments_survive_round_trip_without_shell_interpretation(self):
        value = {"identifier": str(uuid.uuid4()), "kind": "run", "system": "x86_64-linux", "command": ["printf", "$(touch injected); `id`", "a b", "line\nbreak"], "category": "personal"}
        self.assertEqual(jobs.Job.parse(json.loads(json.dumps(value))).as_json(), value)

    def test_work_copies_remain_under_the_work_project_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            with patch.object(Path, "home", return_value=home):
                identifier = str(uuid.uuid4())
                directory = jobs.job_directory(identifier, "work")
                directory.mkdir()
                self.assertTrue(directory.is_relative_to(home / "projects/work"))
                self.assertEqual(jobs.job_directory(identifier), directory)

    def test_unknown_architecture_is_rejected(self):
        with self.assertRaises(ValueError):
            jobs.Job.parse({"identifier": str(uuid.uuid4()), "kind": "cargo", "system": "aarch64-darwin", "command": ["build"]})

    def test_path_cannot_be_used_as_identifier(self):
        with self.assertRaises(ValueError):
            jobs.Job.parse({"identifier": "../../other", "kind": "cargo", "system": "x86_64-linux", "command": []})

    def test_agent_selection_is_explicit(self):
        with self.assertRaises(ValueError):
            jobs.Job.parse({"identifier": str(uuid.uuid4()), "kind": "agent", "system": "x86_64-linux", "command": ["sh"]})

    def test_ignored_credentials_and_build_outputs_are_not_uploaded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / ".gitignore").write_text(".env\ntarget/\n")
            (root / ".env").write_text("private")
            (root / "target").mkdir()
            (root / "target/binary").write_text("build output")
            (root / "source with spaces.rs").write_text("fn main() {}")
            self.assertEqual(jobs.source_files(root).split(b"\0")[:-1], [b".gitignore", b"source with spaces.rs"])

    def test_tracked_ignored_file_remains_part_of_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "required.lock").write_text("tracked")
            subprocess.run(["git", "-C", str(root), "add", "required.lock"], check=True)
            (root / ".gitignore").write_text("required.lock\n")
            self.assertIn(b"required.lock", jobs.source_files(root).split(b"\0"))

    def test_deleted_tracked_files_are_absent_from_source_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "removed.rs").write_text("old source")
            subprocess.run(["git", "-C", str(root), "add", "removed.rs"], check=True)
            (root / "removed.rs").unlink()
            self.assertNotIn(b"removed.rs", jobs.source_files(root).split(b"\0"))

    def test_review_includes_untracked_generated_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            subprocess.run(["git", "-C", str(source), "-c", "user.name=Worker", "-c", "user.email=worker@localhost", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "snapshot"], check=True)
            (root / "baseline").write_bytes(subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"]))
            (source / "new file.rs").write_text("fn added() {}\n")
            with tempfile.TemporaryFile() as output:
                self.assertEqual(jobs.review_diff(root, output), 0)
                output.seek(0)
                self.assertIn(b"+fn added() {}", output.read())

    def test_nested_git_repository_requires_separate_submission(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(["git", "init", "-q", str(root / "nested")], check=True)
            (root / "nested/file").write_text("source")
            with self.assertRaisesRegex(ValueError, "nested Git"):
                jobs.source_files(root)

if __name__ == "__main__":
    unittest.main()
