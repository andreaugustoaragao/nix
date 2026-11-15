{
  pkgs,
  vmHome,
  workstationHome,
}:
let
  inherit (pkgs) lib;
  skills = builtins.attrNames (
    lib.filterAttrs (_: kind: kind == "directory") (builtins.readDir ./portable-skills)
  );
  roots = [
    ".agents/skills"
    ".cursor/skills"
    ".config/opencode/skills"
  ];
  hasPortableSkills =
    home:
    lib.all (root: lib.all (name: builtins.hasAttr "${root}/${name}" home.home.file) skills) roots;
  agentSkills =
    home: lib.filter (lib.hasPrefix ".agents/skills/") (builtins.attrNames home.home.file);
  instructions =
    home:
    map (path: home.home.file.${path}.text) [
      ".codex/AGENTS.md"
      ".pi/agent/AGENTS.md"
    ];
in
assert lib.assertMsg (
  hasPortableSkills vmHome && hasPortableSkills workstationHome
) "Both desktop hosts must install every shared portable skill for retained agents.";
assert lib.assertMsg (
  agentSkills vmHome == agentSkills workstationHome
) "The VM and workstation must expose the same managed Agent Skills.";
assert lib.assertMsg (
  instructions vmHome == instructions workstationHome
) "The VM and workstation must use the same Codex and Pi instructions.";
assert lib.assertMsg (
  vmHome.xdg.configFile."herdr-app/layouts/main-flat.json".source
  == workstationHome.xdg.configFile."herdr-app/layouts/main-flat.json".source
) "Both desktop hosts must install the same custom Herdr layout.";
pkgs.runCommand "check-agent-desktop-parity" { } ''
  touch "$out"
''
