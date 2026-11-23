const GENERIC_TITLES = new Set([
  "terminal",
  "shell",
  "fish",
  "zsh",
  "bash",
  "sh",
  "nu",
  "nushell",
  "codex",
  "pi",
  "pi-task",
  "π",
  "omp",
  "cursor",
  "cursor-agent",
  "grok",
  "gemini",
  "qwen",
]);

export function cleanTitle(raw) {
  if (!raw) return "";
  return String(raw)
    .replace(/^\s*π(?:\s*[:·•>!|-]+(?:\s+|$)|\s+)/u, "")
    .replace(/^[\s\u2800-\u28FF●○◉·•▸▹►▻◆◇▪▫★☆✦✧⚡✓✔✕✖⚠⏳⌛🔄>!]+(?:\s+|$)/u, "")
    .replace(/\s+/g, " ")
    .trim();
}

export function isGenericTitle(rawTitle, program) {
  const raw = String(rawTitle ?? "").trim();
  const strippedLeading = raw.replace(/^[^\p{L}\p{N}~/]+/u, "");
  if (!strippedLeading) return true;
  if (/^[~/]|^[A-Za-z]:\\/.test(strippedLeading)) return true;
  if (/^[^\s@]+@[^\s@]+/.test(strippedLeading)) return true;

  const cleaned = cleanTitle(raw);
  if (!cleaned) return true;
  const lower = cleaned.toLowerCase();
  if (GENERIC_TITLES.has(lower)) return true;
  if (program?.name && lower === program.name.toLowerCase()) return true;
  if (program?.key && lower === program.key.toLowerCase()) return true;
  return false;
}

export function truncateLabel(text, max = 32) {
  const s = String(text ?? "").trim();
  if (s.length <= max) return s;
  return s.slice(0, Math.max(1, max - 1)).trimEnd() + "…";
}

export function shortBranch(branch) {
  const b = String(branch ?? "").trim();
  if (!b || b === "main" || b === "master" || b === "(detached)" || b === "HEAD") return "";
  return b;
}

export function relativeSubdir(cwd, root) {
  if (!cwd || !root) return "";
  const cleanCwd = cwd.replace(/\/+$/, "");
  const cleanRoot = root.replace(/\/+$/, "");
  if (!cleanCwd || !cleanRoot || cleanCwd === cleanRoot) return "";
  if (!cleanCwd.startsWith(cleanRoot + "/")) return "";
  const rel = cleanCwd.slice(cleanRoot.length + 1);
  const parts = rel.split("/").filter(Boolean);
  if (!parts.length) return "";
  return parts.length <= 2 ? parts.join("/") : parts.slice(-2).join("/");
}

export const LEAD_TAB_NAME = "lead";

export function isLeadTabName(name) {
  return /^(?:lead|chief[- ]of[- ]staff)$/i.test(String(name ?? "").trim());
}

export function isAgentTerm(term, pane) {
  if (!term) return false;
  if (pane?.program?.agent || term.program?.agent || term.app || term.report?.app || term.template) {
    return true;
  }
  const cmd = Array.isArray(term.argv) ? term.argv.join(" ") : "";
  return /\b(herdr-cursor|cursor-agent|codex|omp|pi(?:-task)?|gemini|grok)\b/i.test(cmd);
}

export function selectLeadTab({ tabs, spacePanes, liveTerms, termByAddr, paneByTerm, panesByTab, autoTabs }) {
  if (!tabs?.length) return { leadTab: null, leadTerm: null };

  // 1. Explicit herdr.role=lead (or legacy chief-of-staff) / explicit name.
  for (const p of spacePanes) {
    if (!p.terminal) continue;
    const term = termByAddr.get(p.terminal);
    if (!term) continue;
    const role = term.labels?.["herdr.role"];
    const labelName = term.labels?.["herdr.name"];
    if (
      role === LEAD_TAB_NAME ||
      role === "chief-of-staff" ||
      isLeadTabName(labelName) ||
      isLeadTabName(term.name)
    ) {
      return { leadTab: tabs.find((t) => t.id === p.tab) ?? null, leadTerm: term };
    }
  }

  // 2. Existing tab named lead (or legacy chief-of-staff).
  const namedLead = tabs.find((t) => isLeadTabName(t.name)) ?? null;
  if (namedLead) {
    const leadPane = (panesByTab.get(namedLead.id) ?? []).find(
      (p) => p.terminal && isAgentTerm(termByAddr.get(p.terminal), p),
    );
    return { leadTab: namedLead, leadTerm: leadPane ? termByAddr.get(leadPane.terminal) ?? null : null };
  }

  // 3. Agent terminal in this space that has live child agents.
  for (const p of spacePanes) {
    if (!p.terminal) continue;
    const term = termByAddr.get(p.terminal);
    if (!isAgentTerm(term, p)) continue;
    const hasChildAgent = liveTerms.some(
      (k) => k.parent === term.address && isAgentTerm(k, paneByTerm.get(k.address)),
    );
    if (hasChildAgent) {
      return { leadTab: tabs.find((t) => t.id === p.tab) ?? null, leadTerm: term };
    }
  }

  // 4. Fresh-space fallback: promote the first tab (index 0) when it hosts an agent terminal
  //    and is unnamed, placeholder-named, or auto-owned (never overwrite user-named tabs).
  const firstTab = tabs[0];
  const firstPlaceholder = !firstTab.named || isPlaceholderTabName(firstTab.name);
  const firstOwnedByAuto = Boolean(firstTab.named && autoTabs && firstTab.name === autoTabs[firstTab.id]);
  if (firstPlaceholder || firstOwnedByAuto) {
    const firstAgentPane = (panesByTab.get(firstTab.id) ?? []).find(
      (p) => p.terminal && isAgentTerm(termByAddr.get(p.terminal), p),
    );
    if (firstAgentPane) {
      return { leadTab: firstTab, leadTerm: termByAddr.get(firstAgentPane.terminal) ?? null };
    }
  }

  return { leadTab: null, leadTerm: null };
}

