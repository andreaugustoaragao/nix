#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

SOURCE = Path(__file__).with_name('pi-lifecycle-sampler.py')
SPEC = importlib.util.spec_from_file_location('t029_sampler', SOURCE)
sampler_module = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = sampler_module
SPEC.loader.exec_module(sampler_module)
LinuxIO = sampler_module.LinuxIO
ScopeSampler = sampler_module.ScopeSampler
ScopeState = sampler_module.ScopeState
UNIT = 't029-pi-qual-fixture.scope'
INVOCATION = '11111111111111111111111111111111'
GROUP = '/user.slice/user-1000.slice/user@1000.service/app.slice/' + UNIT
ENV = '/user.slice/user-1000.slice/user@1000.service/app.slice/hc-hold-fixture.service'


class Fixture:
    def __init__(self, root):
        self.proc = root / 'proc'; self.proc.mkdir()
        self.cgroup = root / 'cgroup'; self.cgroup.mkdir()
        self.commands = []
        self.show_text = '\n'.join(['Id=' + UNIT, 'LoadState=loaded', 'ActiveState=active',
                                    'SubState=running', 'Result=success', 'ControlGroup=' + GROUP,
                                    'InvocationID=' + INVOCATION])
        self.journal_text = ''
        self.group(GROUP, [42]); self.group(ENV, [])
        self.process(42, 100, 1, 42, GROUP)
        self.io = LinuxIO(self.proc, self.cgroup, self.command)

    def command(self, argv):
        self.commands.append(argv)
        if argv[0] == 'systemctl':
            return self.show_text
        if argv[0] == 'journalctl':
            return self.journal_text
        raise AssertionError('unexpected runtime command')

    def group(self, path, pids, events='oom 0\noom_kill 0\noom_group_kill 0\n', peak=4096):
        path = self.cgroup / path.lstrip('/'); path.mkdir(parents=True, exist_ok=True)
        (path / 'cgroup.procs').write_text('\n'.join(map(str, pids)))
        (path / 'memory.events').write_text(events)
        (path / 'memory.peak').write_text(str(peak))

    def process(self, pid, start, ppid, pgrp, group, state='S'):
        path = self.proc / str(pid); path.mkdir(exist_ok=True)
        fields = [state, str(ppid), str(pgrp)] + ['0'] * 16 + [str(start)] + ['0'] * 10
        (path / 'stat').write_text(f'{pid} (pi fixture ({pid})) ' + ' '.join(fields))
        (path / 'cgroup').write_text('0::' + group + '\n')
        (path / 'status').write_text('VmSwap:\t3 kB\nVmRSS:\t7 kB\nVmSize:\t13 kB\n')
        (path / 'smaps_rollup').write_text('Pss:\t5 kB\nSwapPss:\t2 kB\n')

    def remove_process(self, pid):
        shutil.rmtree(self.proc / str(pid))

    def active(self, unit=UNIT, expected=None):
        sampler = ScopeSampler(self.io, unit, expected, ENV, uid=1000)
        sampler.ingest(dict(kind='root_birth', rootPid=42, rootStartTicks=100))
        return sampler

    def completion_record(self, **overrides):
        return dict(USER_UNIT=UNIT, USER_INVOCATION_ID=INVOCATION,
                    _SYSTEMD_INVOCATION_ID='distinct-manager-invocation', _UID='1000',
                    MESSAGE_ID=sampler_module.UNIT_SUCCEEDED_MESSAGE_ID, **overrides)

    def unload(self, records, remove_root=True):
        if remove_root:
            self.remove_process(42)
        shutil.rmtree(self.cgroup / GROUP.lstrip('/'))
        self.show_text = 'LoadState=not-found\nActiveState=inactive\n'
        self.journal_text = '\n'.join(json.dumps(record) for record in records)


class ScopeFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='t029-sampler-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.f = Fixture(Path(self.temp.name))

    def test_01_healthy_unload_uses_user_manager_target_fields(self):
        sampler = self.f.active()
        active = sampler.tick(1)
        self.assertEqual(active['scope_state'], 'active')
        self.assertTrue(active['full_tree_coverage_complete'])
        self.assertEqual(active['bound_scope']['slice_ancestry'], GROUP.rsplit('/', 1)[0])
        self.assertEqual(active['environmental_reference_cgroup'], ENV)
        self.assertEqual(active['samples'][0]['composite_memory_charge_bytes'], 7 * 1024)
        self.assertEqual(active['samples'][0]['VmSize'], 13 * 1024)
        retained = active['last_retained_scope_counters']
        record = self.f.completion_record()
        self.assertNotIn('INVOCATION_ID', record)
        self.f.unload([record])
        result = sampler.tick(2)
        self.assertEqual(result['scope_state'], 'verified_completed')
        self.assertTrue(result['full_tree_coverage_complete'])
        self.assertEqual(result['final_scope_counters_status'], 'unavailable_unloaded')
        self.assertIsNone(result['final_scope_counters'])
        self.assertEqual(result['last_retained_scope_counters'], retained)
        self.assertEqual(result['live_survivors'], [])
        self.assertEqual(result['enrolled_prockeys'], ['42:100'])
        self.assertEqual(self.f.commands[-1], ['journalctl', '--user', '--user-unit=' + UNIT,
                                             '--invocation=' + INVOCATION, '--output=json'])
        self.assertEqual(result['scope_retained_oom_delta'], dict(oom=0, oom_kill=0, oom_group_kill=0))
        self.assertEqual(result['gateway_dollar_cost'], 'unknown')

    def test_02_retained_readable_completion(self):
        sampler = self.f.active(); sampler.tick(1)
        self.f.remove_process(42)
        self.f.group(GROUP, [], peak=9000)
        result = sampler.tick(2)
        self.assertEqual(result['scope_state'], 'verified_completed')
        self.assertTrue(result['full_tree_coverage_complete'])
        self.assertEqual(result['final_scope_counters_status'], 'read_at_completion')
        self.assertEqual(result['final_scope_counters']['memory_peak_bytes'], 9000)
        self.assertFalse(any(argv[0] == 'journalctl' for argv in self.f.commands))

    def completion_between_reads(self, unloaded, identity_unavailable=False):
        sampler = self.f.active(); sampler.tick(1)
        original = self.f.io.group_pids
        def finish(group):
            self.f.io.group_pids = original
            if unloaded:
                self.f.unload([self.f.completion_record()])
            else:
                self.f.remove_process(42); self.f.group(GROUP, [])
            if identity_unavailable:
                def unavailable():
                    raise ValueError('fixture process identities unavailable')
                self.f.io.procs = unavailable
            return original(group)
        self.f.io.group_pids = finish
        return sampler.tick(2)

    def test_08_readable_empty_refreshes_identities_after_exit_between_reads(self):
        result = self.completion_between_reads(False)
        self.assertEqual(result['scope_state'], 'verified_completed')
        self.assertTrue(result['full_tree_coverage_complete'])
        self.assertEqual(result['live_survivors'], [])
        self.assertEqual(result['samples'], [])
        self.assertEqual(result['enrolled_prockeys'], ['42:100'])
        self.assertEqual(result['final_scope_counters_status'], 'read_at_completion')
        self.assertFalse(any(gap['reason'] == 'process memory sample unavailable' for gap in result['sampling_gaps']))

    def test_09_unloaded_clean_receipt_refreshes_identities_after_exit_between_reads(self):
        result = self.completion_between_reads(True)
        self.assertEqual(result['scope_state'], 'verified_completed')
        self.assertTrue(result['full_tree_coverage_complete'])
        self.assertEqual(result['live_survivors'], [])
        self.assertEqual(result['samples'], [])
        self.assertEqual(result['enrolled_prockeys'], ['42:100'])
        self.assertIsNone(result['final_scope_counters'])
        self.assertEqual(result['final_scope_counters_status'], 'unavailable_unloaded')
        self.assertFalse(any(gap['reason'] == 'process memory sample unavailable' for gap in result['sampling_gaps']))

    def test_terminal_identity_refresh_unavailable_rejects_completion(self):
        for unloaded in (False, True):
            with self.subTest(unloaded=unloaded):
                root = Path(self.temp.name) / str(unloaded); root.mkdir()
                self.f = Fixture(root)
                result = self.completion_between_reads(unloaded, identity_unavailable=True)
                self.assertEqual(result['scope_state'], 'lost_or_incomplete')
                self.assertFalse(result['full_tree_coverage_complete'])
                self.assertTrue(result['sampling_gaps'])

    def test_readable_empty_with_real_enrolled_survivor_rejects_completion(self):
        sampler = self.f.active(); sampler.tick(1)
        self.f.process(42, 100, 1, 42, '/outside-scope')
        self.f.group(GROUP, [])
        result = sampler.tick(2)
        self.assertEqual(result['scope_state'], 'lost_or_incomplete')
        self.assertFalse(result['full_tree_coverage_complete'])
        self.assertEqual(result['live_survivors'], ['42:100'])

    def test_03_wrong_path_and_control_group_mismatch(self):
        for unit, expected in [('nonexistent.scope', None), (UNIT, '/wrong/path')]:
            with self.subTest(unit=unit, expected=expected):
                result = self.f.active(unit, expected).tick(1)
                self.assertEqual(result['scope_state'], 'lost_or_incomplete')
                self.assertFalse(result['full_tree_coverage_complete'])
                self.assertIsNone(result['bound_scope'])
        self.f.process(42, 100, 1, 42, '/wrong/path')
        self.assertEqual(self.f.active().tick(1)['scope_state'], 'lost_or_incomplete')

    def test_04_startup_failed_or_root_missing(self):
        self.f.show_text = self.f.show_text.replace('ActiveState=active', 'ActiveState=failed')
        self.assertEqual(self.f.active().tick(1)['scope_state'], 'lost_or_incomplete')
        self.f.show_text = self.f.show_text.replace('ActiveState=failed', 'ActiveState=active')
        self.f.remove_process(42)
        result = self.f.active().tick(1)
        self.assertEqual(result['scope_state'], 'lost_or_incomplete')
        self.assertFalse(result['full_tree_coverage_complete'])

    def test_05_missing_enrollment_is_sampled_ppid_only(self):
        sampler = self.f.active(unit=None)
        self.f.process(43, 120, 42, 43, GROUP)
        result = sampler.tick(1)
        self.assertEqual(result['scope_state'], 'unestablished')
        self.assertEqual(result['native_family_coverage'], 'sampled_ppid_only')
        self.assertFalse(result['full_tree_coverage_complete'])
        self.assertEqual(result['enrolled_prockeys'], ['42:100', '43:120'])
        self.assertEqual(self.f.commands, [])

    def test_06_raw_mismatch_failure_oom_and_lost_evidence(self):
        positive = self.f.completion_record()
        cases = [[], [{}], [{**positive, 'USER_UNIT': 'wrong.scope'}],
                 [{**positive, 'USER_INVOCATION_ID': 'wrong'}], [{**positive, '_UID': '999'}],
                 [{**positive, 'MESSAGE_ID': 'generic', 'MESSAGE': 'Unit finished successfully'}],
                 [{**positive, 'USER_INVOCATION_ID': None, 'INVOCATION_ID': INVOCATION}],
                 [positive, {**positive, 'UNIT_RESULT': 'failed'}],
                 [positive, {**positive, 'MESSAGE_ID': 'd9b373ed55a64feb8242e02dbe79a49c'}],
                 [positive, {**positive, 'MESSAGE_ID': 'fe6faa94e7774663a0da52717891d8ef'}],
                 [positive, {**positive, 'MESSAGE_ID': 'd989611b15e44c9dbf31e3c81256e4ed'}]]
        for records in cases:
            with self.subTest(records=records), tempfile.TemporaryDirectory(prefix='t029-sampler-fixture-') as tmp:
                f = Fixture(Path(tmp)); sampler = f.active(); sampler.tick(1)
                f.unload(records)
                result = sampler.tick(2)
                self.assertEqual(result['scope_state'], 'lost_or_incomplete')
                self.assertFalse(result['full_tree_coverage_complete'])
                self.assertIsNone(result['final_scope_counters'])
        sampler = self.f.active(); sampler.tick(1)
        self.f.unload([positive], remove_root=False)
        result = sampler.tick(2)
        self.assertEqual(result['scope_state'], 'lost_or_incomplete')
        self.assertEqual(result['live_survivors'], ['42:100'])

    def test_07_native_orphan_and_pgid_continuity(self):
        sampler = self.f.active(); sampler.tick(1)
        self.f.remove_process(42)
        self.f.process(43, 120, 1, 70, GROUP)
        self.f.group(GROUP, [43])
        result = sampler.tick(2)
        self.assertEqual(result['scope_state'], 'active')
        self.assertIn('43:120', result['enrolled_prockeys'])
        self.assertEqual(result['samples'][0]['bucket'], 'native_scoped')
        self.assertEqual(result['live_survivors'], ['43:120'])
        unscoped = ScopeSampler(self.f.io, uid=1000)
        unscoped.ingest(dict(kind='group_birth', childPid=43, childStartTicks=120, pgid=70))
        unscoped.ingest(dict(kind='group_settled', childPid=43, pgid=70, ok=True))
        self.assertTrue(unscoped.leases[(70, 43)].closed)
        self.f.process(44, 140, 1, 70, GROUP)
        unscoped.tick(3)
        self.assertNotIn(sampler_module.ProcKey(44, 140), unscoped.enrolled_prockeys)
        discontinuous = ScopeSampler(self.f.io, uid=1000)
        discontinuous.ingest(dict(kind='group_birth', childPid=43, childStartTicks=120, pgid=70))
        self.f.process(43, 120, 1, 99, GROUP)
        result = discontinuous.tick(3)
        self.assertTrue(result['ownership_ambiguous'])
        self.assertFalse(result['full_tree_coverage_complete'])
        self.assertNotIn('44:140', result['enrolled_prockeys'])

    def test_gaps_unknown_counters_pid_reuse_and_birth_faults_remain_visible(self):
        sampler = self.f.active(); sampler.tick(1)
        (self.f.cgroup / GROUP.lstrip('/') / 'memory.events').unlink()
        (self.f.proc / '42' / 'smaps_rollup').unlink()
        result = sampler.tick(4)
        self.assertGreaterEqual(len(result['sampling_gaps']), 2)
        self.assertEqual(result['samples'][0]['charge_basis'], 'unavailable')
        sampler.ingest(dict(kind='group_birth', childPid=80, pgid=80, childStartTicks=None))
        self.assertFalse(sampler.full_tree_coverage_complete)
        self.f.process(42, 999, 1, 42, GROUP)
        self.f.group(GROUP, [42])
        result = sampler.tick(5)
        self.assertIn('42:100', result['enrolled_prockeys'])
        self.assertIn('42:999', result['enrolled_prockeys'])

    def dead_completion(self, unloaded, state='Z', unavailable_memory=False):
        self.f.group(GROUP, [42], peak=16384)
        sampler = self.f.active()
        sampler.ingest(dict(kind='group_birth', childPid=42, childStartTicks=100, pgid=42))
        active = sampler.tick(1)
        self.assertEqual(active['samples'][0]['composite_memory_charge_bytes'], 7 * 1024)
        retained = active['last_retained_scope_counters']
        self.f.process(42, 100, 1, 42, '/outside-scope', state=state)
        key = sampler_module.ProcKey(42, 100)
        self.assertEqual(self.f.io.procs()[key].state, state, 'Full Linux identity scan must retain the dead identity')
        if unavailable_memory:
            (self.f.proc / '42' / 'status').unlink()
            (self.f.proc / '42' / 'smaps_rollup').unlink()
        if unloaded:
            self.f.unload([self.f.completion_record()], remove_root=False)
        else:
            self.f.group(GROUP, [], peak=16384)
        result = sampler.tick(2)
        self.assertEqual(result['scope_state'], 'verified_completed')
        self.assertTrue(result['full_tree_coverage_complete'])
        self.assertEqual(result['live_survivors'], [])
        self.assertEqual(result['enrolled_prockeys'], ['42:100'])
        self.assertEqual(result['samples'], [], 'Dead identities must not produce executing-process memory samples or fabricated zeroes')
        self.assertIn(key, sampler.leases[(42, 42)].enrolled_keys)
        self.assertTrue(sampler.leases[(42, 42)].closed)
        self.assertEqual(result['last_retained_scope_counters']['memory_peak_bytes'], retained['memory_peak_bytes'])
        if unloaded:
            self.assertIsNone(result['final_scope_counters'])
            self.assertEqual(result['final_scope_counters_status'], 'unavailable_unloaded')
            self.assertIsNotNone(result['terminal_completion_receipt'])
        else:
            self.assertEqual(result['final_scope_counters']['memory_peak_bytes'], 16384)
            self.assertEqual(result['final_scope_counters_status'], 'read_at_completion')
        self.assertFalse(any(gap['reason'] in ('process memory sample unavailable', 'process memory charge unavailable') for gap in result['sampling_gaps']))
        return result

    def test_r11_readable_completion_retains_zombie_history_without_live_survivor(self):
        self.dead_completion(False)

    def test_r11_unloaded_receipt_retains_zombie_history_without_live_survivor(self):
        self.dead_completion(True)

    def test_r11_dead_unavailable_memory_preserves_completion_and_historical_peak(self):
        for state in ('Z', 'X', 'x'):
            for unloaded in (False, True):
                with self.subTest(state=state, unloaded=unloaded), tempfile.TemporaryDirectory(prefix='t029-sampler-fixture-') as tmp:
                    self.f = Fixture(Path(tmp))
                    self.dead_completion(unloaded, state, unavailable_memory=True)

    def test_r11_stopped_live_and_unknown_survivors_still_reject_completion(self):
        for state in ('R', 'S', 'D', 'T', 't', 'I', 'P', 'W', '?', 'z', 'ZX'):
            for unloaded in (False, True):
                with self.subTest(state=state, unloaded=unloaded), tempfile.TemporaryDirectory(prefix='t029-sampler-fixture-') as tmp:
                    f = Fixture(Path(tmp)); sampler = f.active(); sampler.tick(1)
                    f.process(42, 100, 1, 42, '/outside-scope', state=state)
                    if unloaded:
                        f.unload([f.completion_record()], remove_root=False)
                    else:
                        f.group(GROUP, [])
                    result = sampler.tick(2)
                    self.assertEqual(result['scope_state'], 'lost_or_incomplete')
                    self.assertFalse(result['full_tree_coverage_complete'])
                    self.assertEqual(result['live_survivors'], ['42:100'])
                    self.assertEqual(result['enrolled_prockeys'], ['42:100'])

    def test_r11_dead_anchor_cannot_extend_unscoped_group_ownership(self):
        for state in ('Z', 'X', 'x'):
            with self.subTest(state=state), tempfile.TemporaryDirectory(prefix='t029-sampler-fixture-') as tmp:
                f = Fixture(Path(tmp)); f.process(42, 100, 1, 70, GROUP, state=state)
                f.process(43, 120, 1, 70, GROUP)
                sampler = ScopeSampler(f.io, uid=1000)
                sampler.ingest(dict(kind='group_birth', childPid=42, childStartTicks=100, pgid=70))
                result = sampler.tick(1)
                self.assertEqual(result['enrolled_prockeys'], ['42:100'])
                self.assertEqual(result['live_survivors'], [])
                self.assertTrue(result['ownership_ambiguous'])
                self.assertFalse(result['full_tree_coverage_complete'])
                self.assertEqual(sampler.leases[(70, 42)].enrolled_keys, {sampler_module.ProcKey(42, 100)})

    def test_r11_dead_parent_cannot_extend_sampled_ppid_family(self):
        f = self.f; f.process(42, 100, 1, 42, GROUP, state='Z'); f.process(43, 120, 42, 43, GROUP)
        result = f.active(unit=None).tick(1)
        self.assertEqual(result['enrolled_prockeys'], ['42:100'])
        self.assertEqual(result['live_survivors'], [])
        self.assertEqual(result['native_family_coverage'], 'sampled_ppid_only')
        self.assertFalse(result['full_tree_coverage_complete'])

    def test_r11_dead_root_does_not_complete_scope_with_live_member(self):
        sampler = self.f.active(); sampler.tick(1)
        self.f.process(42, 100, 1, 42, '/outside-scope', state='Z')
        self.f.process(43, 120, 1, 43, GROUP); self.f.group(GROUP, [43])
        result = sampler.tick(2)
        self.assertEqual(result['scope_state'], 'active')
        self.assertTrue(result['full_tree_coverage_complete'])
        self.assertEqual(result['enrolled_prockeys'], ['42:100', '43:120'])
        self.assertEqual(result['live_survivors'], ['43:120'])
        self.assertEqual([sample['prockey'] for sample in result['samples']], ['43:120'])


if __name__ == '__main__':
    unittest.main()
