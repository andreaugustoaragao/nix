---
name: "source-command-explore-frontend"
description: "Adversarial UX review of a running frontend by driving a managed browser-task page.
Deterministic evidence-collection pass (screenshots at multiple viewports, DOM outline,
resource timing, keyboard-focus walk, a11y spot-checks), followed by a structured defects-and-improvements
report with severity, location, and proposed fix. Works against any local or remote frontend whose
page is opened in the managed development browser with explicit task ownership."
---

# source-command-explore-frontend

Use this skill when the user asks to run the migrated source command `explore-frontend`.

## Command Template

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
| `TASK` | create a task | Existing owned task UUID, if continuing a review |
| `PAGE` | `main` | Owned page name within the task |
| `TARGET_URL` | infer from context or ask | Full URL to open when starting a task |
| `APP_NAME` | inferred from tab title | Used in the report header only |
| `VIEWPORTS` | `1920x1080,1280x800,768x1024,390x844` | Widths to capture. Keep 3–4. |
| `ROUTES` | (single tab) | Optional list of paths/hashes to visit in the same tab |

Resolve the URL from the request or project context. Ask if it remains ambiguous.
Use an existing task only when it belongs to this review; never choose an everyday browser tab.

---

## Step 1 — Preflight (blocking)

Run these checks. If any fails, STOP with a clear fix suggestion.

```bash
set -euo pipefail
command -v browser-task >/dev/null || {
  echo "browser-task is unavailable; activate the managed Nix configuration"
  exit 1
}
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="/tmp/explore-frontend/${RUN_ID}"
mkdir -p "$OUT_DIR"
echo "OUT_DIR=$OUT_DIR"
```

Record `OUT_DIR`, `TASK`, and `PAGE` for subsequent invocations. The managed
browser services are configured on Linux; do not assume macOS has them.
If the helper reports an unavailable profile, report that error without installing
a browser, changing the everyday profile, or attaching through a raw CDP endpoint.

---

## Step 2 — Open or inspect the owned page

For a new review, open the target in its own background task:

```bash
TASK="$(browser-task start development --label "Frontend UX review" --url "$TARGET_URL" | jq -r .task)"
PAGE="main"
browser-task info "$TASK"
```

For a task already assigned to this review, inspect it with `browser-task info "$TASK"`.
If it was kept or completed, explicitly run `browser-task resume "$TASK"` before
continuing. Use its existing page name; do not navigate or adopt an unrelated tab.
Use `accounts` instead of `development` only for signed-in third-party services.
Send one JSON action at a time through `browser-task action`:

```bash
printf '%s\n' '{"type":"evaluate","expression":"({url:location.href,title:document.title})"}' \
  | browser-task action "$TASK" --page "$PAGE" --timeout 20
```

`evaluate` returns a synchronous page-local value under `value`. It has no host
bindings, filesystem access, persistent variables, or Promise support. Use
`browser-task open TASK --page NAME` for additional pages. Do not create or
select pages through raw browser or CDP APIs. **Do not navigate during review**:
`start` already loaded the new page, and an existing task may hold in-progress
state. Follow links only when the review explicitly requires it.

---

## Step 3 — Deterministic evidence collection

Run each check and save its output under `$OUT_DIR`. Findings later cite those
artifacts by filename. Define a helper for JSON actions:

```bash
action() {
  browser-task action "$TASK" --page "$PAGE" --timeout 30
}
eval_page() {
  jq -nc --arg expression "$1" '{type:"evaluate",expression:$expression}' | action
}
```

### 3.1 Screenshots at each viewport

For each `WxH` in `VIEWPORTS`, set the viewport and capture both a full page
and a visible viewport screenshot. The screenshot result contains a private
`path`; copy that file to the review directory. For example:

```bash
W=1280 H=800
jq -nc --argjson width "$W" --argjson height "$H" \
  '{type:"viewport",width:$width,height:$height}' | action
printf '%s\n' '{"type":"screenshot","full_page":true}' | action \
  | tee "$OUT_DIR/vp-${W}x${H}-full.json"
cp "$(jq -r .path "$OUT_DIR/vp-${W}x${H}-full.json")" \
  "$OUT_DIR/vp-${W}x${H}-full.png"
printf '%s\n' '{"type":"screenshot","full_page":false}' | action \
  | tee "$OUT_DIR/vp-${W}x${H}-fold.json"
cp "$(jq -r .path "$OUT_DIR/vp-${W}x${H}-fold.json")" \
  "$OUT_DIR/vp-${W}x${H}-fold.png"
```