export function localHerdrId(id) {
  const s = String(id ?? "").trim();
  const idx = s.lastIndexOf("/");
  return idx >= 0 ? s.slice(idx + 1) : s;
}

export function isPlaceholderTabName(name) {
  const s = String(name ?? "").trim();
  return !s || /^\d+$/.test(s) || /^tb\d+$/.test(s);
}

export function worktreeQualifier(git) {
  if (!git?.linked) return "";
  const branch = shortBranch(git.branch);
  if (branch) return branch;
  const top = String(git.topName ?? "").trim();
  const repo = String(git.name ?? "").trim();
  if (!top) return "";
  if (repo && top.toLowerCase().startsWith(repo.toLowerCase() + "-")) {
    return top.slice(repo.length + 1);
  }
  return top !== repo ? top : "";
}

export function pickLeadPane(panesInTab) {
  if (!panesInTab?.length) return null;
  return (
    panesInTab.find((p) => p.focused && p.program?.agent) ||
    panesInTab.find((p) => p.program?.agent) ||
    panesInTab.find((p) => p.focused) ||
    panesInTab[0]
  );
}

export function desiredTabBaseName({ tab, space, spaceGit, panesInTab, termByAddr }) {
  if (!panesInTab?.length) return null;
  const lead = pickLeadPane(panesInTab);
  if (!lead) return null;

  if (!lead.terminal && lead.mod) {
    return truncateLabel(lead.title || lead.mod, 32);
  }

  const term = lead.terminal ? termByAddr.get(lead.terminal) : null;
  const explicit = cleanTitle(term?.labels?.["herdr.name"] || term?.name || "");
  if (explicit) return truncateLabel(explicit, 32);

  const osc = cleanTitle(lead.title);
  if (osc && !isGenericTitle(lead.title, lead.program)) {
    return truncateLabel(osc, 32);
  }

  const prog = lead.program?.name || "Terminal";
  const branch = shortBranch(lead.branch);
  const spaceLower = String(space?.name ?? "").toLowerCase();
  const branchRedundant =
    !branch ||
    branch.toLowerCase() === spaceLower ||
    spaceLower.includes(`· ${branch.toLowerCase()}`);

  const root = spaceGit?.top || space?.folder;
  const subdir = relativeSubdir(lead.cwd, root);
  const context = !branchRedundant ? branch : subdir || (panesInTab.length > 1 ? `${panesInTab.length} panes` : "");

  return truncateLabel(context ? `${prog} · ${context}` : prog, 32);
}

export function desiredSplitBaseLabel({ pane, term, space, spaceGit }) {
  if (!pane?.terminal || !term) return null;
  if (term.name || term.labels?.["herdr.name"]) return null;

  const osc = cleanTitle(pane.title);
  if (osc && !isGenericTitle(pane.title, pane.program)) {
    return truncateLabel(osc, 28);
  }

  const rawKey = pane.program?.key;
  const prog =
    rawKey && rawKey !== "program" && rawKey !== "shell"
      ? rawKey
      : (pane.program?.name || "shell").toLowerCase().replace(/\s+/g, "-");

  const branch = shortBranch(pane.branch);
  const spaceLower = String(space?.name ?? "").toLowerCase();
  const branchRedundant =
    !branch ||
    branch.toLowerCase() === spaceLower ||
    spaceLower.includes(`· ${branch.toLowerCase()}`);

  const root = spaceGit?.top || space?.folder;
  const subdir = relativeSubdir(pane.cwd, root);
  const context = subdir || (!branchRedundant ? branch : "");

  return truncateLabel(context ? `${context}:${prog}` : prog, 28);
}

export function dedupeNames(items, getBase) {
  const counts = new Map();
  const out = new Map();
  for (const item of items) {
    const base = getBase(item);
    if (!base) continue;
    const n = (counts.get(base) ?? 0) + 1;
    counts.set(base, n);
  }
  const seen = new Map();
  for (const item of items) {
    const base = getBase(item);
    if (!base) continue;
    if ((counts.get(base) ?? 0) <= 1) {
      out.set(item.id, base);
    } else {
      const idx = (seen.get(base) ?? 0) + 1;
      seen.set(base, idx);
      out.set(item.id, idx === 1 ? base : `${base} (${idx})`);
    }
  }
  return out;
}
