import { open, readdir, readlink } from 'node:fs/promises';
import path from 'node:path';
import { assistantReplies } from './replies.mjs';

const MAX_BYTES = 4 * 1024 * 1024;

export function assistantMessages(text, agent) {
  const messages = [];
  for (const line of text.split('\n')) {
    let record;
    try { record = JSON.parse(line); } catch { continue; }
    let message;
    if (agent === 'codex') {
      if (record.type !== 'response_item' || record.payload?.type !== 'message') continue;
      message = record.payload;
    } else if (agent === 'claude-code') {
      if (!['user', 'assistant'].includes(record.type)) continue;
      message = record.message;
    } else {
      if (record.type !== 'message') continue;
      message = record.message;
    }
    if (!message) continue;
    messages.push({ ...message, id: message.id || record.uuid || record.id || record.timestamp || String(messages.length) });
  }
  return assistantReplies(messages);
}

export async function readWindow(file) {
  const handle = await open(file, 'r');
  try {
    const { size } = await handle.stat();
    const head = Buffer.alloc(Math.min(size, 65536));
    const first = await handle.read(head, 0, head.length, 0);
    let metadata;
    try { metadata = JSON.parse(head.subarray(0, first.bytesRead).toString('utf8').split('\n')[0]); }
    catch { metadata = null; }
    const start = Math.max(0, size - MAX_BYTES);
    const tail = Buffer.alloc(size - start);
    const last = await handle.read(tail, 0, tail.length, start);
    let text = tail.subarray(0, last.bytesRead).toString('utf8');
    if (start) text = text.slice(text.indexOf('\n') + 1);
    return { metadata, text, truncated: start > 0 };
  } finally { await handle.close(); }
}

export async function processTranscript(pid, agent, proc = '/proc') {
  if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error('The selected agent has no live process.');
  let handles;
  try { handles = await readdir(path.join(proc, String(pid), 'fd')); }
  catch { throw new Error('Cannot inspect the selected agent process. Automatic session discovery currently needs local Linux /proc access.'); }
  const files = new Set();
  for (const fd of handles) {
    try {
      const target = await readlink(path.join(proc, String(pid), 'fd', fd));
      if (target.endsWith('.jsonl')) files.add(target);
    } catch {}
  }
  const candidates = [];
  for (const file of files) {
    if (agent === 'codex' && !/[/\\]rollout-[^/\\]+\.jsonl$/.test(file)) continue;
    try {
      const data = await readWindow(file);
      if (agent === 'codex') {
        const meta = data.metadata;
        if (meta?.type !== 'session_meta' || meta.payload?.source !== 'cli') continue;
        candidates.push({ file, session: meta.payload.id, cwd: meta.payload.cwd, ...data });
      } else if (agent === 'claude-code') {
        if (!file.includes('/.claude/projects/')) continue;
        candidates.push({ file, session: path.basename(file, '.jsonl'), ...data });
      } else if (data.metadata?.type === 'session') {
        candidates.push({ file, session: data.metadata.id, cwd: data.metadata.cwd, ...data });
      }
    } catch {}
  }
  if (candidates.length !== 1) throw new Error(candidates.length
    ? 'More than one conversation is open in this agent. Preview will not guess which session you selected.'
    : 'No open transcript was found for this agent. Codex is verified; other agents must keep their JSONL transcript open.');
  return candidates[0];
}
