---
name: explore-frontend
version: 1.0.0
description: |
  Adversarial UX review of a running frontend by driving an already-open browser via `dev-browser` + CDP.
  Deterministic evidence-collection pass (screenshots at multiple viewports, DOM outline, console/network
  errors, keyboard-focus walk, a11y spot-checks), followed by a structured defects-and-improvements
  report with severity, location, and proposed fix. Works against any local or remote frontend whose
  tab is already loaded in a Chrome/Brave instance started with `--remote-debugging-port=9222`.
allowed-tools:
  - Bash
  - Read
  - Write
  - Grep
  - Glob
---

# Explore Frontend — Adversarial UX Review

**Goal:** produce a prioritized list of defects and improvements for a running frontend, from the
perspective of a senior UX designer with an adversarial stance. Assume there ARE things wrong —
your job is to find them, not to decide whether to look.

**Hard rules:**
- Read-only against the target app. Never submit forms, delete data, or mutate server state.
- Capture evidence (screenshots + selectors) for every finding. Findings without evidence are rejected.
- Severity must be justified — not every spacing nit is High.

---

## Inputs

The user should provide (or defaults apply):

| Input | Default | Notes |
|---|---|---|
| `CDP_ENDPOINT` | `http://localhost:9222` | Chrome/Brave DevTools Protocol URL |
| `TARGET_URL_CONTAINS` | (ask user) | Substring used to match the correct tab (e.g. `localhost:3100`) |
| `APP_NAME` | inferred from tab title | Used in the report header only |
| `VIEWPORTS` | `1920x1080,1280x800,768x1024,390x844` | Widths to capture. Keep 3–4. |
| `ROUTES` | (single tab) | Optional list of paths/hashes to visit in the same tab |

Ask for any missing required input using AskUserQuestion. If the target tab cannot be
identified unambiguously, STOP and ask.

---

## Step 1 — Preflight (blocking)

Run these checks. If any fails, STOP with a clear fix suggestion.

```bash
# dev-browser must be on PATH
command -v dev-browser >/dev/null 2>&1 || {
  # fall back to known home-manager symlink name
  command -v dev-browser || { echo "dev-browser missing: install via npm i -g dev-browser or add to nix"; exit 1; }
}

# CDP endpoint must answer
curl -fsS "${CDP_ENDPOINT:-http://localhost:9222}/json/version" >/dev/null || {
  echo "No CDP on ${CDP_ENDPOINT:-http://localhost:9222}. Restart browser with --remote-debugging-port=9222"
  exit 1
}

# Working dir for artifacts
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="/tmp/explore-frontend/${RUN_ID}"
mkdir -p "$OUT_DIR"
echo "OUT_DIR=$OUT_DIR"
```

Record `OUT_DIR` and `CDP_ENDPOINT` — every subsequent dev-browser invocation reads them.

---

## Step 2 — Identify the target tab (blocking)

```bash
dev-browser --connect "$CDP_ENDPOINT" --timeout 20 <<'EOF'
const pages = await browser.listPages();
console.log(JSON.stringify(pages, null, 2));
EOF
```

Pick the single page whose `url` contains `TARGET_URL_CONTAINS`. If 0 or >1 match, STOP and ask.
Record the `id` as `TAB_ID`. All later scripts use `browser.getPage(TAB_ID)` so they operate on
the live tab the user already navigated.

**Never call `page.goto()` on the target tab during review** — it would disrupt the user's session
and may lose in-progress state. Navigate by driving links/buttons the same way a user would, and
only if the review explicitly requires it.

---

## Step 3 — Deterministic evidence collection

Run all of these. Save artifacts to `$OUT_DIR`. Findings later cite artifacts by filename.

### 3.1 Full-page screenshots at each viewport

For each `WxH` in `VIEWPORTS`:

```bash
dev-browser --connect "$CDP_ENDPOINT" --timeout 60 <<EOF
const page = await browser.getPage("${TAB_ID}");
await page.setViewportSize({ width: ${W}, height: ${H} });
await page.waitForTimeout(400);  // let responsive layout settle
const buf = await page.screenshot({ fullPage: true });
await saveScreenshot(buf, "vp-${W}x${H}-full.png");

// Above-the-fold only, same viewport
const buf2 = await page.screenshot({ fullPage: false });
await saveScreenshot(buf2, "vp-${W}x${H}-fold.png");
EOF
```

