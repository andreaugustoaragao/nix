#!/usr/bin/env python3
"""Patch upstream pstack skills to use Nix-managed harness adapters authoritatively.

Replaces conflicting upstream model defaults (`claude-opus-5-5-xhigh`,
`grok-4.7-xhigh-fast`), `~/.cursor/rules/pstack-models.mdc` instructions, and
Cursor-only Claude/Grok family parsing with authoritative routing to:

  - docs/harness/omp.md     (Gemini + OpenAI)
  - docs/harness/cursor.md  (Gemini + Grok)
  - docs/harness/codex.md   (OpenAI only, explicit family-diversity boundary)
"""

import re
import sys
from pathlib import Path

HARNESS_BANNER = (
    "\n> **Harness adapter (authoritative):** Read the guide matching your active harness before choosing models or spawning subagents:\n"
    "> - **OMP:** [docs/harness/omp.md](../../docs/harness/omp.md) (Gemini + OpenAI)\n"
    "> - **Cursor:** [docs/harness/cursor.md](../../docs/harness/cursor.md) (Gemini + Grok)\n"
    "> - **Codex:** [docs/harness/codex.md](../../docs/harness/codex.md) (OpenAI only)\n"
)

BANNER_SKILLS = (
    "poteto-mode",
    "setup-pstack",
    "arena",
    "architect",
    "interrogate",
    "how",
    "why",
    "swarm",
    "reflect",
    "poteto-help",
)


def replace_exact(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"Expected anchor not found in {path}:\n{old[:200]}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def replace_regex(path: Path, pattern: str, repl: str, expected: int = 1) -> None:
    text = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, repl, text, flags=re.MULTILINE)
    if count != expected:
        raise SystemExit(f"Expected {expected} match(es) for {pattern!r} in {path}, got {count}")
    path.write_text(updated, encoding="utf-8")


