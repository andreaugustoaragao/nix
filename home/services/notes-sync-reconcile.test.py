import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('notes-sync-reconcile.sh')
GIT = shutil.which('git')
BASH = shutil.which('bash')


class NotesSyncTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='notes-sync-check-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = {**{key: value for key, value in os.environ.items() if not key.startswith('GIT_')},
                    'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull,
                    'GIT_TERMINAL_PROMPT': '0', 'NOTES_SYNC_GIT': GIT}
        self.remote = self.root / 'origin.git'
        self.local = self.root / 'local'
        self.peer = self.root / 'peer'
        self.git(self.root, 'init', '--bare', '--initial-branch=main', str(self.remote))
        self.git(self.root, 'clone', str(self.remote), str(self.local))
        self.configure(self.local)
        (self.local / 'note.md').write_text('Original note\n')
        (self.local / 'other.md').write_text('Original other note\n')
        (self.local / 'document with spaces.bin').write_bytes(b'\x00original\n')
        self.commit(self.local, 'initial')
        self.git(self.local, 'push', 'origin', 'main')
        self.git(self.root, 'clone', str(self.remote), str(self.peer))
        self.configure(self.peer)

    def git(self, cwd, *args, check=True):
        return subprocess.run([GIT, *args], cwd=cwd, env=self.env, check=check,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def configure(self, cwd):
        self.git(cwd, 'config', 'user.name', 'Fixture')
        self.git(cwd, 'config', 'user.email', 'fixture@example.invalid')
        self.git(cwd, 'config', 'commit.gpgsign', 'false')
        self.git(cwd, 'config', 'core.hooksPath', str(self.root / 'absent-hooks'))

    def commit(self, cwd, message):
        self.git(cwd, 'add', '--all')
        self.git(cwd, 'commit', '-m', message)

    def run_sync(self, cwd=None, *args):
        return subprocess.run([BASH, str(SCRIPT), *args], cwd=cwd or self.local, env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def head(self, cwd):
        return self.git(cwd, 'rev-parse', 'HEAD').stdout

    def publish_peer(self, path, data):
        (self.peer / path).write_bytes(data)
        self.commit(self.peer, 'peer change')
        self.git(self.peer, 'push', 'origin', 'main')

    def test_local_and_remote_edits_merge_and_replay_without_new_commits(self):
        (self.local / 'note.md').write_text('Local edit\n')
        self.publish_peer('other.md', b'Remote edit\n')
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual((self.local / 'note.md').read_text(), 'Local edit\n')
        self.assertEqual((self.local / 'other.md').read_text(), 'Remote edit\n')
        before = self.head(self.local)
        self.assertEqual(self.head(self.remote), before)
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.head(self.local), before)

    def test_conflict_keeps_both_index_versions_and_refuses_repeated_sync(self):
        (self.local / 'note.md').write_text('Local conflict\n')
        self.publish_peer('note.md', b'Remote conflict\n')
        remote_head = self.head(self.remote)
        result = self.run_sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.local / '.git/MERGE_HEAD').is_file())
        self.assertEqual(self.git(self.local, 'show', ':2:note.md').stdout, b'Local conflict\n')
        self.assertEqual(self.git(self.local, 'show', ':3:note.md').stdout, b'Remote conflict\n')
        before = {p: (self.local / p).read_bytes() for p in ['note.md', '.git/index', '.git/MERGE_HEAD']}
        local_head = self.head(self.local)
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual({p: (self.local / p).read_bytes() for p in before}, before)
        self.assertEqual(self.head(self.local), local_head)
        self.assertEqual(self.head(self.remote), remote_head)

    def test_binary_delete_modify_conflict_preserves_original_and_remote_bytes(self):
        name = 'document with spaces.bin'
        (self.local / name).unlink()
        self.publish_peer(name, b'\x00remote revision\n')
        remote_head = self.head(self.remote)
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(self.git(self.local, 'show', ':1:' + name).stdout, b'\x00original\n')
        self.assertEqual(self.git(self.local, 'show', ':3:' + name).stdout, b'\x00remote revision\n')
        self.assertEqual(self.head(self.remote), remote_head)
        self.assertNotEqual(self.run_sync().returncode, 0)

    def test_stash_conflict_without_merge_head_is_preserved(self):
        (self.local / 'note.md').write_text('Stashed local edit\n')
        self.git(self.local, 'stash', 'push')
        self.publish_peer('note.md', b'Remote edit\n')
        self.git(self.local, 'pull', '--ff-only')
        self.assertNotEqual(self.git(self.local, 'stash', 'pop', check=False).returncode, 0)
        self.assertFalse((self.local / '.git/MERGE_HEAD').exists())
        before = (self.local / 'note.md').read_bytes(), (self.local / '.git/index').read_bytes()
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(((self.local / 'note.md').read_bytes(), (self.local / '.git/index').read_bytes()), before)

    def test_other_branch_is_not_committed_or_pushed(self):
        self.git(self.local, 'checkout', '-b', 'manual-work')
        (self.local / 'note.md').write_text('Manual unfinished work\n')
        before = self.head(self.local), (self.local / '.git/index').read_bytes()
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual((self.head(self.local), (self.local / '.git/index').read_bytes()), before)
        self.assertEqual((self.local / 'note.md').read_text(), 'Manual unfinished work\n')

    def test_missing_repository_never_creates_or_moves_notes(self):
        directory = self.root / 'unmanaged'; directory.mkdir()
        (directory / 'note.md').write_text('Keep this\n')
        self.assertNotEqual(self.run_sync(directory).returncode, 0)
        self.assertEqual([p.name for p in directory.iterdir()], ['note.md'])
        self.assertEqual((directory / 'note.md').read_text(), 'Keep this\n')

    def test_fetch_failure_keeps_uncommitted_edits_and_index(self):
        self.git(self.local, 'remote', 'set-url', 'origin', str(self.root / 'missing-remote'))
        (self.local / 'note.md').write_text('Local unpublished work\n')
        before = self.head(self.local), (self.local / '.git/index').read_bytes()
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual((self.head(self.local), (self.local / '.git/index').read_bytes()), before)
        self.assertEqual((self.local / 'note.md').read_text(), 'Local unpublished work\n')

    def test_check_mode_leaves_work_and_remote_tracking_unchanged(self):
        (self.local / 'note.md').write_text('Local unfinished work\n')
        self.publish_peer('other.md', b'New remote work\n')
        before = self.head(self.local), (self.local / '.git/index').read_bytes(), self.git(self.local, 'rev-parse', 'origin/main').stdout
        self.assertEqual(self.run_sync(None, '--check').returncode, 0)
        after = self.head(self.local), (self.local / '.git/index').read_bytes(), self.git(self.local, 'rev-parse', 'origin/main').stdout
        self.assertEqual(after, before)
        self.assertEqual((self.local / 'note.md').read_text(), 'Local unfinished work\n')

    def test_cutover_markers_block_sync_and_check_without_changing_notes(self):
        directory = self.local / '.fulcrum/shared-runtime'; directory.mkdir(parents=True)
        (self.local / 'note.md').write_text('Work before cutover\n')
        before = self.head(self.local), (self.local / '.git/index').read_bytes()
        for kind in ['complete', 'partial', 'dangling']:
            marker = directory / ('cutover.json.partial' if kind == 'partial' else 'cutover.json')
            if kind == 'dangling':
                marker.symlink_to(directory / 'missing-marker-target')
            else:
                marker.write_text('{unfinished')
            try:
                self.assertNotEqual(self.run_sync().returncode, 0)
                self.assertNotEqual(self.run_sync(None, '--check').returncode, 0)
                self.assertEqual((self.head(self.local), (self.local / '.git/index').read_bytes()), before)
                self.assertEqual((self.local / 'note.md').read_text(), 'Work before cutover\n')
            finally:
                marker.unlink()

    @unittest.skipIf(os.geteuid() == 0, 'Root can inspect mode-000 directories')
    def test_uninspectable_cutover_parent_is_not_treated_as_an_absent_marker(self):
        directory = self.local / '.fulcrum/shared-runtime'; directory.mkdir(parents=True)
        (self.local / 'note.md').write_text('Keep local work\n')
        before = self.head(self.local), (self.local / '.git/index').read_bytes()
        for parent in [directory, directory.parent]:
            parent.chmod(0)
            try:
                self.assertNotEqual(self.run_sync().returncode, 0)
                self.assertEqual((self.head(self.local), (self.local / '.git/index').read_bytes()), before)
                self.assertEqual((self.local / 'note.md').read_text(), 'Keep local work\n')
            finally:
                parent.chmod(0o700)


if __name__ == '__main__':
    unittest.main()
