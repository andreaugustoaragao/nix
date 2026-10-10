#!/usr/bin/env python3
"""Audit all three-arm observations and derive paired descriptive comparisons."""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import shlex
import statistics
import subprocess

import analyze
import run
import run_three


def decode_audit_field(value):
    result = []
    i = 0
    escapes = {'\\': '\\', '|': '|', 'n': '\n', 'r': '\r'}
    while i < len(value):
        if value[i] == '\\' and i + 1 < len(value) and value[i + 1] in escapes:
            result.append(escapes[value[i + 1]])
            i += 2
        else:
            result.append(value[i])
            i += 1
    return ''.join(result)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('tag', nargs='?', default='three-way')
    opts = ap.parse_args()
    out = run.HERE / opts.tag
    manifest = json.loads((out / 'manifest.json').read_text())
    tasks = json.loads((out / 'tasks.json').read_text())
    rows = manifest['results']
    expected_count = len(tasks) * manifest['repeats'] * 3
    if not manifest.get('finished_utc') or len(rows) != expected_count:
        raise SystemExit('The planned three-arm matrix is incomplete.')
    temp = Path(manifest['working_root'])
    integrity_path = out / 'integrity.json'
    integrity = {} if temp.exists() else json.loads(integrity_path.read_text())
    hook_execution = {}
    session_isolation = {}
    expected_tools = None
    for row in rows:
        if manifest.get('pi_binary_sha256'):
            preflight = json.loads((out / 'session-preflight' / (row['run_id'] + '.json')).read_text())
            toolset = preflight['tools']
            if toolset['pi-rs']['sha256'] != manifest['pi_binary_sha256'] or toolset['pi-rs']['version'] != manifest['pi_version']:
                raise SystemExit('Wrong pi-rs binary in session: ' + row['run_id'])
            if toolset['rtk']['sha256'] != manifest['rtk_binary_sha256'] or toolset['rtk']['version'] != manifest['rtk_version']:
                raise SystemExit('Wrong RTK binary in session: ' + row['run_id'])
            if preflight['PATH'] != manifest['configuration']['shell_environment_policy.set.PATH']:
                raise SystemExit('Session PATH differs from the configured tool PATH: ' + row['run_id'])
            if expected_tools is None:
                expected_tools = toolset
            if toolset != expected_tools:
                raise SystemExit('Toolchain differs between sessions: ' + row['run_id'])
            guidance = preflight['guidance']
            if row['arm'] == 'pi' and (not guidance or guidance['sha256'] != manifest['guidance_sha256']):
                raise SystemExit('Wrong pi guidance in session: ' + row['run_id'])
            if row['arm'] == 'stock' and guidance is not None:
                raise SystemExit('Unexpected native-arm global guidance: ' + row['run_id'])
            expected_hooks = json.loads((out / 'rtk-installed/hooks.json').read_text()) if row['arm'] == 'rtk' else None
            if preflight['hooks'] != expected_hooks:
                raise SystemExit('Wrong hooks in session: ' + row['run_id'])
            if row['arm'] == 'rtk' and guidance['sha256'] != hashlib.sha256((out / 'rtk-installed/AGENTS.md').read_bytes()).hexdigest():
                raise SystemExit('Wrong RTK instruction reference: ' + row['run_id'])
            session_isolation[row['run_id']] = {'binary_hashes_verified': True,
                                                'toolchain_and_PATH_match': True,
                                                'guidance_and_hooks_match': True}
        transcript = (out / 'transcripts' / (row['run_id'] + '.jsonl')).read_text()
        evidence = json.loads((out / 'rtk-observation' / (row['run_id'] + '.json')).read_text())
        parsed = run_three.parse_result(transcript, row['task'], tasks[row['task']], row['arm'],
                                       row['repeat'], row['seconds'], row['exit_code'], row['timed_out'], evidence)
        for key in parsed:
            if parsed[key] != row[key]:
                raise SystemExit(f"Transcript/manifest mismatch: {row['run_id']} {key}")
        shell_commands = []
        for command in row['commands']:
            argv = shlex.split(command)
            shell_commands.append(argv[argv.index('-c') + 1] if '-c' in argv else command)
        available = Counter(shell_commands)
        matched, unmatched = [], []
        malformed = [d for d in evidence['hook_decisions']
                     if d['action'] != 'rewrite' and not d['action'].startswith('skip:')]
        for decision in evidence['hook_decisions']:
            if decision['action'] == 'rewrite':
                replacement = decode_audit_field(decision['rewritten'])
                if available[replacement]:
                    available[replacement] -= 1
                    matched.append(replacement)
                else:
                    unmatched.append(replacement)
        hook_execution[row['run_id']] = {'matched_rewrite_executions': len(matched),
                                          'matched_commands': matched,
                                          'unmatched_rewrites': unmatched,
                                          'malformed_hook_audit_records': malformed,
                                          'rtk_history_rows': row['rtk_history_count']}
        if unmatched:
            raise SystemExit('Hook rewrite has no matching executed command: ' + row['run_id'])
        fixture = temp / 'runs' / row['run_id'] / 'fixture'
        required_test = row['task'] != 'cargo_failure' or any('cargo test' in c for c in row['commands'])
        if temp.exists():
            original = analyze.tracked_digest(temp / 'templates' / row['task'])
            actual = analyze.tracked_digest(fixture)
            added = subprocess.check_output([run.GIT, '-C', str(fixture), 'ls-files',
                                             '--others', '--exclude-standard'], text=True).splitlines()
            unexpected = [p for p in added if not (row['task'] == 'cargo_failure' and p == 'Cargo.lock')]
            integrity[row['run_id']] = {'original_sha256': original, 'after_sha256': actual,
                                         'tracked_files_unchanged': original == actual,
                                         'unexpected_untracked_files': unexpected,
                                         'required_test_command_executed': required_test}
        record = integrity[row['run_id']]
        row['task_success'] = bool(row['correct'] and row['exit_code'] == 0 and row['usage']
                                   and required_test and record['tracked_files_unchanged']
                                   and not record['unexpected_untracked_files'])
        if row['arm'] != 'rtk' and (row['rtk_hook_rewrite_count'] or row['rtk_history_count']):
            raise SystemExit('RTK contamination detected in ' + row['run_id'])
        if row['arm'] == 'stock' and row['pi_command_count']:
            raise SystemExit('pi-rs contamination detected in ' + row['run_id'])
    run.save_json(integrity_path, integrity)
    run.save_json(out / 'hook-execution-audit.json', hook_execution)
    if session_isolation:
        run.save_json(out / 'session-isolation-audit.json', {'sessions': session_isolation,
                       'shared_tools': expected_tools, 'scope': 'Same-mount non-login shell preflight, plus explicitly configured identical tool PATH; probe is outside model usage.'})
    metrics = ['input_tokens', 'cached_input_tokens', 'uncached_input_tokens', 'cache_write_input_tokens',
               'output_tokens', 'reasoning_output_tokens', 'seconds', 'command_count', 'command_output_bytes',
               'pi_command_count', 'rtk_command_count', 'rtk_history_count', 'rtk_hook_rewrite_count',
               'rtk_hook_skip_count', 'recovery_command_count', 'agent_instruction_read_count']
    groups = {arm: [r for r in rows if r['arm'] == arm] for arm in run_three.ARMS}
    totals = {arm: {metric: analyze.total(rs, metric) for metric in metrics} for arm, rs in groups.items()}
    for arm, rs in groups.items():
        totals[arm].update(sessions=len(rs), successes=sum(r['task_success'] for r in rs),
                           median_seconds=statistics.median(r['seconds'] for r in rs),
                           task_failures=[r['run_id'] for r in rs if not r['task_success']],
                           error_items=sum(len(r['errors']) for r in rs),
                           hook_trust_notice_items=sum('--dangerously-bypass-hook-trust' in message
                                                       for r in rs for message in r['errors']),
                           other_error_items=sum('--dangerously-bypass-hook-trust' not in message
                                                  for r in rs for message in r['errors']),
                           malformed_hook_audit_records=sum(len(hook_execution[r['run_id']]['malformed_hook_audit_records'])
                                                            for r in rs))
    per_task = []
    for task in tasks:
        item = {'task': task}
        for arm, rs in groups.items():
            sub = [r for r in rs if r['task'] == task]
            item[arm] = {m: analyze.total(sub, m) for m in metrics}
            item[arm]['successes'] = sum(r['task_success'] for r in sub)
        per_task.append(item)
    comparisons = {}
    for baseline, treatment in [('stock', 'pi'), ('stock', 'rtk'), ('pi', 'rtk')]:
        key = treatment + '_vs_' + baseline
        pairs = []
        for task in tasks:
            for rep in range(1, manifest['repeats'] + 1):
                b = next(r for r in groups[baseline] if r['task'] == task and r['repeat'] == rep)
                t = next(r for r in groups[treatment] if r['task'] == task and r['repeat'] == rep)
                pairs.append({'task': task, 'repeat': rep, 'baseline_input': b['usage']['input_tokens'],
                              'treatment_input': t['usage']['input_tokens'],
                              'input_reduction_percent': analyze.reduction(b['usage']['input_tokens'], t['usage']['input_tokens'])})
        rng = random.Random(6148)
        boot = []
        for _ in range(20000):
            selected = []
            for task in tasks:
                candidates = [p for p in pairs if p['task'] == task]
                selected.extend(rng.choices(candidates, k=len(candidates)))
            boot.append(analyze.reduction(sum(p['baseline_input'] for p in selected),
                                          sum(p['treatment_input'] for p in selected)))
        boot.sort()
        comparisons[key] = {'baseline': baseline, 'treatment': treatment,
                            'reduction_percent': {m: analyze.reduction(totals[baseline][m], totals[treatment][m])
                                                  for m in ('input_tokens', 'uncached_input_tokens', 'output_tokens',
                                                            'seconds', 'command_output_bytes')},
                            'input_savings_pairs': sum(p['treatment_input'] < p['baseline_input'] for p in pairs),
                            'pairs': pairs, 'descriptive_bootstrap_95_percent': [boot[499], boot[19499]]}
    positions = {arm: {str(i): sum(r['position'] == i for r in rs) for i in (1, 2, 3)}
                 for arm, rs in groups.items()}
    summary = {'source': str(out.relative_to(run.REPO) / 'manifest.json'), 'totals': totals,
               'per_task': per_task, 'comparisons': comparisons, 'positions': positions,
               'observations': len(rows), 'all_transcripts_match_manifest': True,
               'all_tracked_files_unchanged': all(v['tracked_files_unchanged'] for v in integrity.values()),
               'all_intact_logged_hook_rewrites_match_executed_commands': True,
               'all_session_preflights_verified': len(session_isolation) == len(rows) if session_isolation else None,
               'hook_audit_scope': 'RTK audit writes can interleave under concurrent commands; parsed rewrite counts are lower bounds when malformed records exist. Completed command events and SQLite history remain separate execution evidence.',
               'bootstrap_scope': '20,000 paired resamples within each fixed task, descriptive only; not a production-workload confidence guarantee.',
               'usage_scope': 'Provider-reported cumulative input, including repeated cached context; uncached=input-cached. Command-output bytes are sanitized CLI event payloads, not exact model-visible token counts.',
               'integration_scope': 'RTK official hook plus default awareness-file reference; pi-rs selected inline guidance only; native clean baseline. Includes the cost of reading awareness files and differing model decisions.'}
    run.save_json(out / 'summary.json', summary)
    lines = ['# Fresh three-arm Codex comparison', '',
             f"{len(rows)} sessions on five fixed fixtures, requested `{manifest['configuration']['model']}` / `{manifest['configuration']['model_reasoning_effort']}`.", '',
             f"| Metric | Native | {manifest['pi_version']} | {manifest['rtk_version']} |", '|---|---:|---:|---:|']
    for metric in ['successes', 'input_tokens', 'cached_input_tokens', 'uncached_input_tokens',
                   'output_tokens', 'seconds', 'command_count', 'command_output_bytes',
                   'rtk_hook_rewrite_count', 'rtk_hook_skip_count', 'recovery_command_count',
                   'agent_instruction_read_count']:
        values = [totals[a][metric] for a in run_three.ARMS]
        vals = [f'{v:,.1f}' if isinstance(v, float) else f'{v:,}' for v in values]
        lines.append('| ' + metric + ' | ' + ' | '.join(vals) + ' |')
    lines += ['', '| Task | Native input | pi-rs input | RTK input | Correct native/pi/RTK |',
              '|---|---:|---:|---:|---|']
    for item in per_task:
        lines.append('| ' + item['task'] + ' | ' + ' | '.join(f"{item[a]['input_tokens']:,}" for a in run_three.ARMS)
                     + ' | ' + '/'.join(str(item[a]['successes']) for a in run_three.ARMS) + ' |')
    lines += ['', '| Comparison | Total-input reduction | Uncached-input reduction | Input-saving pairs |',
              '|---|---:|---:|---:|']
    for name, c in comparisons.items():
        lines.append(f"| {name} | {c['reduction_percent']['input_tokens']:.2f}% | {c['reduction_percent']['uncached_input_tokens']:.2f}% | {c['input_savings_pairs']}/15 |")
    lines += ['', 'Positive reduction means the named treatment used less. Timing is descriptive and includes provider latency. '
              'RTK hook rewrite counts include intact parsed audit records; concurrent audit-log corruption can make them lower bounds. '
              'See ../THREE_WAY.md for integration behavior, protocol details, and limitations.', '']
    run.write(out / 'results.md', '\n'.join(lines), stage=True)
    print(json.dumps({'totals': totals, 'comparisons': {k: {kk: vv for kk, vv in v.items() if kk != 'pairs'}
                                                       for k, v in comparisons.items()},
                      'positions': positions}, indent=2))


if __name__ == '__main__':
    main()
