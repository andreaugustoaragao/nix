{
  lib,
  pkgs,
  ...
}:

let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  upstream = pkgs.fetchFromGitHub {
    owner = "mattpocock";
    repo = "skills";
    rev = "abeeaf95660ba9e8b7c753eb38f441ca707a8823";
    hash = "sha256-fc5+qmchp1IQ/rQP1olWKC1eC4VdYhaB7YYzC3+JBe0=";
  };

  # All engineering + productivity skills, with `tdd` and `teach` renamed to
  # `pocock-tdd` and `pocock-teach` to avoid colliding with `pstack`.
  skillNames = [
    "ask-matt"
    "code-review"
    "codebase-design"
    "diagnosing-bugs"
    "domain-modeling"
    "grill-me"
    "grill-with-docs"
    "grilling"
    "handoff"
    "implement"
    "implement-spec"
    "improve-codebase-architecture"
    "pocock-tdd"
    "pocock-teach"
    "pr"
    "prototype"
    "research"
    "retro"
    "setup-matt-pocock-skills"
    "to-questionnaire"
    "to-spec"
    "to-tickets"
    "triage"
    "wait-what"
    "wayfinder"
    "wizard"
    "writing-for-agents"
  ];

  pocockSkills = pkgs.runCommand "mattpocock-skills" { } ''
    mkdir -p "$out"
    for group in engineering productivity; do
      for dir in "${upstream}/skills/$group"/*; do
        [ -d "$dir" ] || continue
        name="$(basename "$dir")"
        case "$name" in
          tdd) target="pocock-tdd" ;;
          teach) target="pocock-teach" ;;
          *) target="$name" ;;
        esac
        cp -r "$dir" "$out/$target"
      done
    done
    chmod -R u+w "$out"

    ${lib.getExe python} - "$out" <<'PY'
    import re
    import sys
    from pathlib import Path

    root = Path(sys.argv[1])

    for old, new in (("tdd", "pocock-tdd"), ("teach", "pocock-teach")):
        skill_md = root / new / "SKILL.md"
        text = skill_md.read_text(encoding="utf-8")
        text, count = re.subn(rf"(?m)^name:\s*{re.escape(old)}\s*$", f"name: {new}", text, count=1)
        if count != 1:
            raise SystemExit(f"Expected name: {old} in {skill_md}")
        skill_md.write_text(text, encoding="utf-8")

    # Update cross-references inside Pocock skills to the disambiguated names.
    for skill_md in sorted(root.glob("*/SKILL.md")):
        text = skill_md.read_text(encoding="utf-8")
        text = re.sub(r'(?<![\w-])/(tdd)\b', "/pocock-tdd", text)
        text = re.sub(r'(?<![\w-])/(teach)\b', "/pocock-teach", text)
        text = text.replace('Skill tool with "tdd"', 'Skill tool with "pocock-tdd"')
        text = text.replace("Skill tool with `tdd`", "Skill tool with `pocock-tdd`")
        text = text.replace('Skill tool with "teach"', 'Skill tool with "pocock-teach"')
        text = text.replace("Skill tool with `teach`", "Skill tool with `pocock-teach`")
        skill_md.write_text(text, encoding="utf-8")

    # Supplement /retro with mandatory non-deterministic -> deterministic conversion analysis.
    retro_md = root / "retro" / "SKILL.md"
    retro_text = retro_md.read_text(encoding="utf-8")
    anchor = "- **Information access**:"
    determinism_bullet = (
        "- **Non-deterministic to deterministic conversion** _(required every retro)_: "
        "audit every non-deterministic step, manual multi-command ritual, or recurring agent "
        "judgement call from the session and convert each viable one into a deterministic "
        "lint rule, static validator, or helper script. Prefer mechanical enforcement "
        "(ESLint/Clippy/schema/config validator or a one-command script) over prose rules "
        "whenever the invariant can be checked or executed deterministically.\n"
    )
    if anchor not in retro_text:
        raise SystemExit(f"Expected anchor {anchor!r} in {retro_md}")
    retro_text = retro_text.replace(anchor, determinism_bullet + anchor, 1)
    retro_md.write_text(retro_text, encoding="utf-8")
    PY
    # Enforce explicit-only invocation across every Pocock skill for OMP, Cursor, and Codex.
    ${lib.getExe python} ${./make-explicit-skill.py} "$out"/*

    # Verify the built set matches our declared static skill list exactly.
    built="$(cd "$out" && printf '%s\n' * | LC_ALL=C sort)"
    expected="$(printf '%s\n' ${lib.escapeShellArgs skillNames} | LC_ALL=C sort)"
    if [ "$built" != "$expected" ]; then
      echo "Pocock skill list mismatch!" >&2
      diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$built") >&2
      exit 1
    fi
  '';
in
{
  # Codex and Pi discover ~/.agents/skills recursively; OMP loads this subtree
  # via skills.customDirectories in omp.nix. Cursor scans ~/.cursor/skills one
  # level deep, so mirror each skill directly there.
  home.file = {
    ".agents/skills/pocock".source = pocockSkills;
  }
  // lib.listToAttrs (
    map (name: {
      name = ".cursor/skills/${name}";
      value = {
        source = "${pocockSkills}/${name}";
        force = true;
      };
    }) skillNames
  );
}
