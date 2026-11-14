{
  config,
  lib,
  pkgs,
  ...
}:

let
  rev = "5863806dd4e15c63174bee4e7515a4256792ecfa";
  upstream = "https://raw.githubusercontent.com/mattpocock/skills/${rev}/skills/productivity";
  entry = pkgs.fetchurl {
    url = "${upstream}/grill-me/SKILL.md";
    hash = "sha256-yq+LjeFoT5biayjzwpGJ21yJzOS3PhyT2GFk9m74hjc=";
  };
  metadata = pkgs.fetchurl {
    url = "${upstream}/grill-me/agents/openai.yaml";
    hash = "sha256-wGHjnD4PnYZfsbl1VtSFcEryqKWPS4IhqJF6XCB0oys=";
  };
  grilling = pkgs.fetchurl {
    url = "${upstream}/grilling/SKILL.md";
    hash = "sha256-oUaELtk8pD2DNVD6mt8C5Yy2PIP+qdS0UimVuCJC1OI=";
  };
  skill = pkgs.runCommand "grill-me-skill" { } ''
    mkdir -p "$out/agents" "$out/references"
    substitute ${entry} "$out/SKILL.md" \
      --replace-fail 'Call the Skill tool with "grilling".' \
      'Read references/grilling.md in this skill directory and follow its instructions.'
    cp ${grilling} "$out/references/grilling.md"
    cp ${metadata} "$out/agents/openai.yaml"
  '';
  roots = [
    ".agents/skills"
    ".claude/skills"
    ".cursor/skills"
    ".grok/skills"
    ".gemini/skills"
    ".qwen/skills"
    "${lib.removePrefix "${config.home.homeDirectory}/" config.xdg.configHome}/opencode/skills"
  ];
in
{
  home.file = lib.genAttrs (map (root: "${root}/grill-me") roots) (_: {
    source = skill;
  });
}
