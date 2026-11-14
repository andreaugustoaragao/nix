import { View, div } from "gpui-kit";
import { spaces, panes, terminals, exec, hc, run, notify, shared, setShared, nextCommand } from "herdr";
import {
  cleanTitle,
  worktreeQualifier,
  isChiefTabName,
  isAgentTerm,
  localHerdrId,
  isPlaceholderTabName,
  desiredTabBaseName,
  desiredSplitBaseLabel,
  dedupeNames,
  truncateLabel,
} from "./rules.js";

const TICK_MS = 1500;
const GIT_TTL_MS = 10000;
const RENAME_COOLDOWN_MS = 2000;
const MAX_SPLITS_PER_WORKER_TAB = 4;
const STORAGE_SPACES = "autoNamer.spaces.v1";
const STORAGE_TABS = "autoNamer.tabs.v1";

const baseName = (path) => String(path ?? "").replace(/\/+$/, "").split("/").pop() || "";

function loadMap(key) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

function saveMap(key, map) {
  try {
    localStorage.setItem(key, JSON.stringify(map));
  } catch {}
}

function spaceCwd(space, allPanes) {
  const tabIds = new Set((space.tabs ?? []).map((t) => t.id));
  return allPanes.find((p) => tabIds.has(p.tab) && p.cwd)?.cwd || space.folder || "";
}

export default class AutoNamer extends View {
  init(_props, cx) {
    this.gitCache = new Map();
    this.lastActionAt = new Map();
    this.warnedDuplicates = new Set();
    this.pendingTabForChild = new Map();
    this.autoSpaces = loadMap(STORAGE_SPACES);
    this.autoTabs = loadMap(STORAGE_TABS);
    this.busy = false;
    this.lastRun = 0;

    cx.timer.every(TICK_MS, (cx) => this.tick(cx));
    cx.spawn(async (cx) => {
      for (;;) {
        const cmd = await nextCommand();
        if (cmd === "toggle") {
          const paused = Boolean(shared("autoNamer.paused"));
          setShared("autoNamer.paused", !paused);
          if (paused) this.tick(cx, true);
        } else if (cmd === "recheck") {
          this.gitCache.clear();
          this.tick(cx, true);
        }
      }
    });
    this.tick(cx, true);
  }

  canAct(key, now) {
    const prev = this.lastActionAt.get(key) ?? 0;
    if (now - prev < RENAME_COOLDOWN_MS) return false;
    this.lastActionAt.set(key, now);
    return true;
  }

