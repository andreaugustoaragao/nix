import { createPublisher } from './session-publisher.mjs';
import { assistantReplies } from '../lib/replies.mjs';

// Pi invokes this factory again on /reload and session replacement.
export default function preview(pi) {
  let publisher;
  let context;
  let live;
  let timer;

  async function publish() {
    if (!publisher || !context) return;
    const messages = context.sessionManager.getBranch().filter(entry => entry.type === 'message')
      .map(entry => ({ ...entry.message, id: entry.id }));
    if (live) messages.push({ ...live, id: 'streaming' });
    await publisher.publish({ session: context.sessionManager.getSessionId(), cwd: context.cwd,
      messages: assistantReplies(messages) });
  }
  function schedule(ctx) {
    context = ctx;
    if (timer) return;
    timer = setTimeout(() => {
      timer = undefined;
      publish().catch(error => console.warn('Herdr Preview:', error.message));
    }, 100);
    timer.unref?.();
  }
  pi.on('session_start', async (_event, ctx) => {
    context = ctx;
    publisher = createPublisher('pi');
    await publish();
  });
  pi.on('message_update', (event, ctx) => { live = event.message; schedule(ctx); });
  pi.on('message_end', (_event, ctx) => { live = undefined; schedule(ctx); });
  for (const event of ['session_tree', 'agent_end', 'session_compact']) {
    pi.on(event, (_event, ctx) => { live = undefined; schedule(ctx); });
  }
  pi.on('session_shutdown', async () => {
    clearTimeout(timer);
    timer = undefined;
    await publisher?.close();
    publisher = undefined;
  });
}
