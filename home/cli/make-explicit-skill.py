#!/usr/bin/env python3
"""Ensure one or more Agent Skill directories are explicit-only across OMP, Cursor, and Codex.

For every supplied skill directory:
  1. Sets `disable-model-invocation: true` in `SKILL.md` YAML frontmatter.
  2. Merges `policy.allow_implicit_invocation: false` into `agents/openai.yaml`,
     preserving existing metadata such as `interface`.
"""

import re
import sys
from pathlib import Path
import yaml

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---(\n|\Z)", re.DOTALL)
DMI_LINE_RE = re.compile(r"(?m)^disable-model-invocation\s*:.*$")


def update_skill_md(skill_dir: Path) -> None:
    skill_md = skill_dir / "SKILL.md"
    if not skill_md.is_file():
        raise SystemExit(f"Missing SKILL.md in {skill_dir}")

    text = skill_md.read_text(encoding="utf-8")
    match = FRONTMATTER_RE.match(text)
    if not match:
        raise SystemExit(f"Missing YAML frontmatter in {skill_md}")

    raw_fm = match.group(1)
    newline = match.group(2)
    body = text[match.end() :]

    if DMI_LINE_RE.search(raw_fm):
        new_fm = DMI_LINE_RE.sub("disable-model-invocation: true", raw_fm, count=1)
    else:
        new_fm = f"{raw_fm}\ndisable-model-invocation: true"

    parsed = yaml.safe_load(new_fm)
    if not isinstance(parsed, dict):
        raise SystemExit(f"Frontmatter is not a mapping in {skill_md}")
    if parsed.get("disable-model-invocation") is not True:
        raise SystemExit(f"Failed to set disable-model-invocation in {skill_md}")
    if not parsed.get("name") or not parsed.get("description"):
        raise SystemExit(f"Missing required name or description in {skill_md}")

    skill_md.write_text(f"---\n{new_fm}\n---{newline}{body}", encoding="utf-8")


def update_openai_yaml(skill_dir: Path) -> None:
    yaml_path = skill_dir / "agents" / "openai.yaml"
    if yaml_path.exists():
        loaded = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
        if loaded is None:
            data = {}
        elif isinstance(loaded, dict):
            data = loaded
        else:
            raise SystemExit(f"Unexpected YAML structure in {yaml_path}")
    else:
        yaml_path.parent.mkdir(parents=True, exist_ok=True)
        data = {}

    policy = data.get("policy")
    if policy is None:
        policy = {}
    elif not isinstance(policy, dict):
        raise SystemExit(f"Unexpected policy structure in {yaml_path}")
    policy["allow_implicit_invocation"] = False
    data["policy"] = policy

    rendered = yaml.safe_dump(data, sort_keys=False, allow_unicode=True)
    yaml_path.write_text(rendered, encoding="utf-8")

    check = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
    if not isinstance(check, dict) or check.get("policy", {}).get("allow_implicit_invocation") is not False:
        raise SystemExit(f"Failed to verify policy.allow_implicit_invocation in {yaml_path}")


def main(argv: list[str]) -> int:
    if not argv:
        raise SystemExit("Usage: make-explicit-skill.py <skill-dir> [...]")
    for raw in argv:
        skill_dir = Path(raw)
        if not skill_dir.is_dir():
            raise SystemExit(f"Not a directory: {skill_dir}")
        update_skill_md(skill_dir)
        update_openai_yaml(skill_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