  async resolveGit(machine, cwd, now) {
    if (!cwd) return null;
    const key = JSON.stringify([machine ?? null, cwd]);
    const cached = this.gitCache.get(key);
    if (cached && now - cached.at < GIT_TTL_MS) return cached.value;

    try {
      const [topRes, commonRes] = await Promise.all([
        exec("git", ["rev-parse", "--path-format=absolute", "--show-toplevel"], { cwd, on: machine }),
        exec("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], { cwd, on: machine }),
      ]);
      if (topRes.code !== 0 || commonRes.code !== 0) {
        const value = null;
        this.gitCache.set(key, { at: now, value });
        return value;
      }
      const top = topRes.stdout.trim();
      const common = commonRes.stdout.trim();
      const branchRes = await exec("git", ["symbolic-ref", "-q", "HEAD"], { cwd, on: machine });
      const branch = branchRes.code === 0 ? branchRes.stdout.trim().replace(/^refs\/heads\//, "") : "";
      const repoName = common.endsWith("/.git")
        ? baseName(common.slice(0, -5))
        : baseName(common).replace(/\.git$/, "");
      const value = {
        name: repoName,
        top,
        topName: baseName(top),
        common,
        branch,
        linked: common !== `${top}/.git`,
      };
      this.gitCache.set(key, { at: now, value });
      return value;
    } catch {
      return cached?.value ?? null;
    }
  }

  tick(cx, force = false) {
    if (shared("autoNamer.paused")) return;
    const now = Date.now();
    if (!force && (this.busy || now - this.lastRun < 900)) return;
    this.busy = true;
    this.lastRun = now;
    cx.spawn(async () => {
      try {
        await this.reconcile(Date.now());
      } finally {
        this.busy = false;
      }
    });
  }

  async enforceChiefOfStaff(sp, ps, allTerms, termByAddr, paneByTerm, panesByTab, now) {
    const chiefTabBySpace = new Map();
    const liveTerms = allTerms.filter((t) => t.state === "live");

    for (const s of sp) {
      const tabs = s.tabs ?? [];
      const tabSet = new Set(tabs.map((t) => t.id));
      const spacePanes = ps.filter((p) => tabSet.has(p.tab));

      let chiefTerm = null;
      let chiefTab = null;

      // 1. Explicit herdr.role=chief-of-staff or name=chief-of-staff terminal in this space.
      for (const p of spacePanes) {
        if (!p.terminal) continue;
        const term = termByAddr.get(p.terminal);
        if (!term) continue;
        if (
          term.labels?.["herdr.role"] === "chief-of-staff" ||
          term.labels?.["herdr.name"] === "chief-of-staff" ||
          term.name === "chief-of-staff"
        ) {
          chiefTerm = term;
          chiefTab = tabs.find((t) => t.id === p.tab) ?? null;
          break;
        }
      }

      // 2. Existing tab named chief-of-staff / Chief of staff.
      if (!chiefTab) {
        chiefTab = tabs.find((t) => isChiefTabName(t.name)) ?? null;
        if (chiefTab) {
          const lead = (panesByTab.get(chiefTab.id) ?? []).find((p) => p.terminal && isAgentTerm(termByAddr.get(p.terminal), p));
          if (lead) chiefTerm = termByAddr.get(lead.terminal) ?? null;
        }
      }

      // 3. Agent terminal in this space that has live child agents.
      if (!chiefTab) {
        for (const p of spacePanes) {
          if (!p.terminal) continue;
          const term = termByAddr.get(p.terminal);
          if (!isAgentTerm(term, p)) continue;
          const hasChildAgent = liveTerms.some((k) => k.parent === term.address && isAgentTerm(k, paneByTerm.get(k.address)));
          if (hasChildAgent) {
            chiefTerm = term;
            chiefTab = tabs.find((t) => t.id === p.tab) ?? null;
            break;
          }
        }
      }

      if (!chiefTab) continue;
      chiefTabBySpace.set(s.id, chiefTab.id);

      // Ensure the single coordinator tab is literally named "chief-of-staff".
      if (chiefTab.name !== "chief-of-staff" && this.canAct(`tb:${chiefTab.id}`, now)) {
        this.autoTabs[chiefTab.id] = "chief-of-staff";
        run("tab.rename", { id: chiefTab.id, name: "chief-of-staff" });
      }

      // Tag the chief terminal with herdr.role=chief-of-staff.
      if (chiefTerm && chiefTerm.labels?.["herdr.role"] !== "chief-of-staff" && this.canAct(`role:${chiefTerm.address}`, now)) {
        await hc(["label", chiefTerm.address, "herdr.role=chief-of-staff"]).catch(() => null);
      }

      // Prevent duplicate chief-of-staff tabs in the same space.
      for (const tab of tabs) {
        if (tab.id !== chiefTab.id && isChiefTabName(tab.name) && this.canAct(`dup:${tab.id}`, now)) {
          delete this.autoTabs[tab.id];
          run("tab.rename", { id: tab.id, name: "" });
          if (!this.warnedDuplicates.has(tab.id)) {
            this.warnedDuplicates.add(tab.id);
            notify({
              title: "Single chief-of-staff per space",
              body: `Space "${s.name}" already has a chief-of-staff tab.`,
              level: "warning",
              timeout: 6000,
            });
          }
        }
      }

      if (!chiefTerm) continue;

      // Enforce all child agents of chiefTerm open on other tabs with up to 4 splits per tab.
      const childAgents = liveTerms.filter((k) => k.parent === chiefTerm.address && isAgentTerm(k, paneByTerm.get(k.address)));
      if (!childAgents.length) continue;

      const workerTabs = tabs.filter((t) => t.id !== chiefTab.id);
      const workerCounts = new Map(workerTabs.map((t) => [t.id, (panesByTab.get(t.id) ?? []).length]));
      const childAddrSet = new Set(childAgents.map((k) => k.address));
      const tabsWithChildren = new Set(
        workerTabs
          .filter((t) => (panesByTab.get(t.id) ?? []).some((p) => p.terminal && childAddrSet.has(p.terminal)))
          .map((t) => t.id),
      );

      let nextSeq = 1;
      const machinePrefix = s.machine ? `${s.machine}/` : "";
      const freshTabId = () => {
        for (;;) {
          const local = `tbwk${chiefTerm.address}_${nextSeq++}`;
          const full = `${machinePrefix}${local}`;
          if (!tabSet.has(full) && !workerCounts.has(full)) return full;
        }
      };

      const pickWorkerTab = () => {
        for (const t of workerTabs) {
          if (tabsWithChildren.has(t.id) && (workerCounts.get(t.id) ?? 0) < MAX_SPLITS_PER_WORKER_TAB) {
            return t.id;
          }
        }
        for (const [id, cnt] of workerCounts.entries()) {
          if (cnt < MAX_SPLITS_PER_WORKER_TAB && id !== chiefTab.id && tabs.every((t) => t.id !== id || tabsWithChildren.has(t.id) || cnt === 0)) {
            return id;
          }
        }
        const id = freshTabId();
        workerCounts.set(id, 0);
        tabsWithChildren.add(id);
        return id;
      };

      for (const child of childAgents) {
        const pane = paneByTerm.get(child.address);
        if (pane) {
          this.pendingTabForChild.delete(child.address);
          const count = workerCounts.get(pane.tab) ?? (panesByTab.get(pane.tab) ?? []).length;
          if (pane.tab === chiefTab.id || (pane.tab !== chiefTab.id && count > MAX_SPLITS_PER_WORKER_TAB)) {
            if (this.canAct(`park:${child.address}`, now)) {
              if (pane.tab !== chiefTab.id) workerCounts.set(pane.tab, count - 1);
              run("terminal.park", { terminal: child.address });
            }
          }
          continue;
        }

        // Child is currently unpaned: adopt into a worker tab (<= 4 splits per tab).
        let targetTab = this.pendingTabForChild.get(child.address);
        if (!targetTab || (workerCounts.get(targetTab) ?? 0) >= MAX_SPLITS_PER_WORKER_TAB) {
          targetTab = pickWorkerTab();
          this.pendingTabForChild.set(child.address, targetTab);
        }
        workerCounts.set(targetTab, (workerCounts.get(targetTab) ?? 0) + 1);
        tabsWithChildren.add(targetTab);

        const wantSpace = localHerdrId(s.id);
        const wantTab = localHerdrId(targetTab);
        if (
          (child.labels?.["herdr.space"] !== wantSpace || child.labels?.["herdr.tab"] !== wantTab) &&
          this.canAct(`adopt:${child.address}`, now)
        ) {
          await hc(["label", child.address, `herdr.space=${wantSpace}`, `herdr.tab=${wantTab}`]).catch(() => null);
        }
      }
    }

    return chiefTabBySpace;
  }

  async reconcile(now) {
    const sp = spaces();
    const ps = panes();
    const allTerms = terminals();
    const termByAddr = new Map(allTerms.map((t) => [t.address, t]));
    const paneByTerm = new Map(ps.filter((p) => p.terminal).map((p) => [p.terminal, p]));

    const liveSpaceIds = new Set(sp.map((s) => s.id));
    const liveTabIds = new Set(sp.flatMap((s) => (s.tabs ?? []).map((t) => t.id)));
    let spacesDirty = false;
    let tabsDirty = false;
    for (const id of Object.keys(this.autoSpaces)) {
      if (!liveSpaceIds.has(id)) {
        delete this.autoSpaces[id];
        spacesDirty = true;
      }
    }
    for (const id of Object.keys(this.autoTabs)) {
      if (!liveTabIds.has(id)) {
        delete this.autoTabs[id];
        tabsDirty = true;
      }
    }

    const panesByTab = new Map();
    for (const p of ps) {
      if (!panesByTab.has(p.tab)) panesByTab.set(p.tab, []);
      panesByTab.get(p.tab).push(p);
    }

    // 0. Enforce single chief-of-staff tab per space & child agents in worker tabs (<= 4 splits).
    const chiefTabBySpace = await this.enforceChiefOfStaff(sp, ps, allTerms, termByAddr, paneByTerm, panesByTab, now);

    const spaceCwds = new Map(sp.map((s) => [s.id, spaceCwd(s, ps)]));
    const gitBySpace = new Map();
    await Promise.all(
      sp.map(async (s) => {
        const cwd = spaceCwds.get(s.id);
        gitBySpace.set(s.id, await this.resolveGit(s.machine ?? null, cwd, now));
      }),
    );

    // 1. Auto-name spaces (never overwrite manual space names).
    const spaceAutoAllowed = new Map();
    const spaceBaseDesired = new Map();
    for (const s of sp) {
      const manual = s.named && s.name !== this.autoSpaces[s.id];
      spaceAutoAllowed.set(s.id, !manual);
      const git = gitBySpace.get(s.id);
      if (git?.linked) {
        const qual = worktreeQualifier(git);
        spaceBaseDesired.set(s.id, truncateLabel(qual ? `${git.name} · ${qual}` : git.name, 36));
      } else if (git?.name) {
        spaceBaseDesired.set(s.id, git.name);
      } else {
        spaceBaseDesired.set(s.id, baseName(spaceCwds.get(s.id)) || "~");
      }
    }

    const spaceCounts = new Map();
    for (const s of sp) {
      const effective = spaceAutoAllowed.get(s.id) ? spaceBaseDesired.get(s.id) : s.name;
      spaceCounts.set(effective, (spaceCounts.get(effective) ?? 0) + 1);
    }

    const spaceSeen = new Map();
    for (const s of sp) {
      if (!spaceAutoAllowed.get(s.id)) continue;
      const git = gitBySpace.get(s.id);
      const base = spaceBaseDesired.get(s.id);
      const count = spaceCounts.get(base) ?? 0;
      const idx = (spaceSeen.get(base) ?? 0) + 1;
      spaceSeen.set(base, idx);

      let want = null;
      if (git?.linked) {
        want = count > 1 && idx > 1 ? `${base} (${idx})` : base;
      } else if (count > 1 && idx > 1) {
        const activeTab = (s.tabs ?? []).find((t) => t.active) ?? s.tabs?.[0];
        const hint = activeTab
          ? desiredTabBaseName({
              tab: activeTab,
              space: s,
              spaceGit: git,
              panesInTab: panesByTab.get(activeTab.id) ?? [],
              termByAddr,
            })
          : "";
        want = truncateLabel(hint && hint !== base ? `${base} · ${hint}` : `${base} (${idx})`, 36);
      } else if (s.named && s.name === this.autoSpaces[s.id]) {
        want = "";
      }

      if (want === null) continue;
      if (want === "") {
        if (s.named && this.canAct(`sp:${s.id}`, now)) {
          delete this.autoSpaces[s.id];
          spacesDirty = true;
          run("space.rename", { id: s.id, name: "" });
        }
      } else if (s.name !== want && this.canAct(`sp:${s.id}`, now)) {
        this.autoSpaces[s.id] = want;
        spacesDirty = true;
        run("space.rename", { id: s.id, name: want });
      }
    }

    // 2. Auto-name tabs per space (never overwrite manual tab names or chief-of-staff).
    for (const s of sp) {
      const spaceGit = gitBySpace.get(s.id);
      const chiefTabId = chiefTabBySpace.get(s.id);
      const tabs = s.tabs ?? [];
      const manualNames = new Set();
      const autoTabsInSpace = [];

      for (const tab of tabs) {
        if (tab.id === chiefTabId) {
          manualNames.add("chief-of-staff");
          continue;
        }
        const placeholder = !tab.named || isPlaceholderTabName(tab.name);
        const ownedByAuto = tab.named && tab.name === this.autoTabs[tab.id];
        if (!placeholder && !ownedByAuto) {
          manualNames.add(tab.name);
          continue;
        }
        autoTabsInSpace.push(tab);
      }

      const rawDesired = new Map();
      for (const tab of autoTabsInSpace) {
        const name = desiredTabBaseName({
          tab,
          space: s,
          spaceGit,
          panesInTab: panesByTab.get(tab.id) ?? [],
          termByAddr,
        });
        if (name) rawDesired.set(tab.id, name);
      }

      const counts = new Map();
      for (const name of manualNames) counts.set(name, 1);
      for (const tab of autoTabsInSpace) {
        const b = rawDesired.get(tab.id);
        if (b) counts.set(b, (counts.get(b) ?? 0) + 1);
      }

      const seen = new Map();
      for (const name of manualNames) seen.set(name, 1);
      for (const tab of autoTabsInSpace) {
        const b = rawDesired.get(tab.id);
        if (!b) continue;
        let finalName = b;
        if ((counts.get(b) ?? 0) > 1) {
          const n = (seen.get(b) ?? 0) + 1;
          seen.set(b, n);
          if (n > 1 || manualNames.has(b)) finalName = `${b} (${n})`;
        }
        if (tab.name !== finalName && this.canAct(`tb:${tab.id}`, now)) {
          this.autoTabs[tab.id] = finalName;
          tabsDirty = true;
          run("tab.rename", { id: tab.id, name: finalName });
        }
      }
    }

    // 3. Auto-label unnamed terminal splits (sets herdr.auto_name via hc label).
    for (const s of sp) {
      const spaceGit = gitBySpace.get(s.id);
      for (const tab of s.tabs ?? []) {
        const tabPanes = panesByTab.get(tab.id) ?? [];
        const labeled = tabPanes
          .filter((p) => p.terminal && termByAddr.has(p.terminal))
          .map((p) => ({
            id: p.pane,
            pane: p,
            term: termByAddr.get(p.terminal),
          }));

        const deduped = dedupeNames(labeled, (item) =>
          desiredSplitBaseLabel({
            pane: item.pane,
            term: item.term,
            space: s,
            spaceGit,
          }),
        );

        for (const item of labeled) {
          const want = deduped.get(item.id);
          if (!want) continue;
          const current = cleanTitle(item.term.labels?.["herdr.auto_name"] ?? "");
          if (current !== want && this.canAct(`term:${item.term.address}`, now)) {
            await hc(["label", item.term.address, `herdr.auto_name=${want}`]).catch(() => null);
          }
        }
      }
    }

    if (spacesDirty) saveMap(STORAGE_SPACES, this.autoSpaces);
    if (tabsDirty) saveMap(STORAGE_TABS, this.autoTabs);
  }

  render() {
    return div().size(0);
  }
}
