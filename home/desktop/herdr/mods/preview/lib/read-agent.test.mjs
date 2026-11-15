import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, writeFile, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readAgent } from './read-agent.mjs';
import { boundSnapshot, BINDING_LABEL, processStart } from './bindings.mjs';
import { createPublisher } from '../integrations/session-publisher.mjs';

test('publisher creates private snapshots, binds the live process and removes its file', async t => {
  const root = await mkdtemp(join(tmpdir(), 'herdr-preview-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  let label;
  const publisher = createPublisher('pi', {
    env: { HERDR_APP_HOME: root, HC_TERMINAL_ID: 't1', HC_TERMINAL_SOCKET: '/unused' },
    report: async (terminal, raw) => { assert.equal(terminal, 't1'); label = raw; },
  });
  await publisher.publish({ session: 'fixture', cwd: root, messages: [{ id: '1', text: '# Remote reply' }] });
  const terminal = { foreground: { pid: process.pid }, labels: { [BINDING_LABEL]: label } };
  const snapshot = await boundSnapshot(terminal);
  assert.equal(snapshot.session, 'fixture');
  assert.equal(snapshot.messages[0].text, '# Remote reply');
  const binding = JSON.parse(label);
  assert.equal(binding.start, await processStart(process.pid));
  assert.equal(await boundSnapshot({ ...terminal, foreground: { pid: process.pid + 1 } }), null);
  terminal.labels[BINDING_LABEL] = JSON.stringify({ ...binding, start: 'stale' });
  assert.equal(await boundSnapshot(terminal), null);
  await publisher.close();
  await assert.rejects(readFile(binding.file), { code: 'ENOENT' });
});

test('remote address executes only the managed reader on the registered machine', async t => {
  const root = await mkdtemp(join(tmpdir(), 'herdr-preview-remote-'));
  const previousPath = process.env.PATH;
  t.after(async () => { process.env.PATH = previousPath; await rm(root, { recursive: true, force: true }); });
  await mkdir(join(root, 'bin'));
  const expected = { agent: 'pi', session: 'remote', cwd: '/project', messages: [{ id: '1', text: 'Remote snapshot' }] };
  await writeFile(join(root, 'bin/hc'), `#!${process.execPath}
import assert from 'node:assert/strict';
assert.deepEqual(process.argv.slice(2), ['exec', '--on', 'worker-1', 'herdr-agent-preview', 't2']);
console.log(${JSON.stringify(JSON.stringify(expected))});
`, { mode: 0o700 });
  process.env.PATH = `${root}/bin:${previousPath}`;
  assert.deepEqual(await readAgent('worker-1/t2'), { ...expected, machine: 'worker-1' });
  for (const address of ['--worker/t2', 'worker/t2/extra', 'worker/../../etc/passwd', 'worker/$(id)', null]) {
    await assert.rejects(readAgent(address), /registered machine\/terminal/);
  }
});

test('publisher outside a core terminal is inactive', async () => {
  const publisher = createPublisher('pi', { env: {}, report: () => { throw new Error('Unexpected registration'); } });
  await publisher.publish({ session: null, cwd: '/project', messages: [] });
  await publisher.close();
});