Repeat for the requested viewport list. If background screenshot capture fails,
record the error and the missing viewport. Do not foreground the browser to
hide the failure. A finding still needs visual evidence from a successful
capture.

### 3.2 DOM outline and landmark audit

Take a snapshot to get visible structure and live refs:

```bash
printf '%s\n' '{"type":"snapshot","max_nodes":2500,"max_chars":60000}' \
  | action > "$OUT_DIR/structure.json"
```

A later snapshot or navigation invalidates earlier refs. Use a fresh ref or
unique role and name before each interaction. Inspect the document's landmarks
with a synchronous expression:

```bash
eval_page '(() => { const count = s => document.querySelectorAll(s).length; return {main:count("main,[role=main]"),nav:count("nav,[role=navigation]"),header:count("header,[role=banner]"),footer:count("footer,[role=contentinfo]"),h1:count("h1"),buttonsNoLabel:[...document.querySelectorAll("button")].filter(e=>!e.textContent.trim()&&!e.getAttribute("aria-label")&&!e.getAttribute("title")).length,imgsNoAlt:[...document.querySelectorAll("img")].filter(e=>!e.hasAttribute("alt")).length,inputsNoLabel:[...document.querySelectorAll("input,textarea,select")].filter(e=>!e.labels?.length&&!e.getAttribute("aria-label")&&!e.getAttribute("aria-labelledby")).length}; })()' \
  | jq .value > "$OUT_DIR/landmarks.json"
```

### 3.3 Runtime health spot-check

Inspect visible error and loading states in the snapshot and screenshots.
Record the current resource timing entries, which may include completed
requests but do not provide a complete network log:

```bash
eval_page 'performance.getEntriesByType("resource").slice(-100).map(e=>({name:e.name,duration:Math.round(e.duration),status:e.responseStatus||null}))' \
  | jq .value > "$OUT_DIR/resources.json"
```

The native tool has no persistent console, page-error, network-event, or
request-interception API. Do not claim those checks were performed. Note this
coverage limit in the report and use app logs only when the user's task gives
you access to them.

### 3.4 Keyboard focus walk

Press Tab up to 30 times with typed `key` actions. After each press, read the
active element's label, position, and focus style. Save the returned `value`
objects as `focus-trail.json`. This loop starts from the page's current focus:

```bash
for i in $(seq 1 30); do
  printf '%s\n' '{"type":"key","key":"Tab"}' | action >/dev/null
  eval_page '(() => { const a=document.activeElement; if(!a)return null; const r=a.getBoundingClientRect(),s=getComputedStyle(a); return {tag:a.tagName.toLowerCase(),role:a.getAttribute("role"),label:(a.getAttribute("aria-label")||a.textContent||"").trim().slice(0,60),rect:{x:Math.round(r.x),y:Math.round(r.y),w:Math.round(r.width),h:Math.round(r.height)},outline:s.outlineStyle+" "+s.outlineWidth+" "+s.outlineColor,boxShadow:s.boxShadow.slice(0,120),visible:r.width>0&&r.height>0&&s.visibility!=="hidden"}; })()' \
    | jq .value > "$OUT_DIR/focus-${i}.json"
done
jq -s . "$OUT_DIR"/focus-*.json > "$OUT_DIR/focus-trail.json"
```

Inspect the screenshots at focused steps when the style data suggests that a
ring is missing or focus reaches an invisible element.

### 3.5 Contrast spot-check

Sample computed colors on visible text. Flag ratios below WCAG AA, 4.5:1 for
normal text and 3:1 for large text. This is a spot-check, not an axe audit.

