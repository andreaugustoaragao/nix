{ pkgs, ... }:

let
  pstackSource = pkgs.fetchFromGitHub {
    owner = "cursor";
    repo = "plugins";
    rev = "c742dd61706fbacc1b95f1a20b7b988cf096ce6c";
    hash = "sha256-YB+9AIZJ6aR5Yx1OC22Xc6HdoxvDDjja/z2yMUt5gWs=";
  };

  # Keep relative links to the guide, agents, and sibling skills intact.
  # Upstream's dormant Benny automations are Cursor-only and must not be
  # picked up as standalone skills by the clients' recursive discovery.
  pstackSkills = pkgs.runCommand "pstack-skills-0.15.36" { } ''
    mkdir -p "$out"
    cp -r ${pstackSource}/pstack/{skills,agents,assets,docs,README.md,LICENSE,plugin.json} "$out/"
    chmod -R u+w "$out"
    ${pkgs.patch}/bin/patch --batch --fuzz=0 -d "$out" -p1 < ${./pstack-testing.patch}

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
  # Codex and Pi discover this global Agent Skills directory.
  # Preserve other installed skills by managing only pstack's subtree.
  home.file.".agents/skills/pstack".source = pstackSkills;

  # OpenCode v2 uses its native configuration directory for skill discovery.
  xdg.configFile."opencode/skills/pstack".source = pstackSkills;
}
