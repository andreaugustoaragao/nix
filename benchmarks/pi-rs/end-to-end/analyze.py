#!/usr/bin/env python3
"""Derive descriptive paired results and audit fixture integrity from events."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import random
import statistics
import subprocess

import run


def tracked_digest(root: Path) -> str:
    names = subprocess.check_output([run.GIT, '-C', str(root), 'ls-files', '-z']).split(b'\0')
    h = hashlib.sha256()
    for name in sorted(n for n in names if n):
        h.update(name + b'\0')
        h.update((root / name.decode()).read_bytes() + b'\0')
    return h.hexdigest()


def total(rows: list[dict], key: str):
    if key in ('input_tokens', 'cached_input_tokens', 'output_tokens',
               'cache_write_input_tokens', 'reasoning_output_tokens'):
        return sum(r['usage'].get(key, 0) for r in rows)
    if key == 'uncached_input_tokens':
        return sum(r['usage']['input_tokens'] - r['usage']['cached_input_tokens'] for r in rows)
    return sum(r[key] for r in rows)


def reduction(stock: float, pi: float) -> float:
    return (stock - pi) / stock * 100 if stock else 0.0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('tag', nargs='?', default='verified')
    opts = parser.parse_args()
    directory = Path(__file__).resolve().parent / opts.tag
    manifest = json.loads((directory / 'manifest.json').read_text())
    if not manifest.get('finished_utc'):
        raise SystemExit('The entire planned matrix must complete before main analysis.')
    rows = manifest['results']
    if len(rows) != manifest['repeats'] * 2 * len(json.loads((directory / 'tasks.json').read_text())):
        raise SystemExit('Missing planned observations.')
    temp = Path(manifest['working_root'])
    integrity_path = directory / 'integrity.json'
    if not temp.exists() and not integrity_path.exists():
        raise SystemExit('Temporary fixtures or a previously captured integrity audit are required.')
    integrity = json.loads(integrity_path.read_text()) if not temp.exists() else {}
    for r in rows:
        template = temp / 'templates' / r['task']
        fixture = temp / 'runs' / r['run_id'] / 'fixture'
        executed_test = r['task'] != 'cargo_failure' or any('cargo test' in c for c in r['commands'])
        if temp.exists():
            reference, observed = tracked_digest(template), tracked_digest(fixture)
            untracked = subprocess.check_output([run.GIT, '-C', str(fixture), 'ls-files',
                                                '--others', '--exclude-standard'], text=True).splitlines()
            unexpected = [p for p in untracked if not (r['task'] == 'cargo_failure' and p == 'Cargo.lock')]
            integrity[r['run_id']] = {'template_sha256': reference, 'after_sha256': observed,
                                     'tracked_files_unchanged': reference == observed,
                                     'unexpected_untracked_files': unexpected,
                                     'required_test_command_executed': executed_test}
        record = integrity[r['run_id']]
        # Exact answer, actual required test execution, and no source edits are separate gates.
        r['task_success'] = bool(r['correct'] and record['tracked_files_unchanged']
                                 and not record['unexpected_untracked_files'] and executed_test)
    run.save_json(directory / 'integrity.json', integrity)
    keys = ['input_tokens', 'cached_input_tokens', 'uncached_input_tokens',
            'cache_write_input_tokens', 'output_tokens', 'reasoning_output_tokens',
            'seconds', 'command_count', 'command_output_bytes', 'pi_command_count',
            'recovery_command_count']
    by_arm = {arm: [r for r in rows if r['arm'] == arm] for arm in ('stock', 'pi')}
    totals = {arm: {key: total(arm_rows, key) for key in keys}
              for arm, arm_rows in by_arm.items()}
    for arm, arm_rows in by_arm.items():
        totals[arm].update(sessions=len(arm_rows), successes=sum(r['task_success'] for r in arm_rows),
                           median_seconds=statistics.median(r['seconds'] for r in arm_rows))
    tasks = list(dict.fromkeys(r['task'] for r in rows))
    per_task = []
    pairs = []
    for task in tasks:
        tr = {a: [r for r in v if r['task'] == task] for a, v in by_arm.items()}
        result = {'task': task}
        for arm, arm_rows in tr.items():
            result[arm] = {k: total(arm_rows, k) for k in keys}
            result[arm]['successes'] = sum(r['task_success'] for r in arm_rows)
        result['input_reduction_percent'] = reduction(result['stock']['input_tokens'], result['pi']['input_tokens'])
        result['uncached_input_reduction_percent'] = reduction(result['stock']['uncached_input_tokens'], result['pi']['uncached_input_tokens'])
        result['elapsed_reduction_percent'] = reduction(result['stock']['seconds'], result['pi']['seconds'])
        per_task.append(result)
        for rep in range(1, manifest['repeats'] + 1):
            s = next(r for r in tr['stock'] if r['repeat'] == rep)
            p = next(r for r in tr['pi'] if r['repeat'] == rep)
            pairs.append({'task': task, 'repeat': rep,
                          'stock_input_tokens': s['usage']['input_tokens'],
                          'pi_input_tokens': p['usage']['input_tokens'],
                          'input_reduction_percent': reduction(s['usage']['input_tokens'], p['usage']['input_tokens']),
                          'stock_seconds': s['seconds'], 'pi_seconds': p['seconds']})
    rng = random.Random(6137)
    boot = []
    for _ in range(20000):
        sampled = []
        for task in tasks:
            candidates = [p for p in pairs if p['task'] == task]
            sampled.extend(rng.choices(candidates, k=len(candidates)))
        boot.append(reduction(sum(p['stock_input_tokens'] for p in sampled),
                              sum(p['pi_input_tokens'] for p in sampled)))
    boot.sort()
    summary = {'source': str(directory.relative_to(run.REPO) / 'manifest.json'),
               'totals': totals, 'per_task': per_task, 'pairs': pairs,
               'input_reduction_percent': reduction(totals['stock']['input_tokens'], totals['pi']['input_tokens']),
               'uncached_input_reduction_percent': reduction(totals['stock']['uncached_input_tokens'], totals['pi']['uncached_input_tokens']),
               'output_reduction_percent': reduction(totals['stock']['output_tokens'], totals['pi']['output_tokens']),
               'elapsed_reduction_percent': reduction(totals['stock']['seconds'], totals['pi']['seconds']),
               'input_savings_pairs': sum(p['pi_input_tokens'] < p['stock_input_tokens'] for p in pairs),
               'total_pairs': len(pairs),
               'descriptive_bootstrap_95_percent': [boot[499], boot[19499]],
               'bootstrap_scope': '20,000 resamples of paired repeats within each of the five fixed tasks; descriptive sampling variability, not generalization to other workloads.',
               'all_tracked_files_unchanged': all(x['tracked_files_unchanged'] for x in integrity.values()),
               'notes': ['Input usage is the provider-reported cumulative sum across model requests, including cached tokens.',
                         'Uncached = input - cached_input; cache-write input is reported separately and may carry provider-specific billing.',
                         'Command output bytes are the completed CLI event payloads after path/URL sanitization, not tokenizer counts or guaranteed exact model-visible output.',
                         'Reasoning output may be included in output_tokens; it is never added again.',
                         'Whole-task input differences include command selection, batching, instruction overhead, and recovery.']}
    run.save_json(directory / 'summary.json', summary)
    lines = ['# Verified isolated Codex A/B results', '',
             f"{len(rows)} sessions; requested model `{manifest['configuration']['model']}`, reasoning `{manifest['configuration']['model_reasoning_effort']}`.", '',
             '| Metric (15 sessions per arm) | Stock | pi-rs |',
             '|---|---:|---:|']
    for key in ['successes', 'input_tokens', 'cached_input_tokens', 'uncached_input_tokens',
                'output_tokens', 'seconds', 'command_count', 'command_output_bytes',
                'pi_command_count', 'recovery_command_count']:
        vals = [totals[a][key] for a in ('stock', 'pi')]
        cells = [f'{v:,.1f}' if isinstance(v, float) else f'{v:,}' for v in vals]
        lines.append(f"| {key} | {cells[0]} | {cells[1]} |")
    lines += ['', '| Task | Stock input | pi-rs input | Input reduction | Uncached reduction |',
              '|---|---:|---:|---:|---:|']
    for r in per_task:
        lines.append(f"| {r['task']} | {r['stock']['input_tokens']:,} | {r['pi']['input_tokens']:,} | {r['input_reduction_percent']:.1f}% | {r['uncached_input_reduction_percent']:.1f}% |")
    lines += ['', f"Overall input reduction: {summary['input_reduction_percent']:.2f}%. "
              f"Uncached input reduction: {summary['uncached_input_reduction_percent']:.2f}%. "
              f"Input savings in {summary['input_savings_pairs']}/{len(pairs)} pairs.", '',
              f"Descriptive paired bootstrap interval: [{boot[499]:.2f}%, {boot[19499]:.2f}%]. "
              'This measures variability of repeated sessions on these fixed fixtures; it does not establish a population-wide benefit.', '',
              'See ../README.md for isolation, protocol exclusions, source limitations, and reproduction.', '']
    run.write(directory / 'results.md', '\n'.join(lines), stage=True)
    print(json.dumps({k: v for k, v in summary.items() if k not in ('pairs', 'per_task', 'notes')}, indent=2))


if __name__ == '__main__':
    main()