```bash
expr="$(cat <<'JS'
(() => {
  const rgb = s => { const m = s.match(/rgba?\(([^)]+)\)/); return m ? m[1].split(",").map(x => Number.parseFloat(x)) : null; };
  const lum = c => { const f = v => { v /= 255; return v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; }; return .2126*f(c[0]) + .7152*f(c[1]) + .0722*f(c[2]); };
  const background = el => { for (let p = el; p; p = p.parentElement) { const c = rgb(getComputedStyle(p).backgroundColor); if (c && (c[3] ?? 1) > .1) return c; } return [255,255,255]; };
  const out = [];
  for (const el of [...document.querySelectorAll("p,span,a,button,label,li,td,th,h1,h2,h3,h4,h5,h6")].slice(0,400)) {
    const text = (el.innerText || "").trim();
    if (text.length < 2) continue;
    const style = getComputedStyle(el), fg = rgb(style.color);
    if (!fg) continue;
    const bg = background(el), a = lum(fg), b = lum(bg);
    const ratio = (Math.max(a,b)+.05)/(Math.min(a,b)+.05);
    const size = Number.parseFloat(style.fontSize), bold = Number.parseInt(style.fontWeight) >= 700;
    const need = size >= 24 || (size >= 18.66 && bold) ? 3 : 4.5;
    if (ratio >= need) continue;
    const r = el.getBoundingClientRect();
    out.push({text:text.slice(0,60),ratio:+ratio.toFixed(2),need,fg:style.color,bg:background(el),rect:{x:Math.round(r.x),y:Math.round(r.y),w:Math.round(r.width),h:Math.round(r.height)}});
    if (out.length === 80) break;
  }
  return out;
})()
JS
)"
eval_page "$expr" | jq .value > "$OUT_DIR/contrast-low.json"
```

### 3.6 Hit-target sizes

Flag interactive elements smaller than 24x24 as WCAG 2.5.8 failures. A 44x44
size is a recommendation. Save up to 80 visible targets with positions:

```bash
expr="$(cat <<'JS'
(() => {
  const out = [];
  for (const el of document.querySelectorAll("button,a[href],[role=button],input:not([type=hidden])")) {
    const r = el.getBoundingClientRect();
    if (!r.width || !r.height || (r.width >= 44 && r.height >= 44)) continue;
    out.push({tag:el.tagName.toLowerCase(),label:(el.getAttribute("aria-label")||el.textContent||"").trim().slice(0,60),w:Math.round(r.width),h:Math.round(r.height),x:Math.round(r.x),y:Math.round(r.y)});
    if (out.length === 80) break;
  }
  return out;
})()
JS
)"
eval_page "$expr" | jq .value > "$OUT_DIR/hit-targets.json"
```

### 3.7 Long-text and overflow stress

Skip this if you cannot identify a field whose draft value you can safely
replace. Read the current value with a synchronous `evaluate` expression.
Use a typed `fill` action with a fresh ref or unique role and name to insert
500 characters of sample text. Capture a screenshot, then restore the exact
original value with another `fill` action. Do not submit the form.

---
## Step 4 — Adversarial analysis

For each of the 8 axes below, open `$OUT_DIR` artifacts (Read screenshots, landmarks.json,
focus-trail.json, contrast-low.json, hit-targets.json, resources.json) and enumerate findings.
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
8. **Performance feel & runtime health** — cite `resources.json`, screenshots, and visible
   loading states. Note that console errors and a complete network log are unavailable.

---

## Step 5 — Report

Write the report to `$OUT_DIR/REPORT.md` and echo the path. Use this exact schema so downstream
tooling can parse it:

```markdown
# Explore-Frontend Report — <APP_NAME>

Run: <RUN_ID>
Target: <url> (task <TASK>, page <PAGE>)
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

After the report and browser work are complete, run `browser-task finish "$TASK"`.
Registered pages remain for one hour. For user review, capture a screenshot before
running `browser-task keep "$TASK"`. The default profiles are headless and cannot
show a desktop window. Only a deliberately configured headed profile supports
`browser-task show "$TASK" --page "$PAGE"`, and only on user request.
Resume kept tasks before further automation or finishing. Active, kept, manual,
and unrelated pages never age out through this workflow.

Stop after writing the report. Do not attempt fixes in the same run — the user decides what to
pursue. If the user asks for fixes, branch from main and address findings top-down by severity.

---

## Safety & idempotence

- Keep the review read-only. Never use `navigate` during review or click destructive
  buttons (anything labeled Delete / Remove / Logout / Send / Submit).
- If a finding requires interaction to reproduce (e.g., a dropdown), capture the *before*
  state, perform the minimum interaction, capture the *after* state, and restore with `Escape`
  or a close button. Never leave the tab in a modified state.
- All artifacts land in `$OUT_DIR` and are identified by `RUN_ID` so repeat runs don't clobber.
- `screenshot` returns a private artifact path. Copy that file to `$OUT_DIR`
  from the shell after each capture. Other actions do not write files.

---

## Quick one-shot

To start with defaults, set the target and run Steps 1–5 in order:

```bash
TARGET_URL="http://localhost:3100"
# then run Steps 1-5 in order
```
