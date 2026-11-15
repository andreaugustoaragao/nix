"""Structured intake presentation data; original source-processing receipts stay separate."""
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit
from datetime import datetime


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def plain(text):
    return re.sub(r'\s+', ' ', re.sub(r'[*`]', '', text)).strip()


def cells(line):
    return [p.strip().replace('\\|', '|') for p in re.split(r'(?<!\\)\|', line.strip().strip('|'))]


def links(text, origin):
    result = []
    for label, href in re.findall(r'\[([^\]]+)\]\(([^\s)]+)\)', text):
        result.append({'label': label, 'url': href, 'origin': origin})
    return result


def legacy_items(report):
    result, headers = [], []
    for line in report['briefing_markdown'].splitlines():
        if not line.startswith('|'):
            continue
        row = cells(line)
        if row and row[0].lower() == 'priority':
            headers = [h.lower() for h in row]
            continue
        if not headers or not row or not re.match(r'^\d+[.)]?$', row[0]):
            continue
        def value(fragment):
            return next((row[i] for i, h in enumerate(headers) if fragment in h and i < len(row)), '')
        title = row[1]
        sources = links(value('evidence'), report['briefing_path'])
        # Conservative fallback: changed wording is a new identity, never an inferred merge.
        identity = 'legacy:' + digest({'title': plain(title).casefold(), 'sources': [s['url'] for s in sources]})[:24]
        kind = 'decision' if re.search(r'\b(decide|approve|agree with|agree whether|agree on)\b', plain(title), re.I) else 'action'
        result.append({'id': identity, 'title': plain(title), 'kind': kind, 'priority': int(row[0].rstrip('.)')),
                       'owner': plain(value('owner')), 'timing': plain(value('why') or value('deadline')),
                       'effort': plain(value('est.')), 'sources': sources, 'legacy': True})
    return result


def validated_items(value):
    if not isinstance(value, list) or len(value) > 30:
        raise ValueError('items must be a list of at most 30 actions')
    result, seen = [], set()
    allowed = {'id', 'title', 'kind', 'priority', 'owner', 'timing', 'effort', 'sources', 'todo', 'due_at'}
    for item in value:
        if not isinstance(item, dict) or set(item) - allowed:
            raise ValueError('Unknown structured item fields')
        identity = item.get('id', '')
        if not isinstance(identity, str) or not re.fullmatch(r'[a-zA-Z0-9:_-]{3,120}', identity) or identity in seen:
            raise ValueError('Each item needs a unique stable id')
        seen.add(identity)
        if item.get('kind') not in ('action', 'decision', 'waiting'):
            raise ValueError('Item kind must be action, decision or waiting')
        for field in ('title', 'owner', 'timing', 'effort'):
            if not isinstance(item.get(field, ''), str) or len(item.get(field, '')) > 1600:
                raise ValueError(f'Invalid item {field}')
        if not item.get('title', '').strip():
            raise ValueError('An item must have a title')
        if type(item.get('priority', 0)) is not int or not 0 <= item.get('priority', 0) <= 30:
            raise ValueError('Invalid priority')
        sources = item.get('sources', [])
        if not isinstance(sources, list) or not 1 <= len(sources) <= 12:
            raise ValueError('Every item requires source evidence')
        for source in sources:
            if not isinstance(source, dict) or set(source) - {'label', 'url', 'origin'}:
                raise ValueError('Invalid source')
            if not all(isinstance(source.get(k), str) and 0 < len(source[k]) <= 4000 for k in ('label','url')):
                raise ValueError('Invalid source label or URL')
            scheme = urlsplit(source['url']).scheme
            if scheme and scheme not in ('https','http','intake-note'):
                raise ValueError('Unsupported source URL scheme')
        todo = item.get('todo')
        if todo is not None and (not isinstance(todo, dict) or set(todo) != {'title','owner','opened'}
                                 or not all(isinstance(v,str) and v.strip() for v in todo.values())):
            raise ValueError('TODO reference needs the exact title, owner and opened date')
        if item.get('due_at'):
            if datetime.fromisoformat(item['due_at'].replace('Z','+00:00')).tzinfo is None:
                raise ValueError('due_at requires timezone')
        result.append(dict(item, owner=item.get('owner',''), timing=item.get('timing',''), effort=item.get('effort','')))
    return result


def source_freshness(manifest):
    result = []
    coverage = manifest.get('coverage', [])
    if not isinstance(coverage, list):
        return result
    for source in coverage:
        if not isinstance(source, dict):
            continue
        gaps = source.get('gaps', [])
        if isinstance(gaps, str):
            gaps = [gaps]
        text = ' '.join(str(g) for g in gaps)
        blocked = source.get('pagination_complete') is False and bool(re.search(r'block|inaccessible|reauth|verification|forbidden|403', text, re.I))
        status = 'unavailable' if blocked else 'partial' if gaps or source.get('pagination_complete') is not True else 'checked'
        at = next((source.get(k) for k in ('delivery_refresh_at','checked_at','capture_cutoff','cutoff') if source.get(k)), None)
        at = at or source.get('window', {}).get('cutoff')
        if not at and status != 'unavailable':
            at = manifest.get('window', {}).get('cutoff')
        result.append({'source': source.get('source', source.get('source_type','Source')), 'status': status,
                       'checked_through': at if status != 'unavailable' else None, 'gaps': [str(g) for g in gaps]})
    return result


def presentation_snapshot(manifest, structured=None):
    return {'items': validated_items(structured['items']) if structured is not None else None,
            'sources': source_freshness(manifest)}


def change_set(current, baseline):
    before = {item['id']: item for item in baseline}
    now = {item['id']: item for item in current}
    fields = ('title','kind','owner','timing','effort','sources','due_at')
    def version(item):
        return {k: item.get(k) for k in fields}
    return {'new': [i for i in current if i['id'] not in before],
            'changed': [{'item': i, 'before': before[i['id']]} for i in current
                        if i['id'] in before and version(i) != version(before[i['id']])],
            'not_listed': [i for i in baseline if i['id'] not in now],
            'unchanged': sum(i['id'] in before and version(i) == version(before[i['id']]) for i in current)}


def todo_rows(text):
    result = []
    for line in text.splitlines():
        if not re.match(r'^\| \[[ x]\] \|', line):
            continue
        row = cells(line)
        if len(row) not in (5, 6) or (row[0] == '[ ]' and len(row) != 5):
            continue
        match = re.match(r'^\*\*(.+?)\*\*', row[1])
        title = plain(match[1] if match else row[1])
        result.append({'ref': {'title': title, 'owner': row[2], 'opened': row[4]},
                       'status': 'done' if row[0] == '[x]' else 'open', 'line': line, 'cells': row})
    return result
