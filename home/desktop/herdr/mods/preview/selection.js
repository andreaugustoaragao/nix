// Focused terminals win. A panel click retains that tab's last selected agent.
export function selectedAgent(focus, agents, remembered, { terminals = [], panes = [] } = {}) {
  agents = [...agents];
  for (const terminal of terminals) {
    if (agents.some(agent => agent.address === terminal.address)) continue;
    let binding;
    try { binding = JSON.parse(terminal.labels?.["herdr-preview.session"] || "null"); } catch { continue; }
    if (binding?.version !== 1 || !["pi", "opencode"].includes(binding.agent)) continue;
    const pane = panes.find(pane => pane.terminal === terminal.address);
    if (pane) agents.push({ ...pane, address: terminal.address, app: binding.agent });
  }
  if (!focus) return null;
  const terminal = focus.shown || focus.terminal;
  const direct = agents.find(agent => agent.address === terminal);
  if (direct) return direct;
  // A focused shell is not an agent, even if the agent-block selection is stale.
  if (terminal) return null;
  const candidates = agents.filter(agent => agent.tab === focus.tab);
  return candidates.find(agent => agent.address === remembered)
    || candidates.find(agent => agent.address === focus.agent)
    || candidates.find(agent => agent.focused)
    || (candidates.length === 1 ? candidates[0] : null);
}