def prepend_banner(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    match = re.match(r"\A---\n.*?\n---\n", text, re.DOTALL)
    if not match:
        raise SystemExit(f"Missing frontmatter in {path}")
    path.write_text(text[: match.end()] + HARNESS_BANNER + text[match.end() :], encoding="utf-8")


def patch_poteto_mode(root: Path) -> None:
    path = root / "skills/poteto-mode/SKILL.md"
    replace_regex(
        path,
        r"^\*\*Defaults for every `Task` call\.\*\*.*$",
        "**Defaults for every `Task` call.** Use your active harness adapter (`docs/harness/{omp,cursor,codex}.md`) for the subagent tool, agent type, and per-role model table. Keep file pointers instead of inlined context, and run independent spawns concurrently. Tier code delegates by difficulty: the hardest changes (cross-cutting design, gnarly concurrency, subtle algorithms) use the `hardest tasks` role, prose and judgment use `judgment and prose`, and code playbooks use their named role (`feature, refactoring`, `bug-fix`, `perf-issue`, `hillclimb`). A role set to `inherit-parent` or `auto` runs on the parent model (omit `model`).",
    )
    replace_regex(
        path,
        r"^\*\*Match the model to the job\.\*\*.*$",
        "**Match the model to the job.** Start from the active harness adapter's role mapping and budget (`large` by default). Raise effort one step for the hardest or subtlest work and lower it for routine tasks, staying within valid slugs for the active harness. On Cursor, append `-fast` to code roles only when urgent (CI/trunk red or a human is blocked right now); verification stays on the `swarm workers` role. Keep the family the role names so diverse panels stay diverse, and never treat a same-family model as a cross-family judge. If the harness rejects a slug, fall back per the active harness adapter and report it.",
    )


def patch_setup_pstack(root: Path) -> None:
    path = root / "skills/setup-pstack/SKILL.md"
    text = path.read_text(encoding="utf-8")
    match = re.match(r"\A(---\n.*?\n---\n)", text, re.DOTALL)
    if not match:
        raise SystemExit(f"Missing frontmatter in {path}")
    new_body = f"""{HARNESS_BANNER}
# Setup pstack

pstack model routing on this machine is declaratively managed in Nix, per harness, rather than in an always-applied `~/.cursor/rules/pstack-models.mdc` file (which would leak pstack instructions into non-pstack turns).

## Steps

### 1. Identify the active harness and current mapping

Read the active harness adapter:

- **OMP:** `docs/harness/omp.md` (source: `~/projects/personal/nix/home/cli/pstack/harness-omp.md` + `home/cli/omp.nix`)
- **Cursor:** `docs/harness/cursor.md` (source: `~/projects/personal/nix/home/cli/pstack/harness-cursor.md`)
- **Codex:** `docs/harness/codex.md` (source: `~/projects/personal/nix/home/cli/pstack/harness-codex.md`)

### 2. Verify available models

Detect the models actually available in the active harness before proposing any change:

- **OMP:** configured `modelRoles` in `~/.omp/agent/config.yml` (per-call models require operator `modelRoles` grants with `task.perCallModel = "on"`).
- **Cursor:** `cursor-agent --list-models`.
- **Codex:** `codex debug models` (and the `codex-openai` vs `codex-webai` split).

Never write a model slug that has not been verified in the active harness. `inherit-parent` and `auto` are always valid.

### 3. Budget, map, and confirm

Offer `unlimited` (`max`), `large` (`xhigh`), `medium` (`high`), or `small` (`medium`). These are reasoning presets, not spending caps. Show the complete proposed role table for the target harness and confirm with the user before editing Nix source.

Respect model families when configuring `arena runners`, `architect runners`, `interrogate reviewers`, and `arena cross-judge pool`. On OpenAI-only harnesses (Codex), do not configure another GPT model as a cross-family judge.

### 4. Persist declaratively

Edit the corresponding Nix source file under `~/projects/personal/nix/home/cli/pstack/harness-<harness>.md` (and `home/cli/omp.nix` if an OMP role grant is added). Do not write `~/.cursor/rules/pstack-models.mdc` or edit `/nix/store`. Validate the Nix flake and report activation as pending until rebuild/switch runs.

### 5. Offer optional project verification skills

If the current repository lacks a `verify-*` app-driving skill or a formal verification skill, offer once to generate one with `/create-verification-skill` or `/create-formal-verification-skill`.
"""
    path.write_text(match.group(1) + new_body, encoding="utf-8")

def patch_arena(root: Path) -> None:
    path = root / "skills/arena/SKILL.md"
    replace_regex(
        path,
        r"^3\. Pick the runners\..*$",
        "3. Pick the runners from the `arena runners` role in the active harness adapter (`docs/harness/{omp,cursor,codex}.md`). An `auto` or `inherit-parent` entry runs on the parent model (omit `model`) only when the parent belongs to that harness's allowed families. Classify model families after stripping any `provider/` prefix and `:effort` suffix: `openai` (`gpt-*`, `o1-*`, `o3-*`, `o4-*`, `codex-*`), `gemini` (`gemini-*`), `grok` (`grok-*`, `cursor-grok-*`), `composer` (`composer-*`), and `claude` (`claude-*`). If the harness rejects a configured entry, fall back to the closest valid slug of the same family per the active harness adapter and say so, or drop the seat when none exists. If dropped seats leave fewer than two runners, add runners on a remaining runner's model (or omit `model` only when the parent belongs to that harness's allowed families; otherwise stop and report the shortfall). Note explicitly when a harness's runners share one family (e.g. Codex OpenAI Astra + Sol = model diversity, not cross-family diversity). Pick reasoning effort per the Subagents section of **poteto-mode**.",
    )
    replace_regex(
        path,
        r"^After all Phase B candidates complete, choose one model from the `arena cross-judge pool`.*$",
        "After all Phase B candidates complete, choose one model from the `arena cross-judge pool` role in the active harness adapter (`docs/harness/{omp,cursor,codex}.md`). Spawn one readonly judge subagent whose model family (per Phase A step 3) differs strictly from the parent's family. Try only pool entries from another family, in pool order; `auto` and `inherit-parent` never judge, and a same-family model (such as `gpt-6-astra` judging a `gpt-6.1-sol` parent) never qualifies as a cross-family judge. If the pool is empty or has no qualifying non-parent family (including OpenAI-only Codex routes), skip Phase C, pick the base alone in Phase D, and report that no cross-family judge was available. If the parent's model is unknown, try the pool's real slugs in order and state that the family check did not run. The judge sees the rubric and the candidates by path label, scores each criterion, and recommends a base with rationale. It runs in parallel with your reading in Phase D. Don't spawn it while candidates are still writing.",
    )


def patch_architect(root: Path) -> None:
    path = root / "skills/architect/SKILL.md"
    replace_regex(
        path,
        r"^Take the runners from the `architect runners` line.*$",
        "Take the runners from the `architect runners` role in the active harness adapter (`docs/harness/{omp,cursor,codex}.md`), in place of `arena runners`. Alias, family classification, and rejected-entry handling follow **arena** Phase A.",
    )


def patch_how(root: Path) -> None:
    path = root / "skills/how/SKILL.md"
    replace_regex(
        path,
        r"^Every spawn is a Task subagent with `subagent_type: generalPurpose`.*$",
        "Spawn readonly subagents per the active harness adapter (`docs/harness/{omp,cursor,codex}.md`): explorers use `how explorer`, and explainers use `how explainer`. Leave `model` unset for `auto` or `inherit-parent`. If a slug is rejected, follow the active harness adapter's fallback and report it. Pick reasoning effort per the Subagents section of **poteto-mode**.",
    )


def patch_why(root: Path) -> None:
    path = root / "skills/why/SKILL.md"
    replace_regex(
        path,
        r"^Each spawn below names a role line in the `pstack-models\.mdc`.*$",
        "Each spawn below names a role in the active harness adapter (`docs/harness/{omp,cursor,codex}.md`). Set `model` from that role (leave unset for `auto` or `inherit-parent`). If a slug is rejected, follow the active harness adapter's fallback and report it. Pick reasoning effort per the Subagents section of **poteto-mode**.",
    )
    replace_exact(
        path,
        "`model`: the `why investigators` line, default `grok-4.7-xhigh-fast`.",
        "`model`: the `why investigators` role from the active harness adapter.",
    )
    replace_exact(
        path,
        "`model`: the `why synthesizer` line, default `claude-opus-5-5-xhigh`.",
        "`model`: the `why synthesizer` role from the active harness adapter.",
    )


def patch_swarm(root: Path) -> None:
    path = root / "skills/swarm/SKILL.md"
    replace_regex(
        path,
        r"^3\. Pick the worker model from the `swarm workers` line.*$",
        "3. Pick the worker model from the `swarm workers` role in the active harness adapter (`docs/harness/{omp,cursor,codex}.md`). For `auto` or `inherit-parent`, omit `model`. If a slug is rejected, follow the active harness adapter's fallback and report it. For a model race, name each arm's model up front. Pick reasoning effort per the Subagents section of **poteto-mode**.",
    )


def patch_reflect(root: Path) -> None:
    path = root / "skills/reflect/SKILL.md"
    replace_regex(
        path,
        r"^Each reviewer and the synthesizer name a role line in the `pstack-models\.mdc`.*$",
        "Each reviewer and the synthesizer name a role in the active harness adapter (`docs/harness/{omp,cursor,codex}.md`). Set `model` from that role (leave unset for `auto` or `inherit-parent`). If a slug is rejected, follow the active harness adapter's fallback and report it. Pick reasoning effort per the Subagents section of **poteto-mode**.",
    )
    replace_exact(
        path,
        "| Lens | Role line | Default `model` | Prompt template |\n"
        "|---|---|---|---|\n"
        "| Judgment | `reflect judgment, divergent, synthesizer` | `claude-opus-5-5-xhigh` | `references/judgment-reviewer.md` |\n"
        "| Tooling | `reflect tooling` | `grok-4.7-xhigh-fast` | `references/tooling-reviewer.md` |\n"
        "| Divergent | `reflect judgment, divergent, synthesizer` | `claude-opus-5-5-xhigh` | `references/divergent-reviewer.md` |",
        "| Lens | Role (active harness adapter) | Prompt template |\n"
        "|---|---|---|\n"
        "| Judgment | `reflect judgment, divergent, synthesizer` | `references/judgment-reviewer.md` |\n"
        "| Tooling | `reflect tooling` | `references/tooling-reviewer.md` |\n"
        "| Divergent | `reflect judgment, divergent, synthesizer` | `references/divergent-reviewer.md` |",
    )
    replace_exact(
        path,
        "`model` from the `reflect judgment, divergent, synthesizer` line (default `claude-opus-5-5-xhigh`)",
        "`model` from the `reflect judgment, divergent, synthesizer` role in the active harness adapter",
    )


def patch_poteto_help(root: Path) -> None:
    path = root / "skills/poteto-help/SKILL.md"
    replace_exact(
        path,
        "- No `~/.cursor/rules/pstack-models.mdc` means `/setup-pstack` hasn't run for this user, so every role uses its default model.",
        "- Model routing is Nix-managed per harness in `docs/harness/{omp,cursor,codex}.md` (not `~/.cursor/rules/pstack-models.mdc`).",
    )
    replace_exact(
        path,
        "Other tools can read the skills, because they use the Agent Skills format. But most workflow skills, including `/poteto-mode`, `/how`, `/why`, and `/teach`, spawn Cursor subagents with per-role models, and Custom Modes and `/loop` are Cursor features, so those parts may not work there.",
        "This Nix installation ships authoritative harness adapters in `docs/harness/omp.md` (Gemini + OpenAI), `docs/harness/cursor.md` (Gemini + Grok), and `docs/harness/codex.md` (OpenAI only).",
    )


def patch_playbooks(root: Path) -> None:
    playbooks = root / "skills/poteto-mode/playbooks"
    for name in (
        "bug-fix.md",
        "feature.md",
        "hillclimb.md",
        "multi-phase-plan.md",
        "perf-issue.md",
        "refactoring.md",
    ):
        replace_exact(
            playbooks / name,
            "(default `grok-4.7-xhigh-fast`)",
            "(per the active harness adapter)",
        )


def verify_clean(root: Path) -> None:
    skills_root = root / "skills"
    leaks = []
    for md in sorted(skills_root.rglob("*.md")):
        text = md.read_text(encoding="utf-8")
        if "claude-opus-5-5" in text:
            leaks.append(f"claude-opus-5-5 remained in {md.relative_to(root)}")
        if "pstack-models.mdc" in text and md.relative_to(root).as_posix() not in (
            "skills/setup-pstack/SKILL.md",
            "skills/poteto-help/SKILL.md",
        ):
            leaks.append(f"pstack-models.mdc remained in {md.relative_to(root)}")
    if leaks:
        raise SystemExit("Upstream pstack model/rule leaks remain:\n" + "\n".join(leaks))


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        raise SystemExit("Usage: patch-pstack.py <pstack-root>")
    root = Path(argv[0])

    patch_poteto_mode(root)
    patch_setup_pstack(root)
    patch_arena(root)
    patch_architect(root)
    patch_how(root)
    patch_why(root)
    patch_swarm(root)
    patch_reflect(root)
    patch_poteto_help(root)
    patch_playbooks(root)

    for skill in BANNER_SKILLS:
        if skill != "setup-pstack":
            prepend_banner(root / "skills" / skill / "SKILL.md")

    verify_clean(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
