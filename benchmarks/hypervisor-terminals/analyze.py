#!/usr/bin/env python3
"""Validate completed work, then summarize paired VM measurements."""
import argparse
import json
import statistics
from pathlib import Path


def stats(values):
    return {'median':statistics.median(values),'min':min(values),'max':max(values),'samples':values,'n':len(values)}


def analyze(root):
    records={side:{'apps':{},'go':{}} for side in ['parallels','fusion']}
    trials={}
    for side in records:
        trials[side]=sorted(int(p.name.split('-')[1]) for p in root.glob(side+'-*-go.json'))
    if not trials['parallels'] or trials['parallels']!=trials['fusion']:
        raise ValueError(f'Paired rounds are incomplete: {trials}')
    total_errors=0
    for side in records:
        for app in ['ghostty','herdr','kero']:
            metrics={k:[] for k in ['startup_seconds','idle_cpu_seconds','paced_cpu_seconds','paced_pss_mib','bulk_seconds','paced_ack_p95_ms','generator_cpu_seconds']}
            modes=set();sizes=set()
            for trial in trials[side]:
                value=json.loads((root/f'{side}-{trial}-{app}.json').read_text())
                total_errors+=len(value['errors'])
                if value['pilot']:
                    raise ValueError('Pilot in measured data')
                phases={p['mode']:p for p in value['phases']}
                assert set(phases)=={'idle','bulk','paced'}
                for mode,units in [('idle',0),('bulk',100000),('paced',480)]:
                    phase=phases[mode]
                    assert phase['error'] is None and phase['work_units']==units
                    assert len(phase['ack_seconds'])==(480 if mode=='paced' else 0)
                    assert bool(phase['gpu_fds'])==(value['render_mode']=='native-gpu')
                    sizes.add(tuple(phase['terminal_size']))
                assert phases['bulk']['bytes']>9_000_000
                assert phases['paced']['cursor_reply']==[24,1]
                modes.add(value['render_mode'])
                metrics['startup_seconds'].append(statistics.median(p['startup_seconds'] for p in phases.values()))
                metrics['idle_cpu_seconds'].append(phases['idle']['cpu_seconds'])
                metrics['paced_cpu_seconds'].append(phases['paced']['cpu_seconds'])
                metrics['paced_pss_mib'].append(phases['paced']['end_summed_pss_mib'])
                metrics['bulk_seconds'].append(phases['bulk']['seconds'])
                ack=sorted(phases['paced']['ack_seconds'])
                metrics['paced_ack_p95_ms'].append(ack[int(.95*(len(ack)-1))]*1000)
                metrics['generator_cpu_seconds'].append(phases['paced']['generator_cpu_seconds'])
            records[side]['apps'][app]={'render_modes':sorted(modes),'terminal_sizes':sorted(sizes),'metrics':{k:stats(v) for k,v in metrics.items()}}
        for phase in ['clean','incremental']:
            metrics={k:[] for k in ['seconds','user_seconds','system_seconds','peak_summed_rss_mib']}
            for trial in trials[side]:
                value=json.loads((root/f'{side}-{trial}-go.json').read_text())
                total_errors+=len(value['errors']) if phase=='clean' else 0
                assert not value['profile']
                p=next(p for p in value['phases'] if p['phase']==phase)
                assert p['exit_code']==0 and p['stamp']==f'trial-{trial}-{phase}' and '_go_.o' in p['object_members']
                for key in metrics:
                    metrics[key].append(p['resources'][key] if key=='peak_summed_rss_mib' else p[key])
            records[side]['go'][phase]={k:stats(v) for k,v in metrics.items()}
    # The core can acknowledge its child before the GUI sends a resize.
    # ready.json records that initial PTY size, not final window geometry.
    # Every workload draws the same 80x24 grid and must fit every initial PTY.
    for side in records:
        for app in records[side]['apps'].values():
            assert all(cols>=80 and rows>=24 for cols,rows in app['terminal_sizes'])
    return {'trials':trials['parallels'],'errors':total_errors,'app_trials':len(trials['parallels'])*6,'app_phases':len(trials['parallels'])*18,'go_builds':len(trials['parallels'])*4,'geometry_note':'PTY sizes are captured at child readiness and can precede GUI resize. All grids are 80x24; validate final pixel geometry with screenshots.','records':records}


def analyze_storage(root):
    trials={side:sorted(int(p.name.split('-')[1]) for p in root.glob(side+'-*-storage.json')) for side in ['parallels','fusion']}
    assert trials['parallels'] and trials['parallels']==trials['fusion']
    records={side:{} for side in trials}
    total_errors=0
    for side in trials:
        for trial in trials[side]:
            value=json.loads((root/f'{side}-{trial}-storage.json').read_text())
            total_errors+=len(value['errors'])
            assert len(value['cases'])==7
            integrity=value['integrity']['fio']['jobs'][0]
            assert integrity['error']==0 and integrity['read']['io_bytes']==64*1024**2
            for case in value['cases']:
                name=case['name'];job=case['fio']['jobs'][0]
                direction='read' if 'read' in name else 'write';io=job[direction]
                assert job['error']==0 and io['io_bytes']>0 and io['total_ios']>0
                metrics=records[side].setdefault(name,{k:[] for k in ['mib_per_second','iops','completion_p99_ms','fio_cpu_percent','sync_p99_ms','io_bytes','observed_qd16_percent']})
                metrics['mib_per_second'].append(io['bw_bytes']/1024**2)
                metrics['iops'].append(io['iops'])
                metrics['completion_p99_ms'].append(io['clat_ns']['percentile']['99.000000']/1e6)
                metrics['fio_cpu_percent'].append(job['usr_cpu']+job['sys_cpu'])
                metrics['io_bytes'].append(io['io_bytes'])
                metrics['observed_qd16_percent'].append(job['iodepth_level']['16'])
                metrics['sync_p99_ms'].append(job.get('sync',{}).get('lat_ns',{}).get('percentile',{}).get('99.000000',0)/1e6)
        records[side]={name:{key:stats(values) for key,values in metrics.items()} for name,metrics in records[side].items()}
    go_records={}
    if any(root.glob('*-go.json')):
        for side in trials:
            go_records[side]={}
            runs=[json.loads((root/f'{side}-{trial}-go.json').read_text()) for trial in trials[side]]
            for value,trial in zip(runs,trials[side]):
                assert not value['errors'] and not value['profile']
                for phase in value['phases']:
                    assert phase['exit_code']==0 and phase['stamp']==f"trial-{trial}-{phase['phase']}" and '_go_.o' in phase['object_members']
            for phase in ['clean','incremental']:
                values=[next(p for p in value['phases'] if p['phase']==phase) for value in runs]
                go_records[side][phase]={key:stats([p[key] for p in values]) for key in ['seconds','user_seconds','system_seconds']}
    return {'trials':trials['parallels'],'errors':total_errors,'storage_cases':len(trials['parallels'])*14,'integrity_checks':len(trials['parallels'])*2,'records':records,'go_records':go_records}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',type=Path)
    p.add_argument('--storage',action='store_true')
    a=p.parse_args()
    print(json.dumps(analyze_storage(a.directory) if a.storage else analyze(a.directory),indent=2))

if __name__=='__main__':
    main()
