#!/usr/bin/env python3
"""Alternate existing disposable benchmark VMs; retain raw evidence per run."""
import argparse
import json
import shlex
import subprocess
import time
from pathlib import Path

VMX = '/Users/aragao/Virtual Machines.localized/Hypervisor Benchmark Fusion.vmwarevm/Hypervisor Benchmark Fusion.vmx'
VMRUN = '/Applications/VMware Fusion.app/Contents/Library/vmrun'
PARALLELS = 'Hypervisor Benchmark Parallels'


def run(argv, timeout=900):
    p = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError(f'{argv[:2]}: {p.returncode}\n{p.stdout[-1500:]}\n{p.stderr[-3000:]}')
    return p.stdout


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ssh-config', required=True)
    p.add_argument('--mac-ssh', required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--rounds', type=int, default=5)
    p.add_argument('--first-trial', type=int, default=1)
    p.add_argument('--resume-results', action='store_true', help='Skip complete VM rounds already saved')
    p.add_argument('--suite', choices=['apps','storage'], default='apps')
    p.add_argument('--include-go', action='store_true', help='Repeat Go builds after each storage round')
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    def mac(argv):
        return run([args.mac_ssh, shlex.join(argv)])
    def guest(side, argv):
        return run(['ssh', '-F', args.ssh_config, 'vmperf-' + side, shlex.join(argv)])
    def suspend(side):
        return mac(['/usr/local/bin/prlctl', 'suspend', PARALLELS] if side == 'parallels' else [VMRUN, 'suspend', VMX, 'hard'])
    def resume(side):
        argv = ['/usr/local/bin/prlctl', 'resume', PARALLELS] if side == 'parallels' else [VMRUN, 'start', VMX, 'nogui']
        # Fusion can leave a helper holding SSH's pipes after vmrun exits.
        # Redirect all inherited descriptors while preserving its exit code.
        return run([args.mac_ssh, shlex.join(argv) + ' </dev/null >/tmp/vmperf-resume.log 2>&1'])
    def host():
        return {key:mac(argv) for key,argv in {
            'uptime':['/usr/bin/uptime'],
            'power':['/usr/bin/pmset','-g','batt'],
            'thermal':['/usr/bin/pmset','-g','therm'],
            'vm_processes':['/bin/sh','-c',"ps -axo pid,time,rss,pcpu,comm | awk '/prl_vm_app|vmware-vmx/ {print}'"]
        }.items()}
    def save(name,value):
        path=args.output/name
        path.write_text(json.dumps(value,indent=2)+'\n')
    # Preconditions: both named disposable VMs running and all pilots complete.
    suspend('fusion')
    active='parallels'
    try:
        for trial in range(args.first_trial,args.first_trial+args.rounds):
            for side in ['parallels','fusion']:
                kinds = ['ghostty','herdr','kero','go'] if args.suite == 'apps' else ['storage']
                if args.suite == 'storage' and args.include_go:
                    kinds.append('go')
                complete = all((args.output/f'{side}-{trial}-{kind}.json').exists() for kind in kinds + ['host-before','host-after'])
                if args.resume_results and complete:
                    print(f'{side} trial {trial}: reusing complete round',flush=True)
                    continue
                if active != side:
                    suspend(active)
                    active=None
                    resume(side)
                    active=side
                time.sleep(5)
                save(f'{side}-{trial}-host-before.json',host())
                if args.suite == 'storage':
                    name=f'{side}-{trial}-storage.json'
                    if (args.output/name).exists():
                        raise RuntimeError(f'Refusing to overwrite {name}')
                    value=json.loads(guest(side,['python3','/opt/vmperf/storage.py','run','--trial',str(trial)]))
                    save(name,value)
                    if value['errors'] or len(value['cases'])!=7:
                        raise RuntimeError(f'Invalid storage result: {name}')
                    if args.include_go:
                        save(f'{side}-{trial}-go.json',json.loads(guest(side,['python3','/opt/vmperf/guest.py','go','--trial',str(trial)])))
                    save(f'{side}-{trial}-host-after.json',host())
                    print(f'{side} trial {trial}: storage completed',flush=True)
                    continue
                apps=['ghostty','herdr','kero']
                offset=(trial-args.first_trial)%len(apps)
                apps=apps[offset:]+apps[:offset]
                for app in apps:
                    name=f'{side}-{trial}-{app}.json'
                    if (args.output/name).exists():
                        raise RuntimeError(f'Refusing to overwrite {name}')
                    value=json.loads(guest(side,['python3','/opt/vmperf/guest.py','app','--app',app,'--trial',str(trial)]))
                    if value['errors'] or len(value['phases'])!=3:
                        raise RuntimeError(f'Invalid app result: {name}')
                    save(name,value)
                    print(f'{side} trial {trial}: {app} completed',flush=True)
                value=json.loads(guest(side,['python3','/opt/vmperf/guest.py','go','--trial',str(trial)]))
                save(f'{side}-{trial}-go.json',value)
                save(f'{side}-{trial}-host-after.json',host())
                print(f'{side} trial {trial}: Go completed',flush=True)
    finally:
        if active:
            suspend(active)
    print('Both benchmark VMs suspended.',flush=True)

if __name__=='__main__':
    main()
