#!/usr/bin/env python3
import os,json,sys,time
from pathlib import Path
job=Path(os.environ['CHAT_SEND_JOB']);v=json.loads(job.read_text());mode='status' if sys.argv[1]=='status' else 'deliver'
with job.with_name('fake-calls.jsonl').open('a') as f:f.write(json.dumps({'mode':mode,'args':sys.argv[1:]})+'\n')
time.sleep(v.get('fixture_delay',0))
outcome=v.get('fixture_outcome','sent') if mode=='deliver' else v.get('fixture_status','sent')
print(json.dumps({'outcome':outcome,'reason':'fixture','operation_id':v['operation'],'send_attempted':True}))
