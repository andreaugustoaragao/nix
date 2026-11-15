import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { boundSnapshot } from './bindings.mjs';
import { assistantMessages, processTranscript } from './transcripts.mjs';

const run = promisify(execFile);

export async function readAgent(address) {
  const remote = typeof address === 'string' && /^([A-Za-z0-9][A-Za-z0-9._-]{0,63})\/(t[a-z0-9]+)$/.exec(address);
  if (remote) {
    const result = await run('hc', ['exec', '--on', remote[1], 'herdr-agent-preview', remote[2]],
      { timeout: 15000, maxBuffer: 6 * 1024 * 1024 });
    return { ...JSON.parse(result.stdout), machine: remote[1] };
  }
  if (typeof address !== 'string' || !/^t[a-z0-9]+$/.test(address)) {
    throw new Error('Choose a local terminal or a registered machine/terminal address.');
  }
  const result = await run('hc', ['get', address], { timeout: 5000, maxBuffer: 1024 * 1024 });
  const terminal = JSON.parse(result.stdout);
  const snapshot = await boundSnapshot(terminal);
  const agent = snapshot?.agent || terminal.status?.app;
  if (!['codex', 'claude-code', 'pi', 'omp', 'oh-my-pi', 'opencode'].includes(agent)) {
    throw new Error('This agent has no supported Markdown transcript reader yet. Supported agents: Codex, Claude Code, pi and OpenCode.');
  }
  if (!snapshot && ['pi', 'opencode'].includes(agent)) throw new Error('Reload pi with /reload, or restart OpenCode, to load the Herdr Preview integration.');
  const transcript = snapshot || await processTranscript(terminal.foreground?.pid, agent);
  // Recheck after reading: a restart or foreground switch must not show old output.
  const current = JSON.parse((await run('hc', ['get', address], { timeout: 5000, maxBuffer: 1024 * 1024 })).stdout);
  if (current.foreground?.pid !== terminal.foreground?.pid) {
    throw new Error('The selected agent changed while its transcript was being read. Retrying…');
  }
  return { agent, session: transcript.session, cwd: transcript.cwd || terminal.foreground?.cwd,
    truncated: transcript.truncated, messages: snapshot ? snapshot.messages : assistantMessages(transcript.text, agent) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(await readAgent(process.argv[2]))); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
