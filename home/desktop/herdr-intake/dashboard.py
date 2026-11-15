#!/usr/bin/env python3
"""Local Intake history and user follow-up state. No source ingestion or remote writes."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import sys
from zoneinfo import ZoneInfo

from intake_data import cells, change_set, digest, legacy_items, plain, source_freshness, todo_rows
from support import atomic, contained, stamp, viewer_markdown

ROOT = Path(os.environ["HERDR_INTAKE_NOTES_ROOT"])
BASE = Path('_system/intake/work-intake/herdr')
ZONE = ZoneInfo('America/Denver')


def read(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default


def now():
    return datetime.now(timezone.utc)


def reports(root):
    directory = root / BASE
    result = {}
    for path in sorted((directory / 'receipts').glob('*.json')):
        report = read(path)
        if not isinstance(report, dict) or not report.get('run_id') or not report.get('generated_at'):
            raise ValueError(f'Invalid saved report: {path.name}')
        stamp(report['generated_at'])
        result[report['run_id']] = report
    latest = read(directory / 'latest.json')
    if latest:
        result.setdefault(latest['run_id'], latest)
    # Older saved intakes predate desktop delivery. Their finished manifests retain provenance.
    for path in (root / '_system/intake/work-intake').glob('*/manifest.json'):
        m = read(path)
        if m.get('run_id') in result or m.get('status') not in ('complete','partial') or not m.get('briefed_at') or not m.get('briefing_path'):
            continue
        brief = contained(root, m['briefing_path'])
        if not brief.is_file():
            continue
        at = stamp(m['briefed_at'])
        result[m['run_id']] = {'schema_version':1, 'run_id':m['run_id'], 'generated_at':m['briefed_at'],
            'horizon_end':m.get('horizon_end',m['briefed_at']), 'display_time':at.astimezone(ZONE).strftime('%a %H:%M %Z'),
            'coverage':'complete' if m.get('source_coverage_complete') is True else 'partial',
            'briefing_path':m['briefing_path'], 'briefing_markdown':viewer_markdown(root,brief,brief.read_text()),
            'source_manifest':str(path.relative_to(root)), 'summary':'Saved intake report', 'notify':False,
            'attention':'routine', 'action_count':0, 'saved_only':True}
    return sorted(result.values(), key=lambda r:stamp(r['generated_at']), reverse=True)


def enrich(root, report):
    result = dict(report)
    presentation = report.get('presentation') or {}
    result['items'] = presentation.get('items') if presentation.get('items') is not None else legacy_items(report)
    manifest_path = report.get('source_manifest')
    m = read(contained(root, manifest_path), {}) if manifest_path else {}
    result['sources'] = presentation.get('sources') if 'sources' in presentation else source_freshness(m)
    result['sources'] = [dict(s, display_checked=stamp(s['checked_through']).astimezone(ZONE).strftime('%b %d, %H:%M %Z') if s.get('checked_through') else 'Not verified') for s in result['sources']]
    result['calendar'] = next((line for line in report['briefing_markdown'].splitlines() if line.lower().startswith('calendar')), '')
    return result


def state(root):
    return read(root / BASE / 'follow-up.json', {'schema_version':1,'items':{},'read_reports':[],'reviewed_run_id':None,'pending':{},'operations':{}})


def todo_match(root, ref):
    candidates = [r for r in todo_rows((root/'TODO.md').read_text()) if r['ref'] == ref]
    if len(candidates) != 1:
        raise ValueError('The linked TODO changed or is ambiguous. Review and link it again.')
    return candidates[0]


def next_slot(moment):
    local = moment.astimezone(ZONE)
    for offset in range(8):
        day = local + timedelta(days=offset)
        if day.weekday() >= 5:
            continue
        for hour in (6,8,10,12,14,16):
            candidate = day.replace(hour=hour,minute=30,second=0,microsecond=0)
            if candidate > local:
                return candidate.isoformat()


def view(root, report_id=None, moment=None):
    moment = moment or now()
    saved, user = reports(root), state(root)
    if not saved:
        return {'schema_version':2,'report':None,'history':[],'items':[],'reminders':[],'pending':[]}
    index = {r['run_id']:r for r in saved}
    selected = report_id or saved[0]['run_id']
    if selected not in index:
        raise ValueError('This report is no longer available.')
    report = enrich(root,index[selected])
    reviewed = user.get('reviewed_run_id')
    baseline = reviewed if reviewed in index and stamp(index[reviewed]['generated_at']) < stamp(report['generated_at']) else None
    if reviewed == selected:
        baseline = selected
    previous = next((r for r in saved if stamp(r['generated_at']) < stamp(report['generated_at'])), None)
    baseline = baseline or (previous['run_id'] if previous else None)
    before = enrich(root,index[baseline]) if baseline else {'items':[],'sources':[]}
    all_items = {}
    for r in reversed(saved):
        for item in enrich(root,r)['items']:
            all_items[item['id']] = dict(item, report_id=r['run_id'])
    def follow(item):
        followup = dict(user['items'].get(item['id'], {}))
        due = bool(followup.get('remind_at') and stamp(followup['remind_at']) <= moment)
        if followup.get('remind_at'):
            followup['display_reminder'] = stamp(followup['remind_at']).astimezone(ZONE).strftime('%a %b %d, %H:%M %Z')
        ref = followup.get('todo') or item.get('todo')
        todo, problem = None, None
        if ref:
            try:
                match = todo_match(root,ref)
                todo = {'ref':ref,'status':match['status'],'etag':digest(match['line'])}
            except ValueError as error:
                problem = str(error)
        status = followup.get('status','waiting' if item['kind']=='waiting' else 'open')
        if status == 'snoozed' and due:
            status = 'open'
        return dict(item, followup=followup, todo_link=todo, todo_error=problem, reminder_due=due,
                    effective_status='done' if todo and todo['status']=='done' else status)
    items = [follow(i) for i in report['items']]
    retained = [follow(i) for key,i in all_items.items() if key in user['items'] and key not in {a['id'] for a in report['items']}]
    reminders = []
    for item in [*items,*retained]:
        f = item['followup']
        if item['effective_status']!='done' and f.get('status')=='snoozed' and item['reminder_due']:
            reminders.append(dict(item, reminder_key=digest([item['id'],f['remind_at']])[:24]))
    changes = change_set(report['items'],before['items'])
    def coverage_version(sources):
        return [{k:s.get(k) for k in ('source','status','gaps')} for s in sources]
    changes['coverage_changed'] = digest(coverage_version(report['sources'])) != digest(coverage_version(before['sources']))
    # Checkpoints are evidence of attempts, never proof that a process is still running.
    lock = root/'_system/intake/work-intake/.writer-lock'
    return {'schema_version':2,'latest':saved[0]['run_id'],'report':report,'items':items,
            'followups':retained, 'reminders':reminders,
            'pending':list(user.get('pending',{}).values()), 'read':selected in user['read_reports'], 'read_report_ids':user['read_reports'],
            'baseline_label':'your last review' if baseline==reviewed else 'the previous report' if baseline else 'the first available report',
            'baseline':baseline,'changes':changes,
            'history':[{'run_id':r['run_id'],'generated_at':r['generated_at'],'date_label':stamp(r['generated_at']).astimezone(ZONE).strftime('%a %b %d, %H:%M %Z'),'summary':r.get('summary',''),
                        'coverage':r['coverage'],'read':r['run_id'] in user['read_reports'],'saved_only':r.get('saved_only',False)} for r in saved],
            'next_scheduled':next_slot(moment),'writer_record_present':lock.exists()}


@contextmanager
def interaction_lock(root):
    directory = root/BASE
    directory.mkdir(parents=True,exist_ok=True)
    with (directory/'.interaction-lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        yield


@contextmanager
def vault_writer(root, operation):
    lock = root/'_system/intake/work-intake/.writer-lock'
    try:
        lock.mkdir()
    except FileExistsError:
        raise ValueError('Intake is updating the vault. Try completion again after it finishes.')
    try:
        (lock/'owner.json').write_text(json.dumps({'operation_id':operation,'host':os.uname().nodename,'session':'herdr-item-action'}))
        yield
    finally:
        (lock/'owner.json').unlink()
        lock.rmdir()


def complete_todo(root, ref, expected):
    path = root/'TODO.md'
    original = path.read_text()
    match = todo_match(root,ref)
    if match['status']=='done':
        return 'already_complete'
    if digest(match['line']) != expected:
        raise ValueError('The TODO changed after you viewed it. Reload and review it before completing.')
    lines = original.splitlines()
    if lines.count(match['line']) != 1:
        raise ValueError('Ambiguous TODO row')
    start = next((i for i,line in enumerate(lines) if re.match(r'^## Completed(?:\s|$)',line)),None)
    if start is None:
        raise ValueError('TODO Completed section was not found')
    end = next((i for i in range(start+1,len(lines)) if lines[i].startswith('## ')),len(lines))
    header = next((i for i in range(start+1,end) if lines[i].startswith('| Status |') and 'Completed' in lines[i]),None)
    if header is None or header+1>=end or not re.match(r'^\|\s*-',lines[header+1]):
        raise ValueError('TODO Completed table has an unexpected format')
    # Preserve escaped wiki-link separators in the original row.
    raw = re.split(r'(?<!\\)\|',match['line'].strip().strip('|'))
    raw[0]=' [x] '
    finished='|'+'|'.join(raw)+' '+ '| '+now().astimezone(ZONE).date().isoformat()+' |'
    insertion = header+2
    for i in range(header+2,end):
        row = cells(lines[i]) if lines[i].startswith('|') else []
        if len(row) != 6 or row[0] != '[x]' or row[4] < ref['opened']:
            break
        insertion = i+1
    lines.insert(insertion,finished)
    lines.remove(match['line'])
    updated='\n'.join(lines)+'\n'
    if path.read_text()!=original:
        raise ValueError('TODO changed concurrently. Reload before trying again.')
    import tempfile
    handle,tmp=tempfile.mkstemp(prefix='.TODO-intake-',dir=root)
    try:
        with os.fdopen(handle,'w') as out:
            out.write(updated);out.flush();os.fsync(out.fileno())
        if path.read_text()!=original:
            raise ValueError('TODO changed concurrently. Reload before trying again.')
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
    if todo_match(root,ref)['status']!='done':
        raise ValueError('TODO completion could not be verified')
    return 'completed'


def apply(root, request):
    op=request.get('operation_id','')
    if not re.fullmatch(r'[a-zA-Z0-9_-]{8,100}',op):
        raise ValueError('A stable operation ID is required')
    with interaction_lock(root):
        user=state(root);path=root/BASE/'follow-up.json'
        if op in user['operations']:
            if user['operations'][op].get('request_hash') != digest(request):
                raise ValueError('Operation ID already belongs to a different request')
            return user['operations'][op]
        action=request.get('action')
        available={r['run_id']:r for r in reports(root)}
        report_id=request.get('report_id')
        if report_id not in available:
            raise ValueError('Unknown intake report')
        if action=='cancel-pending':
            pending=user['pending'].get(request.get('pending_id'))
            if not pending or todo_match(root,pending['todo'])['status']!='open':
                raise ValueError('Completion outcome must be reconciled before cancelling this request')
            user['pending'].pop(request['pending_id'])
            result={'message':'Cancelled the pending completion. The vault action remains open.'}
        elif action=='read':
            user['read_reports']=list(dict.fromkeys([*user['read_reports'],report_id]))
            user['reviewed_run_id']=max(user['read_reports'],key=lambda key:stamp(available[key]['generated_at']) if key in available else datetime.min.replace(tzinfo=timezone.utc))
            result={'message':'Report marked read. Item completion is unchanged.'}
        else:
            item=next((i for i in enrich(root,available[report_id])['items'] if i['id']==request.get('item_id')),None)
            if item is None:
                raise ValueError('Unknown intake item')
            pending = next((p for p in user['pending'].values() if p['request'].get('item_id') == item['id']), None)
            if action in ('link', 'done') and pending and pending['request'] != request:
                raise ValueError('Reconcile or cancel the saved completion before changing this action.')
            follow=user['items'].get(item['id'],{})
            if action=='link':
                match=todo_match(root,request['todo'])
                follow['todo']=match['ref']
                result={'message':'Linked to the selected vault action. Nothing was marked complete.'}
            elif action=='done':
                ref=follow.get('todo') or item.get('todo')
                if ref:
                    intent=user['pending'].get(op) or {'request':request,'todo':ref}
                    if intent['request'] != request:
                        raise ValueError('Pending operation must be retried with its original request')
                    user['pending'][op]=intent;atomic(path,user)
                    with vault_writer(root,op):
                        complete_todo(root,intent['todo'],intent['request'].get('todo_etag'))
                    follow.update(status='done',completed_in='TODO.md')
                    result={'message':'Completed the linked vault action and verified TODO.md.'}
                else:
                    follow.update(status='done',completed_in='Intake')
                    result={'message':'Marked done in Intake. No vault TODO was linked.'}
                follow.pop('remind_at',None)
            elif action=='open':
                follow.update(status='open');follow.pop('remind_at',None)
                result={'message':'Intake follow-up reopened. Existing vault completion is unchanged.'}
            elif action=='waiting':
                follow.update(status='waiting');follow.pop('remind_at',None)
                result={'message':'Marked waiting on others in Intake.'}
            elif action in ('remind-hour','remind-tomorrow'):
                when=now()+timedelta(hours=1)
                if action=='remind-tomorrow':
                    when=(now().astimezone(ZONE)+timedelta(days=1)).replace(hour=9,minute=0,second=0,microsecond=0)
                follow.update(status='snoozed',remind_at=when.isoformat())
                result={'message':'Reminder set for '+when.astimezone(ZONE).strftime('%a %H:%M %Z')+'.'}
            else:
                raise ValueError('Unknown item action')
            follow['updated_at']=now().isoformat();user['items'][item['id']]=follow
        user['pending'].pop(op,None)
        result['request_hash']=digest(request)
        user['operations'][op]=result
        atomic(path,user)
        return result


def candidates(root, title):
    terms=set(re.findall(r'[a-z0-9]{4,}',title.lower()))
    rows=[r for r in todo_rows((root/'TODO.md').read_text()) if r['status']=='open']
    scored=[(len(terms & set(re.findall(r'[a-z0-9]{4,}',r['ref']['title'].lower()))),r) for r in rows]
    return [{'ref':r['ref'],'preview':plain(r['cells'][1])[:650]} for score,r in sorted(scored,key=lambda x:-x[0])[:8] if score]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('command',choices=['view','action','candidates'])
    p.add_argument('--report');p.add_argument('--request');p.add_argument('--title',default='')
    a=p.parse_args()
    if a.command=='view': result=view(ROOT,a.report)
    elif a.command=='action': result=apply(ROOT,json.loads(a.request))
    else: result=candidates(ROOT,a.title)
    print(json.dumps(result,ensure_ascii=False))


if __name__=='__main__':
    try:
        main()
    except (ValueError,OSError,KeyError,TypeError,json.JSONDecodeError) as error:
        print(str(error),file=sys.stderr);sys.exit(1)
