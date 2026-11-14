import { mkdir, writeFile, rename, unlink } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import os from 'node:os';
import { BINDING_LABEL, processStart } from '../lib/bindings.mjs';

const run = promisify(execFile);

export function createPublisher(agent, { env = process.env, report = async (terminal, value) => {
  await run('hc', ['label', terminal, `${BINDING_LABEL}=${value}`], { timeout: 3000, env });
} } = {}) {
  const terminal = env.HC_TERMINAL_ID;
  if (!terminal || !env.HC_TERMINAL_SOCKET) return { publish: async () => {}, close: async () => {} };
  const directory = path.join(env.HERDR_APP_HOME || path.join(os.homedir(), '.config/herdr-app'), 'data/herdr-preview/sessions');
  const file = path.join(directory, `${process.pid}-${randomUUID()}.json`);
  let generation = 0, disposed = false, bound = false;
  let chain = Promise.resolve();

  function publish({ session, cwd, messages }) {
    if (disposed) return Promise.resolve();
    const revision = ++generation;
    const snapshot = { version: 1, agent, session: session ?? null, cwd, pid: process.pid, messages: [] };
    let size = 0;
    for (const message of messages.slice(-40).reverse()) {
      const bytes = Buffer.byteLength(JSON.stringify(message));
      if (size + bytes > 4 * 1024 * 1024) { snapshot.truncated = true; break; }
      size += bytes;
      snapshot.messages.unshift(message);
    }
    const operation = chain.catch(() => {}).then(async () => {
      if (disposed || revision !== generation) return;
      snapshot.start = await processStart(process.pid);
      await mkdir(directory, { recursive: true, mode: 0o700 });
      const temporary = `${file}.${revision}.tmp`;
      try {
        await writeFile(temporary, JSON.stringify(snapshot), { mode: 0o600 });
        if (disposed || revision !== generation) return;
        await rename(temporary, file);
        if (!bound) {
          await report(terminal, JSON.stringify({ version: 1, agent, pid: process.pid, start: snapshot.start, file }));
          bound = true;
        }
      } finally { await unlink(temporary).catch(() => {}); }
    });
    chain = operation;
    return operation;
  }

  async function close() {
    disposed = true;
    generation++;
    await chain.catch(() => {});
    await unlink(file).catch(() => {});
  }
  return { publish, close };
}
