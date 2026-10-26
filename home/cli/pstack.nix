{ pkgs, ... }:

let
  pstackSource = pkgs.fetchFromGitHub {
    owner = "cursor";
    repo = "plugins";
    rev = "0b8e952052d482ee6de06deebf14d590d77b1b34";
    hash = "sha256-9y7/JHWLK4T75Q25RnmPzEyLmkXfJV1KMB6+pAQGZl8=";
  };

  # Keep relative links to the guide, agents, and sibling skills intact.
  # Upstream's dormant Benny automations are Cursor-only and must not be
  # picked up as standalone skills by the clients' recursive discovery.
  pstackSkills = pkgs.runCommand "pstack-skills-0.15.26" { } ''
    mkdir -p "$out"
    cp -r ${pstackSource}/pstack/{skills,agents,assets,docs,README.md,LICENSE,plugin.json} "$out/"

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
