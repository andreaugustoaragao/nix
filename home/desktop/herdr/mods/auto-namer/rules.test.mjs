import test from "node:test";
import assert from "node:assert/strict";
import { LEAD_TAB_NAME, cleanTitle, isGenericTitle, isLeadTabName, selectLeadTab } from "./rules.js";

function makeInput({ tabs, panes, terms }) {
  const termByAddr = new Map(terms.map((t) => [t.address, t]));
  const paneByTerm = new Map(panes.filter((p) => p.terminal).map((p) => [p.terminal, p]));
  const panesByTab = new Map();
  for (const p of panes) {
    if (!panesByTab.has(p.tab)) panesByTab.set(p.tab, []);
    panesByTab.get(p.tab).push(p);
  }
  return { tabs, spacePanes: panes, liveTerms: terms, termByAddr, paneByTerm, panesByTab };
}

test("fresh space with a single unlabeled agent on tab 0 promotes tab 0 to lead", () => {
  const input = makeInput({
    tabs: [{ id: "tb1", name: "1", named: false }],
    panes: [{ id: "p1", tab: "tb1", terminal: "t1", program: { name: "omp", agent: true } }],
    terms: [{ address: "t1", state: "live", labels: {}, argv: ["omp"] }],
  });
  const { leadTab, leadTerm } = selectLeadTab(input);
  assert.equal(leadTab?.id, "tb1");
  assert.equal(leadTerm?.address, "t1");
});

test("fresh space with only a plain shell on tab 0 is not promoted to lead", () => {
  const input = makeInput({
    tabs: [{ id: "tb1", name: "1", named: false }],
    panes: [{ id: "p1", tab: "tb1", terminal: "t1", program: { name: "fish", agent: false } }],
    terms: [{ address: "t1", state: "live", labels: {}, argv: ["fish"] }],
  });
  const { leadTab, leadTerm } = selectLeadTab(input);
  assert.equal(leadTab, null);
  assert.equal(leadTerm, null);
});

test("explicit herdr.role=lead takes precedence over tab 0", () => {
  const input = makeInput({
    tabs: [
      { id: "tb1", name: "Review", named: true },
      { id: "tb2", name: "2", named: false },
    ],
    panes: [
      { id: "p1", tab: "tb1", terminal: "t1", program: { name: "omp", agent: true } },
      { id: "p2", tab: "tb2", terminal: "t2", program: { name: "codex", agent: true } },
    ],
    terms: [
      { address: "t1", state: "live", labels: {}, argv: ["omp"] },
      { address: "t2", state: "live", labels: { "herdr.role": LEAD_TAB_NAME }, argv: ["codex"] },
    ],
  });
  const { leadTab, leadTerm } = selectLeadTab(input);
  assert.equal(leadTab?.id, "tb2");
  assert.equal(leadTerm?.address, "t2");
});

test("legacy chief-of-staff tab and label are recognized for migration to lead", () => {
  assert.equal(isLeadTabName("lead"), true);
  assert.equal(isLeadTabName("chief-of-staff"), true);
  assert.equal(isLeadTabName("Chief of Staff"), true);
  assert.equal(isLeadTabName("Auth review"), false);

  const input = makeInput({
    tabs: [
      { id: "tb1", name: "Auth review", named: true },
      { id: "tb2", name: "chief-of-staff", named: true },
    ],
    panes: [
      { id: "p1", tab: "tb1", terminal: "t1", program: { name: "omp", agent: true } },
      { id: "p2", tab: "tb2", terminal: "t2", program: { name: "omp", agent: true } },
    ],
    terms: [
      { address: "t1", state: "live", labels: {}, argv: ["omp"] },
      { address: "t2", state: "live", labels: { "herdr.role": "chief-of-staff" }, argv: ["omp"] },
    ],
  });
  const { leadTab, leadTerm } = selectLeadTab(input);
  assert.equal(leadTab?.id, "tb2");
  assert.equal(leadTerm?.address, "t2");
});

test("agent with live child agents is selected as lead even if not on tab 0", () => {
  const input = makeInput({
    tabs: [
      { id: "tb1", name: "Shell", named: true },
      { id: "tb2", name: "Work", named: true },
    ],
    panes: [
      { id: "p1", tab: "tb1", terminal: "t1", program: { name: "fish", agent: false } },
      { id: "p2", tab: "tb2", terminal: "t2", program: { name: "omp", agent: true } },
    ],
    terms: [
      { address: "t1", state: "live", labels: {}, argv: ["fish"] },
      { address: "t2", state: "live", labels: {}, argv: ["omp"] },
      { address: "t3", state: "live", parent: "t2", labels: {}, argv: ["codex"] },
    ],
  });
  const { leadTab, leadTerm } = selectLeadTab(input);
  assert.equal(leadTab?.id, "tb2");
  assert.equal(leadTerm?.address, "t2");
});

test("fresh-space tab-0 fallback never overwrites a manually named tab", () => {
  const input = makeInput({
    tabs: [{ id: "tb1", name: "Auth review", named: true }],
    panes: [{ id: "p1", tab: "tb1", terminal: "t1", program: { name: "omp", agent: true } }],
    terms: [{ address: "t1", state: "live", labels: {}, argv: ["omp"] }],
  });
  const { leadTab, leadTerm } = selectLeadTab({ ...input, autoTabs: {} });
  assert.equal(leadTab, null);
  assert.equal(leadTerm, null);
});

test("fresh-space tab-0 fallback promotes an auto-named tab hosting an agent", () => {
  const input = makeInput({
    tabs: [{ id: "tb1", name: "omp · main", named: true }],
    panes: [{ id: "p1", tab: "tb1", terminal: "t1", program: { name: "omp", agent: true } }],
    terms: [{ address: "t1", state: "live", labels: {}, argv: ["omp"] }],
  });
  const { leadTab, leadTerm } = selectLeadTab({ ...input, autoTabs: { tb1: "omp · main" } });
  assert.equal(leadTab?.id, "tb1");
  assert.equal(leadTerm?.address, "t1");
});

test("cleanTitle normalizes OMP working, idle (>), attention (!), and bare π states identically", () => {
  for (const variant of [
    "π ⠋ Fix auth flow",
    "π ⠙ Fix auth flow",
    "π > Fix auth flow",
    "π ! Fix auth flow",
    "π: Fix auth flow",
    "π : Fix auth flow",
    "π Fix auth flow",
    "⠋ Fix auth flow",
  ]) {
    assert.equal(cleanTitle(variant), "Fix auth flow", `variant: ${variant}`);
  }
  assert.equal(cleanTitle("π 󰊪 ARCH: Vault v2"), "󰊪 ARCH: Vault v2");
  for (const bare of ["π", "π >", "π !", "π ⠋"]) {
    assert.equal(isGenericTitle(bare, { name: "omp" }), true, `bare: ${bare}`);
  }
});
