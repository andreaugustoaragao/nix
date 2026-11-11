{
  config,
  lib,
  pkgs,
  isServer ? false,
  ...
}:
let
  cfg = config.my.sharedVault;
  socketPath =
    if cfg.vaultId == null || cfg.runtimeDirectory == null then
      null
    else
      "${cfg.runtimeDirectory}/vault-${
        builtins.substring 0 24 (builtins.hashString "sha256" cfg.vaultId)
      }/api.sock";
  connection = {
    version = 1;
    inherit (cfg) vaultId runtimeDirectory releaseId;
    inherit socketPath;
    release = toString cfg.release;
  };
  connectionArguments = lib.escapeShellArgs [
    "--socket"
    socketPath
    "--vault"
    cfg.vaultId
  ];
  launchers = pkgs.symlinkJoin {
    name = "shared-vault-clients";
    paths = [
      (pkgs.writeShellScriptBin "vault" ''
        for argument in "$@"; do
          case "$argument" in
            --) break ;;
            --socket|--socket=*|--vault|--vault=*)
              echo 'vault: connection overrides require an explicit separate client' >&2
              exit 2
              ;;
          esac
        done
        exec ${lib.escapeShellArg "${cfg.release}/bin/vault-client"} ${connectionArguments} "$@"
      '')
      (pkgs.writeShellScriptBin "vault-mcp" ''
        if [ "$#" -ne 0 ]; then
          echo 'vault-mcp: no arguments expected' >&2
          exit 2
        fi
        exec ${lib.escapeShellArg "${cfg.release}/bin/vault-mcp"} ${connectionArguments}
      '')
    ];
  };
  command = "${launchers}/bin/vault-mcp";
  nativeEntries = {
    codex = {
      inherit command;
      args = [ ];
      startup_timeout_sec = 20;
      tool_timeout_sec = 120;
    };
    cursor = {
      inherit command;
      args = [ ];
    };
    pi = {
      inherit command;
      args = [ ];
      timeout = 120;
    };
    opencode = {
      type = "local";
      command = [ command ];
      disabled = false;
      timeout = {
        startup = 20000;
        catalog = 20000;
        execution = 120000;
      };
    };
  };
  entryFor =
    name: if cfg.enable && builtins.elem name cfg.clients then nativeEntries.${name} else null;
  manifest = pkgs.writeText "shared-vault-registrations.json" (
    builtins.toJSON {
      version = 1;
      name = "shared-vault";
      clients = [
        {
          kind = "codex";
          target = "${config.home.homeDirectory}/.codex/config.toml";
          desired = entryFor "codex";
        }
        {
          # Retire registrations owned by earlier generations.
          kind = "claude";
          target = "${config.home.homeDirectory}/.claude.json";
          desired = null;
        }
        {
          kind = "cursor";
          target = "${config.home.homeDirectory}/.cursor/mcp.json";
          desired = entryFor "cursor";
        }
        {
          kind = "pi";
          target = "${config.home.homeDirectory}/.pi/agent/mcp.json";
          desired = entryFor "pi";
        }
        {
          kind = "opencode";
          target = "${config.xdg.configHome}/opencode/opencode.jsonc";
          overlay = "${config.xdg.configHome}/opencode/opencode.json";
          desired = entryFor "opencode";
          generated =
            if isServer then null else toString config.xdg.configFile."opencode/opencode.jsonc".source;
        }
      ];
    }
  );
  python = pkgs.python3.withPackages (ps: [
    ps.tomlkit
    ps.json5
  ]);
  stateDirectory = "${config.xdg.stateHome}/shared-vault/registrations";
  configureCommand = "${lib.getExe python} ${./shared-vault-configure.py} --manifest ${manifest} --state-directory ${lib.escapeShellArg stateDirectory}";
  diagnostics = pkgs.writeShellScriptBin "vault-client-config" ''
    if [ "$#" -ne 1 ] || [ "$1" != check ]; then
      echo 'usage: vault-client-config check' >&2
      exit 2
    fi
    exec ${configureCommand} --check
  '';