Then copy to `$OUT_DIR`:
```bash
cp ~/.dev-browser/tmp/vp-*.png "$OUT_DIR/"
```

### 3.2 DOM outline + landmark audit

```bash
dev-browser --connect "$CDP_ENDPOINT" --timeout 30 <<'EOF'
const page = await browser.getPage(TAB_ID);
const data = await page.evaluate(() => {
  const walk = (el, depth=0, max=6) => {
    if (depth > max) return '';
    const t = el.tagName?.toLowerCase();
    if (!t || ['script','style','svg','path','g','defs','use','clipPath'].includes(t)) return '';
    const id = el.id ? '#' + el.id : '';
    const cls = (typeof el.className === 'string' && el.className.trim())
      ? '.' + el.className.trim().split(/\s+/).slice(0,2).join('.') : '';
    const role = el.getAttribute('role') ? `[role=${el.getAttribute('role')}]` : '';
    const aria = el.getAttribute('aria-label') ? `[aria="${el.getAttribute('aria-label').slice(0,50)}"]` : '';
    const txt = el.children.length === 0 ? (el.textContent||'').trim().slice(0,60) : '';
    let s = '  '.repeat(depth) + t + id + cls + role + aria + (txt ? ' : ' + txt : '') + '\n';
    for (const c of el.children) s += walk(c, depth+1, max);
    return s;
  };
  // Landmarks audit
  const landmarks = {
    main: document.querySelectorAll('main, [role=main]').length,
    nav: document.querySelectorAll('nav, [role=navigation]').length,
    header: document.querySelectorAll('header, [role=banner]').length,
    footer: document.querySelectorAll('footer, [role=contentinfo]').length,
    h1: document.querySelectorAll('h1').length,
    buttonsNoLabel: Array.from(document.querySelectorAll('button'))
      .filter(b => !b.textContent.trim() && !b.getAttribute('aria-label') && !b.getAttribute('title')).length,
    imgsNoAlt: Array.from(document.querySelectorAll('img')).filter(i => !i.hasAttribute('alt')).length,
    inputsNoLabel: Array.from(document.querySelectorAll('input,textarea,select'))
      .filter(i => !i.labels?.length && !i.getAttribute('aria-label') && !i.getAttribute('aria-labelledby')).length,
  };
  return { outline: walk(document.body).slice(0, 60000), landmarks };
});
await writeFile("structure.txt", data.outline);
await writeFile("landmarks.json", JSON.stringify(data.landmarks, null, 2));
console.log(JSON.stringify(data.landmarks));
EOF
cp ~/.dev-browser/tmp/structure.txt ~/.dev-browser/tmp/landmarks.json "$OUT_DIR/"
```

### 3.3 Console + network errors (live)

Hook into the page's console and network via `page.on()`, then trigger a benign re-render
(e.g., focus/blur the document). Collect for ~5 seconds.

```bash
dev-browser --connect "$CDP_ENDPOINT" --timeout 20 <<'EOF'
const page = await browser.getPage(TAB_ID);
const events = [];
page.on('console', m => events.push({t:'console', type:m.type(), text:m.text().slice(0,500)}));
page.on('pageerror', e => events.push({t:'pageerror', text:String(e).slice(0,500)}));
page.on('requestfailed', r => events.push({t:'requestfailed', url:r.url(), err:r.failure()?.errorText}));
page.on('response', r => { if (r.status() >= 400) events.push({t:'http', status:r.status(), url:r.url()}); });
await page.evaluate(() => { window.dispatchEvent(new Event('focus')); });
await page.waitForTimeout(5000);
await writeFile("events.json", JSON.stringify(events, null, 2));
console.log("events:", events.length);
EOF
cp ~/.dev-browser/tmp/events.json "$OUT_DIR/"
```

### 3.4 Keyboard focus walk

Tabs through up to 30 focusable elements to verify visible focus rings and logical order.

