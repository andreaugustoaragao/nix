#!/usr/bin/env python3
"""fio tests confined to the dedicated benchmark filesystem."""
import argparse
import json
import os
import subprocess
import time
from pathlib import Path

ROOT=Path('/bench/storage')


def command(argv):
    p=subprocess.run([str(a) for a in argv],text=True,capture_output=True,timeout=180)
    if p.returncode:
        raise RuntimeError(f'Command failed ({p.returncode}): {p.stdout[-2000:]} {p.stderr[-2000:]}')
    return p.stdout


def fio(binary,name,path,options):
    # Reuse a nonzero buffer. Scrambling every large write can saturate fio's
    # CPU before the virtual disk. This test measures fixed nonzero data.
    argv=[binary,'--output-format=json',f'--name={name}',f'--filename={path}','--numjobs=1','--direct=1','--group_reporting=1','--eta=never','--thread=1','--refill_buffers=0','--scramble_buffers=0','--buffer_pattern=0x7c38d149b2a506ef',*options]
    started=time.monotonic()
    value=json.loads(command(argv))
    if any(j['error'] for j in value['jobs']):
        raise RuntimeError(f'fio reported an I/O error: {value}')
    return {'wall_seconds':time.monotonic()-started,'argv':[str(a) for a in argv],'fio':value}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('action',choices=['prepare','run'])
    p.add_argument('--fio',default='/opt/vmperf/fio')
    p.add_argument('--trial',type=int,default=0)
    a=p.parse_args()
    if not os.path.ismount('/bench'):
        raise RuntimeError('/bench must be the mounted scratch disk')
    ROOT.mkdir(exist_ok=True)
    specs=[('sequential.dat','4g'),('random.dat','2g'),('sync.dat','64m')]
    if a.action=='prepare':
        values=[]
        for name,size in specs:
            values.append(fio(a.fio,'precondition',ROOT/name,['--rw=write','--bs=1m',f'--size={size}','--ioengine=libaio','--iodepth=16','--end_fsync=1']))
        meta={'fio_version':command([a.fio,'--version']).strip(),'filesystem':command(['findmnt','-J','/bench']),'block_devices':command(['lsblk','-b','-J','-o','NAME,SIZE,MODEL,FSTYPE,ROTA,LOG-SEC,PHY-SEC,SCHED,MOUNTPOINTS']),'write_cache':{str(x):x.read_text().strip() for x in Path('/sys/block').glob('*/queue/write_cache')},'precondition':values}
        (ROOT/'metadata.json').write_text(json.dumps(meta,indent=2))
        print(json.dumps({'prepared':True,'fio_version':meta['fio_version']}))
        return
    expected=[4*1024**3,2*1024**3,64*1024**2]
    if not all((ROOT/name).stat().st_size==size for (name,_),size in zip(specs,expected)):
        raise RuntimeError('Precondition all benchmark files before running')
    directory=ROOT/f'trial-{a.trial}';directory.mkdir(exist_ok=False)
    kernel_before=command(['dmesg','--level=err,warn']).splitlines()
    device=Path(command(['findmnt','-n','-o','SOURCE','/bench']).strip()).resolve().name
    block_stat_path=Path('/sys/class/block')/device/'stat'
    async_options=['--ioengine=libaio']
    # Four disjoint 1-GiB streams keep fio's single-issuer CPU from setting
    # the sequential ceiling. Aggregate depth and transferred bytes stay 16/4G.
    sequential_options=async_options+['--numjobs=4','--bs=1m','--size=1g','--offset_increment=1g','--iodepth=4']
    random_options=['--bs=4k','--size=2g','--time_based=1','--runtime=3','--ramp_time=1','--norandommap=1','--randrepeat=1','--randseed=1701']
    cases=[
        ('sequential-read','sequential.dat',sequential_options+['--rw=read']),
        ('sequential-write','sequential.dat',sequential_options+['--rw=write','--end_fsync=1']),
        ('random-read-qd1','random.dat',async_options+random_options+['--rw=randread','--iodepth=1']),
        ('random-read-qd16','random.dat',async_options+random_options+['--rw=randread','--iodepth=16']),
        ('random-write-qd1','random.dat',async_options+random_options+['--rw=randwrite','--iodepth=1','--end_fsync=1']),
        ('random-write-qd16','random.dat',async_options+random_options+['--rw=randwrite','--iodepth=16','--end_fsync=1']),
        ('sync-write','sync.dat',['--ioengine=psync','--rw=write','--bs=4k','--size=64m','--iodepth=1','--time_based=1','--runtime=3','--ramp_time=1','--fdatasync=1','--end_fsync=1']),
    ]
    offset=a.trial%len(cases);cases=cases[offset:]+cases[:offset]
    result={'kind':'storage','trial':a.trial,'fio_version':command([a.fio,'--version']).strip(),'cases':[],'errors':[]}
    for name,file,options in cases:
        before={str(block_stat_path):block_stat_path.read_text()}
        value=fio(a.fio,name,ROOT/file,options)
        after={str(block_stat_path):block_stat_path.read_text()}
        job=value['fio']['jobs'][0]
        direction='read' if 'read' in name else 'write'
        assert job[direction]['io_bytes']>0 and job[direction]['total_ios']>0
        if name.startswith('sequential'):
            assert job[direction]['io_bytes']==4*1024**3
        value.update(name=name,block_stat_before=before,block_stat_after=after)
        (directory/f'{name}.json').write_text(json.dumps(value))
        result['cases'].append(value)
    # Excluded integrity proof on the same filesystem, separate from timing.
    proof=ROOT/'integrity.dat'
    result['integrity']=fio(a.fio,'checksum-proof',proof,['--rw=write','--bs=64k','--size=64m','--ioengine=libaio','--iodepth=8','--verify=crc32c','--verify_fatal=1','--do_verify=1','--end_fsync=1'])
    assert result['integrity']['fio']['jobs'][0]['read']['io_bytes']==64*1024**2
    proof.unlink()
    kernel_after=command(['dmesg','--level=err,warn']).splitlines()
    result['new_kernel_warnings']=[line for line in kernel_after if line not in kernel_before]
    poll_parameter=Path('/sys/module/nvme/parameters/poll_queues')
    result['nvme_poll_queues']=poll_parameter.read_text().strip() if poll_parameter.exists() else None
    result['block_device']=device
    result['errors'].extend(line for line in result['new_kernel_warnings'] if ('nvme' in line and 'timeout' in line) or 'I/O error' in line or 'resetting link' in line)
    (directory/'result.json').write_text(json.dumps(result))
    print(json.dumps(result))

if __name__=='__main__':
    main()
