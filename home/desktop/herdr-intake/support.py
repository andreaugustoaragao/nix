"""Local file helpers for the packaged Intake viewer. No delivery or ingestion."""
import json
import os
import re
import tempfile
from datetime import datetime
from urllib.parse import quote

def stamp(value):
    date = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if date.tzinfo is None:
        raise ValueError('A timestamp must include its timezone')
    return date


def contained(root, path):
    candidate = (root / path).resolve()
    candidate.relative_to(root.resolve())
    return candidate


def viewer_markdown(root, brief_path, text):
    def link(match):
        target, _, heading = match.group(1).partition('#')
        label = match.group(2) or target
        candidate = (brief_path.parent / target).resolve()
        if not candidate.is_file():
            candidate = candidate.with_suffix('.md')
        try:
            relative = candidate.relative_to(root)
        except ValueError:
            return label
        if not candidate.is_file():
            return label
        return f'[{label}](intake-note:{quote(str(relative))})'
    return re.sub(r'\[\[([^\]|]+)(?:\|([^\]]+))?\]\]', link, text)


def atomic(path, value):
    handle, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(handle, 'w') as output:
            json.dump(value, output, ensure_ascii=False, indent=2)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)