```bash
dev-browser --connect "$CDP_ENDPOINT" --timeout 30 <<'EOF'
const page = await browser.getPage(TAB_ID);
await page.evaluate(() => document.body.focus());
const trail = [];
for (let i = 0; i < 30; i++) {
  await page.keyboard.press('Tab');
  const info = await page.evaluate(() => {
    const a = document.activeElement;
    if (!a) return null;
    const r = a.getBoundingClientRect();
    const cs = getComputedStyle(a);
    return {
      tag: a.tagName.toLowerCase(),
      role: a.getAttribute('role'),
      label: (a.getAttribute('aria-label') || a.textContent || '').trim().slice(0,60),
      rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) },
      outline: cs.outlineStyle + ' ' + cs.outlineWidth + ' ' + cs.outlineColor,
      boxShadow: cs.boxShadow.slice(0, 120),
      visible: r.width > 0 && r.height > 0 && cs.visibility !== 'hidden',
    };
  });
  trail.push(info);
}
await writeFile("focus-trail.json", JSON.stringify(trail, null, 2));
console.log("steps:", trail.length);
EOF
cp ~/.dev-browser/tmp/focus-trail.json "$OUT_DIR/"
```

### 3.5 Contrast spot-check

Sample computed colors vs backgrounds on visible text nodes; flag anything below WCAG AA (4.5:1
for normal text, 3:1 for large). This is a *spot check*, not a full axe audit.

```bash
dev-browser --connect "$CDP_ENDPOINT" --timeout 30 <<'EOF'
const page = await browser.getPage(TAB_ID);
const low = await page.evaluate(() => {
  const toRGB = s => { const m = s.match(/rgba?\(([^)]+)\)/); if (!m) return null;
    const p = m[1].split(',').map(x=>parseFloat(x.trim())); return [p[0],p[1],p[2], p[3]??1]; };
  const lum = ([r,g,b]) => { const f = v => { v/=255; return v<=.03928 ? v/12.92 : Math.pow((v+.055)/1.055,2.4); };
    return .2126*f(r)+.7152*f(g)+.0722*f(b); };
  const ratio = (a,b) => { const L1=lum(a),L2=lum(b); return (Math.max(L1,L2)+.05)/(Math.min(L1,L2)+.05); };
  const resolveBg = el => { while (el && el !== document.body) {
    const c = getComputedStyle(el).backgroundColor; const p = toRGB(c);
    if (p && p[3] > 0.1) return p; el = el.parentElement; } return [255,255,255,1]; };
  const out = [];
  const els = Array.from(document.querySelectorAll('p,span,a,button,label,li,td,th,h1,h2,h3,h4,h5,h6,div'));
  for (const el of els.slice(0, 400)) {
    const txt = (el.innerText || '').trim();
    if (!txt || txt.length < 2) continue;
    const cs = getComputedStyle(el);
    const fg = toRGB(cs.color); if (!fg) continue;
    const bg = resolveBg(el);
    const size = parseFloat(cs.fontSize);
    const bold = parseInt(cs.fontWeight) >= 700;
    const large = size >= 24 || (size >= 18.66 && bold);
    const r = ratio(fg, bg);
    const need = large ? 3 : 4.5;
    if (r < need) {
      const rect = el.getBoundingClientRect();
      out.push({
        ratio: +r.toFixed(2), need, large, text: txt.slice(0, 60),
        fg: cs.color, bg: `rgb(${bg[0]},${bg[1]},${bg[2]})`,
        rect: { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) },
      });
    }
  }
  return out;
});
await writeFile("contrast-low.json", JSON.stringify(low, null, 2));
console.log("low-contrast elements:", low.length);
EOF
cp ~/.dev-browser/tmp/contrast-low.json "$OUT_DIR/"
```

### 3.6 Hit-target sizes

Flag interactive elements smaller than 24x24 (WCAG 2.5.8 minimum) or 44x44 (Apple/recommended).

```bash
dev-browser --connect "$CDP_ENDPOINT" --timeout 20 <<'EOF'
const page = await browser.getPage(TAB_ID);
const small = await page.evaluate(() => {
  const sel = 'button, a[href], [role=button], input:not([type=hidden]), [onclick]';
  const out = [];
  for (const el of document.querySelectorAll(sel)) {
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    if (r.width < 44 || r.height < 44) {
      out.push({
        tag: el.tagName.toLowerCase(),
        label: (el.getAttribute('aria-label') || el.textContent || '').trim().slice(0,60),
        w: Math.round(r.width), h: Math.round(r.height),
        x: Math.round(r.x), y: Math.round(r.y),
      });
    }
  }
  return out.slice(0, 80);
});
await writeFile("hit-targets.json", JSON.stringify(small, null, 2));
console.log("small hit-targets:", small.length);
EOF
cp ~/.dev-browser/tmp/hit-targets.json "$OUT_DIR/"
```

