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
        !(builtins.elem path [
          ".agents/skills/vault-companion"
          ".cursor/skills/vault-companion"
        ])
        && lib.any (prefix: lib.hasPrefix prefix path) [
          ".agents/skills/"
          ".cursor/skills/"
          ".pi/agent/extensions/"
          ".pi/agent/skills/"
          ".pi/agent/themes/"
          ".codex/AGENTS.md"
          ".pi/agent/AGENTS.md"
          ".omp/agent/themes/"
          ".omp/agent/AGENTS.md"
          ".omp/agent/RULES.md"
        ]
      ) home.home.file
    );
  cloudProviders = home: builtins.removeAttrs home.services.piModels.providers [ "llama-cpp" ];
  codexTemplate =
    home: builtins.fromTOML (builtins.unsafeDiscardStringContext home.my.agentHarness.codexTemplate);
  codex =
    home:
    let
      template = codexTemplate home;
    in
    template
    // {
      model_providers = builtins.removeAttrs template.model_providers [
        "openai-sops"
        "chatgpt-retry"
      ];
      mcp_servers = builtins.removeAttrs template.mcp_servers [ "shared_vault" ];
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
          "herdr-core"
          "agent-hub"
          "herdr-agent-preview"
          "omp"
        ]
      ) home.home.packages
    );
in
assert lib.assertMsg (lib.all hasPortableSkills homes)
  "Every development host and worker must install all shared portable skills.";
assert lib.assertMsg (same managedFiles)
  "VM, workstation and worker must have identical managed skills, instructions and Pi extensions.";
assert lib.assertMsg
  (lib.all (
    home:
    let
      hasCompanion =
        builtins.hasAttr ".agents/skills/vault-companion" home.home.file
        && builtins.hasAttr ".cursor/skills/vault-companion" home.home.file;
      hasAnyCompanion =
        builtins.hasAttr ".agents/skills/vault-companion" home.home.file
        || builtins.hasAttr ".cursor/skills/vault-companion" home.home.file;
    in
    if (home.my.vaultV2.enable or false) then hasCompanion else !hasAnyCompanion
  ) homes)
  "vault-companion must be installed under both .agents/skills and .cursor/skills iff my.vaultV2.enable.";
assert lib.assertMsg (same versions)
  "VM, workstation and worker must pin identical agent and Herdr core versions.";
assert lib.assertMsg (lib.all (
  home: (codexTemplate home).model_provider == "openai"
) homes) "Every host must default to the native OpenAI Codex provider.";
assert lib.assertMsg (
  ((codexTemplate workerHome).model_providers.chatgpt-retry or null) == {
    name = "ChatGPT";
    base_url = "https://chatgpt.com/backend-api/codex";
    requires_openai_auth = true;
    request_max_retries = 100;
    stream_max_retries = 100;
  }
  && lib.all (home: !((codexTemplate home).model_providers ? chatgpt-retry)) [
    vmHome
    workstationHome
  ]
) "Only the worker retains the exact legacy Codex provider for migrated session resumes.";
assert lib.assertMsg (same codex)
  "VM, workstation and worker must share Codex defaults, MCP and hooks.";
assert lib.assertMsg (same (
  home: home.my.agentHarness.cursorHooks
)) "VM, workstation and worker must share Cursor hooks.";
assert lib.assertMsg (
  same cloudProviders && same (home: home.services.piModels.defaultModel)
) "VM, workstation and worker must share cloud models and defaults.";
assert lib.assertMsg (lib.all (
  home:
  home.services.piModels.defaultModel == "litellm/gpt-6.2-sol"
  && home.services.piModels.modelThinkingLevels."litellm/gpt-6.2-sol" == "high"
  &&
    lib.hasPrefix "${home.my.agentHarness.piManagedExtensions}/"
      home.home.file.".pi/agent/extensions/lsp.ts".source
  &&
    lib.hasPrefix "${home.my.agentHarness.piManagedExtensions}/"
      home.home.file.".pi/agent/extensions/browser-mcp.ts".source
  &&
    home.home.file.".pi/agent/extensions/lib/lifecycle.ts".source
    == "${home.my.agentHarness.piManagedExtensions}/lib/lifecycle.ts"
) homes) "Full Pi uses the high-thinking WebAI default and one co-located lifecycle bundle.";
assert lib.assertMsg (
  vmHome.xdg.configFile."herdr-app/layouts/main-flat.json".source
  == workstationHome.xdg.configFile."herdr-app/layouts/main-flat.json".source
) "Both desktop hosts must install the same custom Herdr layout.";
assert lib.assertMsg (lib.all (
  home:
  let
    piPkg = lib.findFirst (p: (p.pname or p.name or "") == "pi-coding-agent") null home.home.packages;
    piTaskPkg = lib.findFirst (p: (p.name or "") == "pi-task") null home.home.packages;
  in
  piPkg != null
  && piTaskPkg != null
  && (home.home.file.".local/bin/pi".source or null) == "${piPkg}/bin/pi"
  && (home.home.file.".local/bin/pi-task".source or null) == lib.getExe piTaskPkg
) homes) "VM, workstation and worker must expose full pi and wrapped pi-task.";
assert lib.assertMsg (lib.all (
  home:
  let
    ompPkg = lib.findFirst (p: (p.pname or p.name or "") == "omp") null home.home.packages;
  in
  ompPkg != null && (home.home.file.".local/bin/omp".source or null) == lib.getExe ompPkg
) homes) "VM, workstation and worker must install and expose omp.";
pkgs.runCommand "check-agent-harness-parity" { } ''
  touch "$out"
''
