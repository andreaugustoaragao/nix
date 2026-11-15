{
  pkgs,
  vmHome,
  workstationHome,
  workerHome,
}:
let
  inherit (pkgs) lib;
  homes = [
    vmHome
    workstationHome
    workerHome
  ];
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
  normalize =
    value:
    lib.concatStrings (
      lib.filter builtins.isString (builtins.split "/nix/store/[a-z0-9]{32}-" (builtins.toJSON value))
    );
  same = project: lib.all (home: normalize (project home) == normalize (project vmHome)) homes;
  managedFiles =
    home:
    lib.mapAttrs (_: file: { inherit (file) source text executable; }) (
      lib.filterAttrs (
        path: _:
        lib.any (prefix: lib.hasPrefix prefix path) [
          ".agents/skills/"
          ".cursor/skills/"
          ".config/opencode/skills/"
          ".pi/agent/extensions/"
          ".pi/agent/skills/"
          ".pi/agent/themes/"
          ".codex/AGENTS.md"
          ".pi/agent/AGENTS.md"
        ]
      ) home.home.file
    );
  cloudProviders = home: builtins.removeAttrs home.services.piModels.providers [ "llama-cpp" ];
  codex =
    home:
    let
      template = builtins.fromTOML (
        builtins.unsafeDiscardStringContext home.my.agentHarness.codexTemplate
      );
    in
    template
    // {
      model_providers = builtins.removeAttrs template.model_providers [ "openai-sops" ];
      mcp_servers = builtins.removeAttrs template.mcp_servers [ "shared_vault" ];
    };
  opencode =
    home:
    let
      value = builtins.fromJSON (
        builtins.unsafeDiscardStringContext home.xdg.configFile."opencode/opencode.jsonc".text
      );
    in
    value
    // {
      providers = builtins.removeAttrs value.providers [ "llama-cpp" ];
      mcp.servers = builtins.removeAttrs value.mcp.servers [ "shared-vault" ];
    };
  versions =
    home:
    map (package: { inherit (package) pname version; }) (
      lib.filter (
        package:
        builtins.elem (package.pname or "") [
          "codex"
          "pi"
          "pi-coding-agent"
          "cursor-agent"
          "opencode"
          "opencode2"
          "herdr-core"
          "agent-hub"
          "herdr-agent-preview"
        ]
      ) home.home.packages
    );
in
assert lib.assertMsg (lib.all hasPortableSkills homes)
  "Every development host and worker must install all shared portable skills.";
assert lib.assertMsg (same managedFiles)
  "VM, workstation and worker must have identical managed skills, instructions and Pi extensions.";
assert lib.assertMsg (same versions)
  "VM, workstation and worker must pin identical agent and Herdr core versions.";
assert lib.assertMsg (same codex)
  "VM, workstation and worker must share Codex defaults, MCP and hooks.";
assert lib.assertMsg (same (
  home: home.my.agentHarness.cursorHooks
)) "VM, workstation and worker must share Cursor hooks.";
assert lib.assertMsg (
  same cloudProviders && same (home: home.services.piModels.defaultModel)
) "VM, workstation and worker must share cloud models and defaults.";
assert lib.assertMsg (same opencode)
  "VM, workstation and worker must share OpenCode defaults, cloud models and MCP.";
assert lib.assertMsg (
  vmHome.xdg.configFile."herdr-app/layouts/main-flat.json".source
  == workstationHome.xdg.configFile."herdr-app/layouts/main-flat.json".source
) "Both desktop hosts must install the same custom Herdr layout.";
pkgs.runCommand "check-agent-harness-parity" { } ''
  touch "$out"
''
