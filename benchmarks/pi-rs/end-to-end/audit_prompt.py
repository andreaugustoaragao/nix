#!/usr/bin/env python3
"""Audit global instruction loading in the same isolated mount namespaces."""

import argparse
import json
import os
from pathlib import Path
import subprocess

import run


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('tag', nargs='?', default='verified')
    opts = parser.parse_args()
    out = Path(__file__).resolve().parent / opts.tag
    manifest = json.loads((out / 'manifest.json').read_text())
    root = Path(manifest['working_root'])
    config, public = run.cli_config()
    # The user's active model can change while the batch is running. The measured
    # batch freezes its CLI arguments once; repeat that snapshot for this audit.
    for key in ('model', 'model_reasoning_effort'):
        public[key] = manifest['configuration'][key]
        config += ['-c', key + '=' + run.toml_literal(public[key])]
    if public != manifest['configuration']:
        raise SystemExit('Current non-model config differs from the measured configuration.')
    prompt = json.loads((out / 'tasks.json').read_text())['source_lookup']['prompt']
    report = {}
    for arm in ('stock', 'pi'):
        session = root / 'runs' / f'source_lookup-1-{arm}'
        if not session.exists():
            raise SystemExit('The source_lookup first pair must exist for this audit.')
        cmd = ['bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--bind', '/tmp', '/tmp',
               '--proc', '/proc', '--dev-bind', '/dev', '/dev',
               '--bind', str(session / 'codex-state'), str(run.CODEX_DIRECTORY),
               '--bind', str(session / 'pi-state'), str(run.PI_DIRECTORY), '--', str(run.CLI),
               '-C', str(session / 'fixture'), '-a', 'never', '-s', 'workspace-write',
               '--add-dir', str(run.PI_DIRECTORY), *config, 'debug', 'prompt-input', prompt]
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('CODEX_', 'NOISE_', 'OPENAI_')) or k == 'CODEX_HOME'}
        env['RUST_LOG'] = 'error'
        proc = subprocess.run(cmd, text=True, capture_output=True, env=env, timeout=90)
        text = run.sanitize(proc.stdout, root)
        run.write(out / f'prompt-audit-{arm}.json', text, stage=True)
        report[arm] = {'exit_code': proc.returncode,
                       'global_pi_guidance_present': '# pi-rs token compression' in text,
                       'skills_catalog_present': 'Available skills' in text,
                       'pi_guidance_occurrences': text.count('# pi-rs token compression')}
    report['scope'] = ('Codex debug prompt-input under the same mount namespace, explicit '
                       'model/settings, approval mode and fixture; verifies instruction loading, '
                       'not the API request body or execution-tool arguments. debug does not '
                       'support exec --ignore-rules or output-schema flags.')
    run.save_json(out / 'prompt-audit.json', report)
    if (report['stock']['global_pi_guidance_present'] or
            report['pi']['pi_guidance_occurrences'] != 1 or
            any(report[a]['skills_catalog_present'] or report[a]['exit_code'] for a in ('stock', 'pi'))):
        raise SystemExit('Instruction isolation audit failed.')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
