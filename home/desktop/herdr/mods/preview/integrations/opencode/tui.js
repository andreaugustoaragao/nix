import { createPublisher } from '../session-publisher.mjs';
import { assistantReplies } from '../../lib/replies.mjs';

// OpenCode v2 keeps the selected route and streaming message projection in its TUI.
export default { id: 'personal.herdr-preview', setup };

export async function setup(context) {
  if (!process.env.HC_TERMINAL_ID || !process.env.HC_TERMINAL_SOCKET) return;
  const publisher = createPublisher('opencode');
  let disposed = false, selected, revision = 0, last;
  const current = () => {
    const route = context.ui.router.current();
    return route?.type === 'session' ? route.sessionID : null;
  };
  async function refresh() {
    if (disposed) return;
    const id = current();
    if (id !== selected) {
      selected = id;
      const generation = ++revision;
      last = undefined;
      await publisher.publish({ session: id, cwd: process.cwd(), messages: [] });
      if (id) await context.data.session.message.sync(id);
      if (disposed || generation !== revision || current() !== id) return;
    }
    const source = id ? context.data.session.message.list(id) : [];
    const messages = assistantReplies(source.map(message => ({ ...message, role: message.type, content: message.type === 'user' ? message.text : message.content })));
    const cwd = (id && context.data.session.get(id)?.location?.directory) || process.cwd();
    const value = JSON.stringify({ session: id, cwd, messages });
    if (value === last) return;
    await publisher.publish({ session: id, cwd, messages });
    if (!disposed && current() === id) last = value;
  }
  const update = () => refresh().catch(error => console.warn('Herdr Preview:', error.message));
  const poll = setInterval(update, 250);
  await update();
  return async () => {
    disposed = true;
    revision++;
    clearInterval(poll);
    await publisher.close();
  };
}