in
{
  options.my.sharedVault = {
    enable = lib.mkEnableOption "shared vault client registrations after release certification";
    vaultId = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9_-]{0,63}");
      default = null;
      description = "Stable vault identity, shared by the service and every client.";
    };
    runtimeDirectory = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "/[A-Za-z0-9._/-]+");
      default = null;
      description = "Absolute private runtime directory, without a trailing slash or dot segments.";
    };
    release = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Certified immutable package providing bin/vault-client, bin/vault-mcp and sharedVaultSourceRevision passthru metadata.";
    };
    releaseId = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[a-f0-9]{40}");
      default = null;
      description = "Full reviewed source revision bound to the release package.";
    };
    clients = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "codex"
          "cursor"
          "pi"
          "opencode"
        ]
      );
      default = [
        "codex"
        "cursor"
        "pi"
        "opencode"
      ];
      description = "Native registrations to install; removed clients are retired using their ownership journal.";
    };
    connectionFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Nonsecret connection contract for Fulcrum and operator inspection.";
    };
    registrationManifest = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "Expected native registrations for activation and drift checks.";
    };
    opencodeServers = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      readOnly = true;
      description = "Native registration consumed by the existing OpenCode JSONC owner.";
    };
  };

  config = {
    my.sharedVault = {
      connectionFile = "${config.xdg.configHome}/shared-vault/connection.json";
      registrationManifest = manifest;
      opencodeServers = lib.optionalAttrs (entryFor "opencode" != null) {
        shared-vault = entryFor "opencode";
      };
    };
    assertions = [
      {
        assertion =
          !cfg.enable
          || (cfg.release != null && (cfg.release.sharedVaultSourceRevision or null) == cfg.releaseId);
        message = "Shared vault release metadata must match its declared full source revision.";
      }
      {
        assertion =
          !cfg.enable
          || (
            cfg.vaultId != null && cfg.runtimeDirectory != null && cfg.release != null && cfg.releaseId != null
          );
        message = "Shared vault clients require explicit vault identity, runtime directory and certified release/package identity.";
      }
      {
        assertion =
          !cfg.enable
          || (
            socketPath != null
            && builtins.stringLength socketPath <= 103
            && lib.all (part: part != "" && part != "." && part != "..") (
              lib.tail (lib.splitString "/" cfg.runtimeDirectory)
            )
          );
        message = "Shared vault runtime must be canonical and its derived socket path at most 103 bytes.";
      }
      {
        assertion = !cfg.enable || (!isServer || !(builtins.elem "opencode" cfg.clients));
        message = "OpenCode configuration is unavailable on server profiles; remove it from sharedVault.clients.";
      }
    ];

    home.packages = [ diagnostics ] ++ lib.optional cfg.enable launchers;
    home.file = lib.mkIf cfg.enable {
      ".local/bin/vault".source = "${launchers}/bin/vault";
      ".local/bin/vault-mcp".source = "${launchers}/bin/vault-mcp";
    };
    xdg.configFile."shared-vault/connection.json" = lib.mkIf cfg.enable {
      text = builtins.toJSON connection;
    };

    home.activation.sharedVaultClientsPrepare =
      lib.hm.dag.entryBetween [ "codexConfig" "linkGeneration" ] [ "writeBoundary" ]
        ''
          if ${if cfg.enable then "true" else "false"} || [ -e ${lib.escapeShellArg stateDirectory} ]; then
            run ${configureCommand} --prepare
          fi
        '';

    # The disabled hooks must survive so older owned registrations can be retired.
    home.activation.sharedVaultClients =
      lib.hm.dag.entryAfter
        [
          "codexConfig"
          "linkGeneration"
        ]
        ''
          if ${if cfg.enable then "true" else "false"} || [ -e ${lib.escapeShellArg stateDirectory} ]; then
            run ${configureCommand} --apply
          fi
        '';
  };
}
