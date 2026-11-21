#!/usr/bin/env python3
"""Finite Pi qualification sampler. Runtime collection is separate from installation."""
import argparse
from dataclasses import dataclass, field
from enum import Enum
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import time

UNIT_SUCCEEDED_MESSAGE_ID = '7ad2d189f7e94e70a38c781354912448'
UNIT_FAILURE_OR_OOM_MESSAGE_IDS = {
    'd9b373ed55a64feb8242e02dbe79a49c',
    'fe6faa94e7774663a0da52717891d8ef',
    'd989611b15e44c9dbf31e3c81256e4ed',
}


class ScopeState(str, Enum):
    UNESTABLISHED = 'unestablished'
    ACTIVE = 'active'
    COMPLETED = 'verified_completed'
    LOST = 'lost_or_incomplete'


@dataclass(frozen=True, order=True)
class ProcKey:
    pid: int
    start_ticks: int

    def text(self):
        return f'{self.pid}:{self.start_ticks}'


@dataclass
class ProcInfo:
    key: ProcKey
    ppid: int
    pgrp: int
    name: str
    state: str


def live_processes(procs):
    # Keep the full identity scan separate from execution/ownership evidence.
    # Only confirmed Linux zombie/dead states can be excluded; unknowns stay live.
    return {key: info for key, info in procs.items() if info.state not in ('Z', 'X', 'x')}


@dataclass
class GroupLease:
    pgid: int
    anchor: ProcKey
    enrolled_keys: set[ProcKey] = field(default_factory=set)
    closed: bool = False


def validate_user_scope_journal_completion(records, unit_name, invocation_id, uid):
    saw_success = False
    for record in records:
        if not isinstance(record, dict):
            continue
        if record.get('USER_UNIT') != unit_name or record.get('USER_INVOCATION_ID') != invocation_id:
            continue
        if record.get('_UID') is not None and str(record['_UID']) != str(uid):
            continue
        if record.get('MESSAGE_ID') in UNIT_FAILURE_OR_OOM_MESSAGE_IDS:
            return False
        if record.get('UNIT_RESULT') is not None and record['UNIT_RESULT'] != 'success':
            return False
        if record.get('MESSAGE_ID') == UNIT_SUCCEEDED_MESSAGE_ID:
            saw_success = True
    return saw_success


def parse_proc_stat(text):
    end = text.rfind(')')
    if end < 0:
        raise ValueError('invalid proc stat')
    pid = int(text[:text.index(' ')])
    fields = text[end + 2:].split()
    key = ProcKey(pid, int(fields[19]))
    if key.pid <= 0 or key.start_ticks <= 0:
        raise ValueError('invalid process identity')
    return ProcInfo(key, int(fields[1]), int(fields[2]), text[text.index('(') + 1:end], fields[0])


def parse_show(text):
    return dict(line.split('=', 1) for line in text.splitlines() if '=' in line)


def parse_journal(text):
    return [json.loads(line) for line in text.splitlines() if line.strip()]


class LinuxIO:
    def __init__(self, proc_root=Path('/proc'), cgroup_root=Path('/sys/fs/cgroup'), command=None):
        self.proc_root = Path(proc_root)
        self.cgroup_root = Path(cgroup_root)
        self.command = command or self.run_command

    @staticmethod
    def run_command(argv):
        result = subprocess.run(argv, capture_output=True, text=True, timeout=3, check=True)
        return result.stdout

    def show(self, unit):
        fields = 'Id,LoadState,ActiveState,SubState,Result,ControlGroup,InvocationID'
        return parse_show(self.command(['systemctl', '--user', 'show', '--property=' + fields, '--', unit]))

    def journal(self, unit, invocation):
        return parse_journal(self.command(['journalctl', '--user', '--user-unit=' + unit,
                                          '--invocation=' + invocation, '--output=json']))

    def proc(self, pid):
        return parse_proc_stat((self.proc_root / str(pid) / 'stat').read_text())

    def procs(self):
        result = {}
        for path in self.proc_root.iterdir():
            if not path.name.isdecimal():
                continue
            try:
                info = self.proc(int(path.name))
                result[info.key] = info
            except FileNotFoundError:
                continue
        return result

    def group_path(self, group):
        if not isinstance(group, str) or not group.startswith('/') or '..' in PurePosixPath(group).parts:
            raise ValueError('invalid cgroup path')
        return self.cgroup_root / group.lstrip('/')

    def membership(self, pid):
        return (self.proc_root / str(pid) / 'cgroup').read_text().splitlines()

    def group_pids(self, group):
        return [int(pid) for pid in (self.group_path(group) / 'cgroup.procs').read_text().split()]

    def counters(self, group):
        path = self.group_path(group)
        events = dict((key, int(value)) for key, value in
                      (line.split() for line in (path / 'memory.events').read_text().splitlines()))
        peak = int((path / 'memory.peak').read_text().strip())
        return dict(memory_events=events, memory_peak_bytes=peak)

    def memory(self, pid):
        path = self.proc_root / str(pid)
        status = {}
        for line in (path / 'status').read_text().splitlines():
            if ':' not in line:
                continue
            key, value = line.split(':', 1)
            if key in ('VmSwap', 'VmRSS', 'VmSize'):
                status[key] = int(value.split()[0]) * 1024
        try:
            for line in (path / 'smaps_rollup').read_text().splitlines():
                if ':' not in line:
                    continue
                key, value = line.split(':', 1)
                if key in ('Pss', 'SwapPss'):
                    status[key] = int(value.split()[0]) * 1024
        except FileNotFoundError:
            pass
        if 'Pss' in status and 'SwapPss' in status:
            status['composite_memory_charge_bytes'] = status['Pss'] + status['SwapPss']
            status['charge_basis'] = 'Pss+SwapPss'
        elif 'Pss' in status and 'VmSwap' in status:
            status['composite_memory_charge_bytes'] = status['Pss'] + status['VmSwap']
            status['charge_basis'] = 'Pss+VmSwap_fallback'
        else:
            status['composite_memory_charge_bytes'] = None
            status['charge_basis'] = 'unavailable'
        return status


