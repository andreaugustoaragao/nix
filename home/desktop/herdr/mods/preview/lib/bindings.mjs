import { readFile } from 'node:fs/promises';

export const BINDING_LABEL = 'herdr-preview.session';

export async function processStart(pid) {
  try {
    const stat = await readFile(`/proc/${pid}/stat`, 'utf8');
    return stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19];
  } catch { return null; }
}

export async function boundSnapshot(terminal) {
  const raw = terminal.labels?.[BINDING_LABEL];
  if (!raw) return null;
  let binding;
  try { binding = JSON.parse(raw); } catch { return null; }
  if (binding.version !== 1 || !['pi', 'opencode'].includes(binding.agent)
    || binding.pid !== terminal.foreground?.pid || typeof binding.file !== 'string') return null;
  if (binding.start !== await processStart(binding.pid)) return null;
  const info = await readFile(binding.file, 'utf8');
  if (info.length > 5 * 1024 * 1024) throw new Error('The agent preview snapshot exceeds its size limit.');
  const data = JSON.parse(info);
  if (data.version !== 1 || data.pid !== binding.pid || data.start !== binding.start || data.agent !== binding.agent
    || !Array.isArray(data.messages) || typeof data.cwd !== 'string'
    || !(data.session === null || typeof data.session === 'string')
    || !data.messages.every(message => typeof message.id === 'string' && typeof message.text === 'string'
      && (message.question === undefined || typeof message.question === 'string'))) {
    throw new Error('The selected agent reported an invalid preview snapshot.');
  }
  return data;
}
