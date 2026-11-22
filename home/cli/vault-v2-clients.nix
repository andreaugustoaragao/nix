# Home Manager module registering Shared Vault v2 and AI Task Scheduler MCP
# servers across Codex, Cursor, Pi, and OMP (ADR-0001 / ADR-0002 / ADR-0003)
# via the existing ownership-aware `shared-vault-configure.py --prepare/--apply/--check`
# activation flow (matching personal/nix/home/cli/shared-vault.nix).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.vaultV2Clients;
  inherit (cfg) vaultSocket schedulerSocket;
  pkg = cfg.package;

  vaultMcpLauncher = pkgs.writeShellScriptBin "vault-v2-mcp" ''
    exec ${pkg}/bin/shared-vault mcp --socket ${lib.escapeShellArg vaultSocket} "$@"
  '';

  schedulerMcpLauncher = pkgs.writeShellScriptBin "scheduler-v2-mcp" ''
    exec ${pkg}/bin/ai-task-scheduler mcp --socket ${lib.escapeShellArg schedulerSocket} "$@"
  '';

  mkServerEntry =
    command: client:
    if client == "codex" then
      {
        inherit command;
        args = [ ];
        startup_timeout_sec = 20;
        tool_timeout_sec = 120;
      }
    else if client == "pi" then
      {
        inherit command;
        args = [ ];
        timeout = 120;
      }
    else if client == "omp" then
      {
        type = "stdio";
        inherit command;
        args = [ ];
        timeout = 120000;
      }
    else
      {
        inherit command;
        args = [ ];
      };

  mkManifest =
    name: command:
    pkgs.writeText "${name}-v2-registrations.json" (
      builtins.toJSON {
        version = 1;
        inherit name;
        clients =
          map
            (client: {
              inherit (client) kind target;
              desired =
                if cfg.enable && builtins.elem client.kind cfg.clients then
                  mkServerEntry command client.kind
                else
                  null;
            })
            [
              {
                kind = "codex";
                target = "${config.home.homeDirectory}/.codex/config.toml";
              }
              {
                kind = "cursor";
                target = "${config.home.homeDirectory}/.cursor/mcp.json";
              }
              {
                kind = "pi";
                target = "${config.home.homeDirectory}/.pi/agent/mcp.json";
              }
              {
                kind = "omp";
                target = "${config.home.homeDirectory}/.omp/agent/mcp.json";
              }
            ];
      }
    );

  vaultManifest = mkManifest "shared-vault" "${vaultMcpLauncher}/bin/vault-v2-mcp";
  schedulerManifest = mkManifest "ai-task-scheduler" "${schedulerMcpLauncher}/bin/scheduler-v2-mcp";

  python = pkgs.python3.withPackages (ps: [
    ps.tomlkit
    ps.json5
  ]);

  vaultStateDir = "${config.xdg.stateHome}/shared-vault/registrations";
  schedulerStateDir = "${config.xdg.stateHome}/ai-task-scheduler/registrations";

  vaultConfigure = "${lib.getExe python} ${cfg.configureScript} --manifest ${vaultManifest} --state-directory ${lib.escapeShellArg vaultStateDir}";
  schedulerConfigure = "${lib.getExe python} ${cfg.configureScript} --manifest ${schedulerManifest} --state-directory ${lib.escapeShellArg schedulerStateDir}";

  diagnostics = pkgs.writeShellScriptBin "vault-v2-client-config" ''
    if [ "$#" -ne 1 ] || [ "$1" != check ]; then
      echo 'usage: vault-v2-client-config check' >&2
      exit 2
    fi
    status=0
    ${vaultConfigure} --check || status=$?
    ${schedulerConfigure} --check || status=$?
    exit "$status"
  '';
in
{
  options.my.vaultV2Clients = {
    enable = lib.mkEnableOption "Shared Vault v2 + AI Task Scheduler MCP client registrations";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Package providing bin/shared-vault and bin/ai-task-scheduler.";
    };

    configureScript = lib.mkOption {
      type = lib.types.path;
      description = "Path to ownership-aware shared-vault-configure.py (--prepare/--apply/--check).";
    };

    vaultSocket = lib.mkOption {
      type = lib.types.str;
      default = "/run/user/1000/shared-vault-v2/api.sock";
      description = "Unix domain socket path for shared-vault v2.";
    };

    schedulerSocket = lib.mkOption {
      type = lib.types.str;
      default = "/run/user/1000/ai-task-scheduler/api.sock";
      description = "Unix domain socket path for ai-task-scheduler.";
    };

    clients = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "codex"
          "cursor"
          "pi"
          "omp"
        ]
      );
      default = [
        "codex"
        "cursor"
        "pi"
        "omp"
      ];
      description = "External AI harnesses to register both v2 MCP servers with.";
    };

    vaultRegistrationManifest = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "Expected shared-vault v2 MCP registration manifest.";
    };

    schedulerRegistrationManifest = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "Expected ai-task-scheduler MCP registration manifest.";
    };
  };

  config = {
    assertions = [
      {
        assertion = !cfg.enable || cfg.package != null;
        message = "my.vaultV2Clients.enable requires my.vaultV2Clients.package.";
      }
      {
        assertion =
          !cfg.enable
          || (builtins.stringLength vaultSocket <= 103 && builtins.stringLength schedulerSocket <= 103);
        message = "v2 Unix socket paths must be at most 103 bytes.";
      }
    ];

    my.vaultV2Clients = {
      vaultRegistrationManifest = vaultManifest;
      schedulerRegistrationManifest = schedulerManifest;
    };

    home.packages = [
      diagnostics
    ]
    ++ lib.optionals cfg.enable [
      vaultMcpLauncher
      schedulerMcpLauncher
    ];

    home.file = lib.mkIf cfg.enable {
      ".local/bin/vault-v2-mcp".source = "${vaultMcpLauncher}/bin/vault-v2-mcp";
      ".local/bin/scheduler-v2-mcp".source = "${schedulerMcpLauncher}/bin/scheduler-v2-mcp";
      ".local/bin/vault-v2-client-config".source = "${diagnostics}/bin/vault-v2-client-config";
    };

    # Prepare ownership journals before other generators touch target files.
    home.activation.vaultV2ClientsPrepare =
      lib.hm.dag.entryBetween [ "codexConfig" "linkGeneration" ] [ "writeBoundary" ]
        ''
          if ${if cfg.enable then "true" else "false"} || [ -e ${lib.escapeShellArg vaultStateDir} ]; then
            run ${vaultConfigure} --prepare
          fi
          if ${if cfg.enable then "true" else "false"} || [ -e ${lib.escapeShellArg schedulerStateDir} ]; then
            run ${schedulerConfigure} --prepare
          fi
        '';

    # Apply (or retire when disabled) using the ownership journals after linkGeneration.
    home.activation.vaultV2Clients =
      lib.hm.dag.entryAfter
        [
          "codexConfig"
          "linkGeneration"
          "ompConfig"
        ]
        ''
          if ${if cfg.enable then "true" else "false"} || [ -e ${lib.escapeShellArg vaultStateDir} ]; then
            run ${vaultConfigure} --apply
          fi
          if ${if cfg.enable then "true" else "false"} || [ -e ${lib.escapeShellArg schedulerStateDir} ]; then
            run ${schedulerConfigure} --apply
          fi
        '';
  };
}
