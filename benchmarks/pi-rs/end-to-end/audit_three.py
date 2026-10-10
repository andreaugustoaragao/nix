#!/usr/bin/env python3
"""Check initial instruction separation for the official three integration bundles."""

import argparse
import json
from pathlib import Path
import subprocess

import run
import run_three


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('tag', nargs='?', default='three-way')
    opts = parser.parse_args()
    out = run.HERE / opts.tag
    manifest = json.loads((out / 'manifest.json').read_text())
    root = Path(manifest['working_root'])
    config, public = run_three.config()
    path_override = manifest['configuration'].get('shell_environment_policy.set.PATH')
    if path_override:
        public['shell_environment_policy.set.PATH'] = path_override
        config += ['-c', 'shell_environment_policy.set.PATH=' + run.toml_literal(path_override)]
    if public != manifest['configuration']:
        raise SystemExit('Measured non-model configuration has changed.')
    prompt = json.loads((out / 'tasks.json').read_text())['source_lookup']['prompt']
    pi_guidance = (out / 'pi-guidance.md').read_text().strip()
    pi_binary = Path(manifest['pi_binary'])
    toolchain_bin = Path(manifest['toolchain_bin']) if manifest.get('toolchain_bin') else None
    results = {}
    for arm in run_three.ARMS:
        session = root / 'runs' / f'source_lookup-1-{arm}'
        cmd = run_three.mounts(session) + [str(run.CLI), '-C', str(session / 'fixture'),
              '-a', 'never', '-s', 'workspace-write', '--add-dir', str(run_three.SHARE_DIRECTORY), *config]
        if arm == 'rtk':
            cmd += ['--dangerously-bypass-hook-trust', '-c', 'features.hooks=true']
        cmd += ['debug', 'prompt-input', prompt]
        result = subprocess.run(cmd, text=True, capture_output=True, env=run_three.environment(pi_binary, toolchain_bin), timeout=90)
        text = run.sanitize(result.stdout, root)
        run.write(out / f'prompt-audit-{arm}.json', text, stage=True)
        messages = json.loads(result.stdout)
        instruction_text = '\n'.join(c.get('text', '') for m in messages for c in m.get('content', []))
        results[arm] = {'exit_code': result.returncode,
                        'pi_guidance_copies': instruction_text.count(pi_guidance),
                        'rtk_reference_copies': text.count('@/home/aragao/.codex/RTK.md'),
                        'rtk_awareness_automatically_inlined': '# Command output' in text,
                        'skills_catalog_present': 'Available skills' in text}
    results['scope'] = ('Debug prompt-input verifies instruction loading with matching mounts/settings. '
                         'It is not the full executed API request. RTK default awareness is supplied through '
                         'the official AGENTS reference; actual model reads and hook rewrites are audited '
                         'separately in command events, hook-audit logs and RTK SQLite history.')
    run.save_json(out / 'prompt-audit.json', results)
    for arm in run_three.ARMS:
        r = results[arm]
        if (r['exit_code'] or r['skills_catalog_present'] or r['pi_guidance_copies'] != (arm == 'pi')
                or r['rtk_reference_copies'] != (arm == 'rtk')):
            raise SystemExit('Instruction-isolation failure: ' + arm)
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
