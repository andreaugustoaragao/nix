{
  lib,
  pkgs,
  ...
}:

let
  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  pstackSource = pkgs.fetchFromGitHub {
    owner = "cursor";
    repo = "plugins";
    rev = "ae5650febf4320793844c12c4adaa937f417f8da";
    hash = "sha256-sX6KIElyFreuDPt4zViNis2nuAn9QG0n38z3uejJU98=";
  };

  # Keep relative links to the guide, agents, and sibling skills intact.
  # Upstream's dormant Benny automations are Cursor-only and must not be
  # picked up as standalone skills by the clients' recursive discovery.
  pstackSkills = pkgs.runCommand "pstack-skills-0.15.36" { } ''
    mkdir -p "$out/.cursor-plugin"
    cp -r ${pstackSource}/pstack/{skills,agents,assets,docs,README.md,LICENSE,plugin.json} "$out/"
    chmod -R u+w "$out"
    ${pkgs.patch}/bin/patch --batch --fuzz=0 -d "$out" -p1 < ${./pstack-testing.patch}

    # Provide Cursor plugin manifest location for `cursor-agent --plugin-dir`.
    cp "$out/plugin.json" "$out/.cursor-plugin/plugin.json"

    # Keep Codex-specific pstack policy inside the bundle instead of global ~/.codex/AGENTS.md.
    cp ${./pstack-codex.md} "$out/docs/codex.md"
    ${lib.getExe python} - "$out" <<'PY'
    import re
    import sys
    from pathlib import Path

    root = Path(sys.argv[1])
    note = "\n> **Codex:** Read [Pstack in Codex](../../docs/codex.md) for Codex execution policy, delegation limits, and model/role mappings.\n"
    for rel in ("skills/poteto-mode/SKILL.md", "skills/setup-pstack/SKILL.md"):
        path = root / rel
        text = path.read_text(encoding="utf-8")
        match = re.match(r"\A---\n.*?\n---\n", text, re.DOTALL)
        if not match:
            raise SystemExit(f"Missing frontmatter in {path}")
        path.write_text(text[:match.end()] + note + text[match.end():], encoding="utf-8")
    PY

    # Enforce explicit-only invocation across all pstack skills (including setup-pstack)
    # for OMP, Cursor, and Codex.
    ${lib.getExe python} ${./make-explicit-skill.py} "$out"/skills/*

    # Pi also discovers ordinary Markdown in nested skill directories.
    # Keep supporting documents readable without registering them as skills.
    cat > "$out/.gitignore" <<'EOF'
    /agents/
    /assets/
    /docs/
    /README.md
    EOF
  '';
in
{
  my.agentHarness.pstackPackage = pstackSkills;

  # Codex and Pi discover this global Agent Skills directory recursively;
  # OMP loads skills/ via skills.customDirectories in omp.nix;
  # Cursor loads this bundle via --plugin-dir in cursor.nix.
  home.file.".agents/skills/pstack".source = pstackSkills;
}