### 3.7 Long-text / overflow stress

Some defects only appear with long content. Skip if you cannot identify an input whose content you
can safely replace. If there is an editable field, snapshot before, fill 500 chars of lorem ipsum,
screenshot, then **restore the original value** (no submit).

---

## Step 4 — Adversarial analysis

For each of the 8 axes below, open `$OUT_DIR` artifacts (Read screenshots, landmarks.json,
focus-trail.json, contrast-low.json, hit-targets.json, events.json) and enumerate findings.
**Every finding gets evidence.**

1. **Visual hierarchy & composition** — misalignments, inconsistent spacing scales, competing
   focal points, things that look clickable but aren't (or vice versa).
2. **Typography & readability** — mixed font families, inconsistent sizes/weights, line-length
   too long/short, cramped line-height, truncation that hides meaningful text.
3. **Color & contrast** — cite `contrast-low.json`. Note semantic color misuse (red for success,
   etc.), insufficient state differentiation (hover/active/focus all look the same).
4. **Affordances & feedback** — icons without tooltips, disabled states that look enabled,
   missing loading/empty/error states, destructive actions without confirmation, no undo path.
5. **Information architecture** — navigation ambiguity, duplicated paths to the same thing,
   dead ends, back behavior, deep-link fragility, where-am-I breadcrumbs.
6. **Accessibility** — cite `landmarks.json` (missing `main`/`h1`), `focus-trail.json` (no
   visible focus ring, illogical order, invisible focused element), inputs without labels,
   buttons without accessible names, keyboard traps.
7. **Content & copy** — jargon, inconsistent capitalization, error messages that blame the
   user, empty states that don't tell you what to do next, ambiguous labels, truncation.
8. **Performance feel & runtime health** — cite `events.json` (console errors, 4xx/5xx,
   `requestfailed`). Missing skeletons, layout shifts, slow-looking interactions, duplicate
   network calls.

---

## Step 5 — Report

Write the report to `$OUT_DIR/REPORT.md` and echo the path. Use this exact schema so downstream
tooling can parse it:

```markdown
# Explore-Frontend Report — <APP_NAME>

Run: <RUN_ID>
Target: <url> (tab <TAB_ID>)
Viewports tested: <list>
Artifacts: <OUT_DIR>

## Summary
- Critical: N
- High: N
- Medium: N
- Low: N
- Nit: N

## Findings

### [SEV] F-001 <short title>
- **Axis:** <1-8 label>
- **Where:** <selector or region> — evidence: `vp-1280x800-fold.png` (x,y,w,h)
- **What:** <one-sentence description of the defect>
- **Why it matters:** <user-visible impact>
- **Proposed fix:** <concrete change, one sentence>

### [SEV] F-002 ...
```

Severity rubric:
- **Critical** — blocks core task, data loss risk, WCAG A failure on primary path.
- **High** — core task workable but painful; WCAG AA failure; misleading affordance.
- **Medium** — friction / polish gap that a new user would notice.
- **Low** — inconsistency only a careful reviewer would spot.
- **Nit** — stylistic; safe to ignore.

Stop after writing the report. Do not attempt fixes in the same run — the user decides what to
pursue. If the user asks for fixes, branch from main and address findings top-down by severity.

---

## Safety & idempotence

- Script runs are read-only. Never call `page.goto()`, never click destructive buttons
  (anything labeled Delete / Remove / Logout / Send / Submit).
- If a finding requires interaction to reproduce (e.g., a dropdown), capture the *before*
  state, perform the minimum interaction, capture the *after* state, and restore with `Escape`
  or a close button. Never leave the tab in a modified state.
- All artifacts land in `$OUT_DIR` and are identified by `RUN_ID` so repeat runs don't clobber.
- `dev-browser`'s sandbox already blocks filesystem escape; paths outside `~/.dev-browser/tmp/`
  will fail — copy to `$OUT_DIR` from the shell after each script block.

---

## Quick one-shot

If you just want to kick the whole thing off with defaults, paste this and fill the two vars:

```bash
TARGET_URL_CONTAINS="localhost:3100"
CDP_ENDPOINT="http://localhost:9222"
# then run Steps 1-5 in order
```
