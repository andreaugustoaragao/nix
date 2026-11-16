import importlib.util
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("credentials", Path(__file__).resolve().parents[1] / "home/cli/worker-git-credentials.py")
credentials = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(credentials)


class WorkerGitTest(unittest.TestCase):
    def test_fresh_ssh_directory_is_private_owned_and_preserves_existing_files(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            credentials.prepare(home, os.getuid(), os.getgid())
            target = home / ".ssh"
            self.assertEqual(target.stat().st_uid, os.getuid())
            self.assertEqual(target.stat().st_mode & 0o777, 0o700)
            (target / "unrelated").write_text("retain me")
            credentials.prepare(home, os.getuid(), os.getgid())
            self.assertEqual((target / "unrelated").read_text(), "retain me")

    def test_symlink_ssh_directory_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            (home / "other").mkdir()
            (home / ".ssh").symlink_to(home / "other")
            with self.assertRaises(ValueError):
                credentials.prepare(home, os.getuid(), os.getgid())

    def test_rotation_removes_only_retired_managed_keys_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="worker-git-") as temp:
            root = Path(temp)
            home = root / "home"; home.mkdir()
            secrets = root / "secrets"; secrets.mkdir()
            state = root / "state"
            credentials.prepare(home, os.getuid(), os.getgid())
            ssh_add = shutil.which("ssh-add")
            ssh_keygen = shutil.which("ssh-keygen")
            agent = subprocess.Popen([shutil.which("ssh-agent"), "-D", "-a", str(root / "socket")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            old_socket = os.environ.get("SSH_AUTH_SOCK")
            os.environ["SSH_AUTH_SOCK"] = str(root / "socket")
            try:
                for _ in range(100):
                    if (root / "socket").exists(): break
                    time.sleep(.01)
                askpass = root / "askpass"
                askpass.write_text(f"#!{shutil.which('sh')}\nexec {shlex.quote(shutil.which('cat'))} \"$WORKER_GIT_SSH_PASSPHRASE_FILE\"\n")
                askpass.chmod(0o700)
                def generate(path, password="", algorithm="ed25519", bits=None):
                    command = [ssh_keygen, "-q", "-t", algorithm, "-N", password, "-f", str(path)]
                    if bits:
                        command.extend(["-b", str(bits)])
                    subprocess.run(command, check=True)
                    return credentials.public_key(path.with_suffix(".pub").read_text())
                for identity in credentials.IDENTITIES:
                    generate(home / ".ssh" / ("id_rsa_" + identity), "fixture-passphrase")
                    (secrets / ("ssh_passphrase_" + identity)).write_text("fixture-passphrase")
                unrelated = root / "unrelated"
                unrelated_public = generate(unrelated, algorithm="ecdsa", bits=384)
                subprocess.run([ssh_add, str(unrelated)], check=True, capture_output=True)
                credentials.refresh(home, state, secrets, ssh_add, ssh_keygen, str(askpass))
                old_personal = json.loads((state / "managed-ssh.json").read_text())["keys"]["personal"]
                private = home / ".ssh/id_rsa_personal"
                private.unlink(); private.with_suffix(".pub").unlink()
                new_personal = generate(private, "fixture-passphrase")
                credentials.refresh(home, state, secrets, ssh_add, ssh_keygen, str(askpass))
                loaded = credentials.loaded_keys(ssh_add, dict(os.environ))
                self.assertIn(unrelated_public, loaded)
                self.assertIn(new_personal, loaded)
                self.assertNotIn(old_personal, loaded)
                ledger = (state / "managed-ssh.json").read_bytes()
                credentials.refresh(home, state, secrets, ssh_add, ssh_keygen, str(askpass))
                self.assertEqual(credentials.loaded_keys(ssh_add, dict(os.environ)), loaded)
                self.assertEqual((state / "managed-ssh.json").read_bytes(), ledger)
                private.unlink()
                with self.assertRaises(RuntimeError):
                    credentials.refresh(home, state, secrets, ssh_add, ssh_keygen, str(askpass))
                self.assertEqual(credentials.loaded_keys(ssh_add, dict(os.environ)), loaded)
                self.assertEqual((state / "managed-ssh.json").read_bytes(), ledger)
                private.with_suffix(".pub").unlink()
                interrupted_personal = generate(private, "fixture-passphrase")
                work_private = home / ".ssh/id_rsa_work"
                work_private.unlink(); work_private.with_suffix(".pub").unlink()
                new_work = generate(work_private, "fixture-passphrase")
                native_invoke = credentials.invoke
                def fail_work_add(arguments, environment):
                    if arguments == [ssh_add, str(work_private)]:
                        return subprocess.CompletedProcess(arguments, 1, "", "fixture failure")
                    return native_invoke(arguments, environment)
                with patch.object(credentials, "invoke", side_effect=fail_work_add):
                    with self.assertRaisesRegex(RuntimeError, "Cannot load"):
                        credentials.refresh(home, state, secrets, ssh_add, ssh_keygen, str(askpass))
                self.assertIn(interrupted_personal, credentials.loaded_keys(ssh_add, dict(os.environ)))
                private.unlink(); private.with_suffix(".pub").unlink()
                final_personal = generate(private, "fixture-passphrase")
                credentials.refresh(home, state, secrets, ssh_add, ssh_keygen, str(askpass))
                self.assertEqual(credentials.loaded_keys(ssh_add, dict(os.environ)),
                                 {unrelated_public, final_personal, new_work})
            finally:
                agent.terminate(); agent.wait(timeout=10)
                if old_socket is None: os.environ.pop("SSH_AUTH_SOCK", None)
                else: os.environ["SSH_AUTH_SOCK"] = old_socket


if __name__ == "__main__":
    unittest.main()