class ScopeSampler:
    def __init__(self, io, scope_unit=None, scope_cgroup=None, env_ref_cgroup=None, uid=None):
        self.io = io
        self.scope_unit = scope_unit
        self.expected_cgroup = scope_cgroup
        self.environmental_reference_cgroup = env_ref_cgroup
        self.uid = os.getuid() if uid is None else uid
        self.scope_state = ScopeState.UNESTABLISHED
        self.bound_scope = None
        self.root_key = None
        self.root_keys = set()
        self.enrolled_prockeys = set()
        self.leases = {}
        self.birth_errors = 0
        self.ownership_ambiguous = False
        self.sampling_gaps = []
        self.last_retained_scope_counters = None
        self.first_scope_counters = None
        self.final_scope_counters = None
        self.final_scope_counters_status = 'not_reached'
        self.terminal_completion_receipt = None
        self.env_first = None
        self.env_last = None
        self.live_survivors = []
        self.seq = 0
        self.last_tick = None
        self.offset = 0
        self.event_tail = ''
        self.failed_lifecycle_records = []

    @property
    def full_tree_coverage_complete(self):
        return (self.scope_state in (ScopeState.ACTIVE, ScopeState.COMPLETED)
                and self.bound_scope is not None and not self.ownership_ambiguous and self.birth_errors == 0)

    def gap(self, reason):
        self.sampling_gaps.append(dict(seq=self.seq, ts=time.time(), reason=reason))

    def lose(self, reason):
        self.scope_state = ScopeState.LOST
        self.gap(reason)

    def ingest(self, record):
        try:
            if not isinstance(record, dict):
                raise ValueError('event must be an object')
            if record.get('ok') is False:
                self.failed_lifecycle_records.append(record)
            if record.get('kind') == 'root_birth':
                key = ProcKey(int(record['rootPid']), int(record['rootStartTicks']))
                if key.pid <= 0 or key.start_ticks <= 0:
                    raise ValueError('invalid root identity')
                self.root_key = key; self.root_keys.add(key); self.enrolled_prockeys.add(key)
            elif record.get('kind') == 'group_birth':
                key = ProcKey(int(record['childPid']), int(record['childStartTicks']))
                pgid = int(record['pgid'])
                if min(key.pid, key.start_ticks, pgid) <= 0:
                    raise ValueError('invalid group identity')
                self.enrolled_prockeys.add(key)
                self.leases[(pgid, key.pid)] = GroupLease(pgid, key, {key})
            elif record.get('kind') == 'group_settled' and record.get('ok') is True:
                lease = self.leases.get((record.get('pgid'), record.get('childPid')))
                if lease:
                    lease.closed = True
        except (ValueError, TypeError, KeyError):
            self.birth_errors += 1
            self.gap('invalid birth/event identity')

    def read_events(self, path):
        try:
            with Path(path).open() as stream:
                if Path(path).stat().st_size < self.offset:
                    self.birth_errors += 1; self.gap('event file truncated'); return
                stream.seek(self.offset)
                text = self.event_tail + stream.read()
                self.offset = stream.tell()
            lines = text.split('\n'); self.event_tail = lines.pop()
            for line in lines:
                if not line.strip():
                    continue
                try:
                    self.ingest(json.loads(line))
                except json.JSONDecodeError:
                    self.birth_errors += 1; self.gap('invalid lifecycle JSON')
        except OSError:
            self.birth_errors += 1; self.gap('lifecycle events unavailable')

    def bind(self):
        if self.scope_unit is None:
            return
        try:
            show = self.io.show(self.scope_unit)
            root = self.io.proc(self.root_key.pid) if self.root_key else None
            group = show.get('ControlGroup')
            if not (show.get('Id') == self.scope_unit and show.get('LoadState') == 'loaded'
                    and show.get('ActiveState') == 'active' and show.get('SubState') == 'running'
                    and show.get('InvocationID') and isinstance(group, str) and group.startswith('/')
                    and root and root.key == self.root_key
                    and '0::' + group in self.io.membership(root.key.pid)
                    and root.key.pid in self.io.group_pids(group)
                    and (self.expected_cgroup is None or self.expected_cgroup == group)):
                self.lose('scope enrollment binding failed'); return
            self.bound_scope = dict(unit=self.scope_unit, invocation_id=show['InvocationID'],
                                    control_group=group, slice_ancestry=group.rsplit('/', 1)[0],
                                    root_prockey=self.root_key.text())
            self.scope_state = ScopeState.ACTIVE
        except (OSError, ValueError, subprocess.SubprocessError):
            self.lose('scope enrollment evidence unavailable')

    def enroll_leases(self, current):
        for lease in self.leases.values():
            if lease.closed:
                continue
            known = [key for key in lease.enrolled_keys if key in current and current[key].pgrp == lease.pgid]
            unseen = [info for key, info in current.items() if info.pgrp == lease.pgid
                      and key not in lease.enrolled_keys and key.start_ticks >= lease.anchor.start_ticks]
            if self.bound_scope:
                group = self.bound_scope['control_group']
                for info in unseen:
                    try:
                        if '0::' + group in self.io.membership(info.key.pid):
                            lease.enrolled_keys.add(info.key); self.enrolled_prockeys.add(info.key)
                    except OSError:
                        self.birth_errors += 1; self.gap('group member identity unavailable')
                if not known and not any('0::' + group in self.io.membership(p.key.pid) for p in unseen):
                    lease.closed = True
            elif known:
                for info in unseen:
                    lease.enrolled_keys.add(info.key); self.enrolled_prockeys.add(info.key)
            elif unseen:
                self.ownership_ambiguous = True; self.gap('discontinuous unscoped PGID occupancy')
            else:
                lease.closed = True

    def terminal_unloaded(self):
        try:
            show = self.io.show(self.bound_scope['unit'])
            invocation = self.bound_scope['invocation_id']
            clean_loaded = (show.get('LoadState') == 'loaded' and show.get('ActiveState') == 'inactive'
                            and show.get('Result') == 'success' and show.get('InvocationID') == invocation)
            records = self.io.journal(self.bound_scope['unit'], invocation) if show.get('LoadState') == 'not-found' else []
            clean_unloaded = show.get('LoadState') == 'not-found' and validate_user_scope_journal_completion(
                records, self.bound_scope['unit'], invocation, self.uid)
            if not (clean_loaded or clean_unloaded):
                self.lose('scope terminal receipt missing, failed, or has surviving identities'); return
            current = live_processes(self.io.procs())
            self.live_survivors = sorted(key.text() for key in self.enrolled_prockeys if key in current)
            if self.live_survivors:
                self.lose('scope terminal receipt missing, failed, or has surviving identities'); return current
            self.final_scope_counters = None
            self.final_scope_counters_status = 'unavailable_unloaded'
            self.terminal_completion_receipt = dict(show=show, journal_records=records)
            self.scope_state = ScopeState.COMPLETED
            return current
        except (OSError, ValueError, subprocess.SubprocessError):
            self.lose('scope terminal evidence unavailable')

    def tick(self, now=None):
        now = time.time() if now is None else now
        self.seq += 1
        if self.last_tick is not None and now - self.last_tick > 1.5:
            self.gap('sampling interval exceeded 1.5 seconds')
        self.last_tick = now
        if self.scope_state == ScopeState.UNESTABLISHED:
            self.bind()
        try:
            current = live_processes(self.io.procs())
        except (OSError, ValueError):
            self.lose('process identity scan unavailable'); return self.report([])
        if self.scope_state == ScopeState.ACTIVE:
            group = self.bound_scope['control_group']
            try:
                pids = self.io.group_pids(group)
                if not pids:
                    try:
                        current = live_processes(self.io.procs())
                    except (OSError, ValueError):
                        self.lose('terminal process identity scan unavailable'); return self.report([])
                for pid in pids:
                    try:
                        info = self.io.proc(pid)
                        if '0::' + group not in self.io.membership(pid):
                            self.birth_errors += 1; self.gap('cgroup membership changed during enrollment'); continue
                        self.enrolled_prockeys.add(info.key)
                    except (OSError, ValueError):
                        self.birth_errors += 1; self.gap('cgroup process birth unavailable')
                try:
                    counters = dict(seq=self.seq, ts=now, **self.io.counters(group))
                    self.last_retained_scope_counters = counters
                    if self.first_scope_counters is None:
                        self.first_scope_counters = counters
                except (OSError, ValueError):
                    counters = None; self.gap('scope counters unavailable')
                self.live_survivors = sorted(key.text() for key in self.enrolled_prockeys if key in current)
                if not pids:
                    if self.live_survivors:
                        self.lose('enrolled identities survived outside empty scope')
                    else:
                        self.final_scope_counters = counters
                        self.final_scope_counters_status = 'read_at_completion' if counters else 'unavailable_readable'
                        self.scope_state = ScopeState.COMPLETED
            except FileNotFoundError:
                current = self.terminal_unloaded()
                if current is None:
                    return self.report([])
            except (OSError, ValueError):
                self.lose('scope membership unavailable')
        elif self.bound_scope is None:
            descendants = set(self.root_keys)
            changed = True
            while changed:
                changed = False
                parent_pids = {key.pid for key in descendants if key in current}
                for key, info in current.items():
                    if info.ppid in parent_pids and key not in descendants:
                        descendants.add(key); changed = True
            self.enrolled_prockeys.update(descendants)
        try:
            self.enroll_leases(current)
        except OSError:
            self.birth_errors += 1; self.gap('group continuity unavailable')
        if self.environmental_reference_cgroup:
            try:
                self.env_last = self.io.counters(self.environmental_reference_cgroup)
                if self.env_first is None:
                    self.env_first = self.env_last
            except (OSError, ValueError):
                self.gap('environmental reference counters unavailable')
        samples = []
        for key in sorted(self.enrolled_prockeys):
            if key not in current:
                continue
            try:
                memory = self.io.memory(key.pid)
                if self.io.proc(key.pid).key != key:
                    self.gap('PID changed during memory sample'); continue
                if memory['composite_memory_charge_bytes'] is None:
                    self.gap('process memory charge unavailable')
                bucket = 'root' if key in self.root_keys else 'extension' if any(key in lease.enrolled_keys for lease in self.leases.values()) else 'native_scoped' if self.bound_scope else 'native_sampled_ppid'
                samples.append(dict(prockey=key.text(), bucket=bucket, name=current[key].name, **memory))
            except (OSError, ValueError):
                self.gap('process memory sample unavailable')
        self.live_survivors = sorted(key.text() for key in self.enrolled_prockeys if key in current)
        return self.report(samples)

    @staticmethod
    def oom_delta(first, last):
        if first is None or last is None:
            return None
        return {key: last['memory_events'][key] - value for key, value in first['memory_events'].items()
                if key.startswith('oom') and key in last['memory_events']}

    def report(self, samples):
        return dict(seq=self.seq, scope_state=self.scope_state.value, bound_scope=self.bound_scope,
                    full_tree_coverage_complete=self.full_tree_coverage_complete,
                    native_family_coverage='bound_cgroup' if self.bound_scope else 'sampled_ppid_only',
                    ownership_ambiguous=self.ownership_ambiguous, birth_errors=self.birth_errors,
                    enrolled_prockeys=sorted(key.text() for key in self.enrolled_prockeys),
                    live_survivors=self.live_survivors, samples=samples, sampling_gaps=self.sampling_gaps,
                    last_retained_scope_counters=self.last_retained_scope_counters,
                    final_scope_counters=self.final_scope_counters, final_scope_counters_status=self.final_scope_counters_status,
                    terminal_completion_receipt=self.terminal_completion_receipt,
                    scope_retained_oom_delta=self.oom_delta(self.first_scope_counters, self.last_retained_scope_counters),
                    environmental_reference_cgroup=self.environmental_reference_cgroup,
                    env_ref_oom_delta=self.oom_delta(self.env_first, self.env_last),
                    failed_lifecycle_records=self.failed_lifecycle_records, gateway_dollar_cost='unknown')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--events-file', type=Path, required=True)
    parser.add_argument('--scope-unit')
    parser.add_argument('--scope-cgroup')
    parser.add_argument('--env-ref-cgroup')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--duration', type=float, default=30)
    args = parser.parse_args()
    if args.duration <= 0:
        parser.error('--duration must be positive')
    sampler = ScopeSampler(LinuxIO(), args.scope_unit, args.scope_cgroup, args.env_ref_cgroup)
    deadline = time.monotonic() + args.duration
    with args.output.open('w') as stream:
        os.chmod(args.output, 0o600)
        while True:
            sampler.read_events(args.events_file)
            json.dump(sampler.tick(), stream); stream.write('\n'); stream.flush()
            if sampler.scope_state in (ScopeState.COMPLETED, ScopeState.LOST) or time.monotonic() >= deadline:
                break
            time.sleep(min(1, max(0, deadline - time.monotonic())))


if __name__ == '__main__':
    main()
