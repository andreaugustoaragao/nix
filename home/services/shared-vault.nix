{
  config,
  lib,
  pkgs,
  ...
}:
let
  shared = config.my.sharedVault;
  cfg = shared.service;
  absolutePath = lib.types.strMatching "/[^\n]+";
  # JSON Schema counts Unicode code points. Removing UTF-8 continuation bytes
  # leaves one byte per code point, including supplementary characters.
  continuationBytes = map (
    code: builtins.substring 1 1 (builtins.fromJSON ''"\u00${lib.toHexString code}"'')
  ) (lib.range 128 191);
  textLength =
    value:
    builtins.stringLength (
      builtins.replaceStrings continuationBytes (map (_: "") continuationBytes) value
    );
  boundedText =
    minimum: maximum:
    lib.types.addCheck lib.types.str (
      value: textLength value >= minimum && textLength value <= maximum
    );
  recordingPath = lib.types.addCheck (boundedText 1 4096) (lib.hasPrefix "/");
  configuration = {
    version = 1;
    inherit (shared) vaultId runtimeDirectory;
    inherit (cfg) notesDir stateDir;
    vector = {
      inherit (cfg.vector) url namespace;
    };
  }
  // lib.optionalAttrs (cfg.recordingsDirectory != null) {
    recordings = {
      directory = cfg.recordingsDirectory;
    }
    // lib.optionalAttrs (cfg.recordingIntake != null) {
      intake = lib.filterAttrs (_: value: value != null) cfg.recordingIntake;
    };
  }
  // lib.optionalAttrs cfg.automation.enable {
    automation = {
      inherit (cfg.automation)
        activation
        recordingAdmission
        concurrency
        timeoutMs
        executable
        ;
      parentUnit = "shared-vault.service";
      controls = {
        systemctl = "${pkgs.systemd}/bin/systemctl";
        systemdRun = "${pkgs.systemd}/bin/systemd-run";
        env = "${pkgs.coreutils}/bin/env";
        bun = "${shared.release}/bin/bun";
        bootstrap = "${shared.release}/share/vault-services/scripts/automation-runner-bootstrap.ts";
      };
    };
  };
  configurationFile = pkgs.writeText "shared-vault-service.json" (builtins.toJSON configuration);
  expectedConnection =
    pkgs.writeText "shared-vault-expected-connection.json"
      config.xdg.configFile."shared-vault/connection.json".text;
  releaseManifest = "${shared.release}/share/vault-services/release.json";
  serviceCommand = "${shared.release}/bin/vault-service --config ${configurationFile} --release-manifest ${releaseManifest}";
  serviceUnit = "${config.xdg.configHome}/systemd/user/shared-vault.service";
  expectedUnit = config.xdg.configFile."systemd/user/shared-vault.service".source;
  diagnostics = pkgs.writeShellScriptBin "vault-service-config" ''
    if [ "$#" -ne 1 ] || [ "$1" != check ]; then
      echo 'usage: vault-service-config check' >&2
      exit 2
    fi
    connection=ok
    service=ok
    release=ok
    unit=ok
    ${pkgs.coreutils}/bin/cmp -s ${expectedConnection} ${lib.escapeShellArg shared.connectionFile} || connection=drift
    ${pkgs.coreutils}/bin/cmp -s ${configurationFile} ${lib.escapeShellArg "${config.xdg.configHome}/shared-vault/service.json"} || service=drift
    ${pkgs.jq}/bin/jq -e --arg revision ${lib.escapeShellArg shared.releaseId} \
      --arg version ${lib.escapeShellArg shared.release.version} \
      '.packageVersion == $version and .source == {kind:"artifact",revision:$revision}' \
      ${releaseManifest} >/dev/null 2>&1 || release=drift

    unit_state=$(${pkgs.systemd}/bin/systemctl --user show shared-vault.service \
      --property=LoadState --value 2>/dev/null) || unit_state=unavailable
    fragment=$(${pkgs.systemd}/bin/systemctl --user show shared-vault.service \
      --property=FragmentPath --value 2>/dev/null) || fragment=
    dropins=$(${pkgs.systemd}/bin/systemctl --user show shared-vault.service \
      --property=DropInPaths --value 2>/dev/null) || dropins=unavailable
    reload=$(${pkgs.systemd}/bin/systemctl --user show shared-vault.service \
      --property=NeedDaemonReload --value 2>/dev/null) || reload=unavailable
    if [ "$unit_state" = unavailable ]; then
      unit=unavailable
    elif [ "$unit_state" != loaded ] || [ "$fragment" != ${lib.escapeShellArg serviceUnit} ] \
      || [ -n "$dropins" ] || [ "$reload" != no ]; then
      unit=drift
    elif ! ${pkgs.coreutils}/bin/cmp -s ${expectedUnit} "$fragment"; then
      unit=drift
    fi
    printf '{"connection":"%s","service":"%s","release":"%s","unit":"%s"}\n' \
      "$connection" "$service" "$release" "$unit"
    if [ "$connection" != ok ] || [ "$service" != ok ] || [ "$release" != ok ] || [ "$unit" != ok ]; then
      exit 2
    fi
  '';
in
{
  options.my.sharedVault.service = {
    enable = lib.mkEnableOption "the independent shared vault owner after migration";
    recordingsDirectory = lib.mkOption {
      type = lib.types.nullOr absolutePath;
      default = null;
      description = "Optional capture directory for shared read-only recording access; this does not enable intake.";
    };
    recordingIntake = lib.mkOption {
      default = null;
      description = "Shared recording processing profile. Execution and fresh intake remain controlled by the separate automation admission settings.";
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            agentName = lib.mkOption {
              type = boundedText 1 200;
              description = "Assistant identity that receives shared recording notices and results.";
            };
            model = lib.mkOption {
              type = lib.types.nullOr (boundedText 1 200);
              default = null;
            };
            systemPromptAppend = lib.mkOption {
              type = lib.types.nullOr (boundedText 0 65536);
              default = null;
              description = "Nonsecret additional recording instructions stored in the Nix generation.";
            };
            recordCall = lib.mkOption {
              type = lib.types.nullOr recordingPath;
              default = null;
              description = "Optional managed record-call executable for finalization checks.";
            };
            google = lib.mkOption {
              default = null;
              description = "Optional Google source reader; credentials remain managed outside this configuration.";
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    account = lib.mkOption { type = boundedText 3 320; };
                    executable = lib.mkOption { type = recordingPath; };
                  };
                }
              );
            };
          };
        }
      );
    };
    notesDir = lib.mkOption {
      type = lib.types.nullOr absolutePath;
      default = null;
      description = "Canonical Markdown vault directory preserved by the migration.";
    };
    stateDir = lib.mkOption {
      type = lib.types.nullOr absolutePath;
      default = null;
      description = "Private migrated state directory. Service startup never initializes or migrates it.";
    };
    vector = {
      url = lib.mkOption {
        type = lib.types.str;
        default = "http://127.0.0.1:8000";
        description = "Existing Chroma endpoint; its lifecycle is independent of Fulcrum.";
      };
      namespace = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9_-]{1,46}[A-Za-z0-9]");
        default = null;
        description = "Explicit migrated vector namespace; activation never chooses a new collection.";
      };
    };
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Nonsecret native parser and model settings. Credentials belong in runtime secret files.";
    };
    automation = {
      enable = lib.mkEnableOption "the reviewed independent automation runner";
      activation = lib.mkOption {
        type = lib.types.enum [
          "paused"
          "enabled"
        ];
        default = "paused";
        description = "Execution admission. Paused activation still permits rule management and history reads.";
      };
      recordingAdmission = lib.mkOption {
        type = lib.types.enum [
          "paused"
          "enabled"
        ];
        default = "paused";
        description = "Recording admission after evidence-based adoption of existing recordings.";
      };
      executable = lib.mkOption {
        type = lib.types.nullOr absolutePath;
        default = null;
        description = "Reviewed installed Codex executable using the operator's existing authentication and policy.";
      };
      concurrency = lib.mkOption {
        type = lib.types.ints.between 1 8;
        default = 2;
      };
      timeoutMs = lib.mkOption {
        type = lib.types.ints.between 100 86400000;
        default = 900000;
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = shared.enable && shared.release != null;
        message = "The shared vault service requires the same certified release and identity as its clients.";
      }
      {
        assertion = cfg.notesDir != null && cfg.stateDir != null && cfg.vector.namespace != null;
        message = "Shared vault activation requires explicit notes, migrated state and vector namespace.";
      }
      {
        assertion = !cfg.automation.enable || cfg.automation.executable != null;
        message = "Shared automation requires an explicitly reviewed executable.";
      }
      {
        assertion =
          cfg.recordingIntake == null || (cfg.recordingsDirectory != null && cfg.automation.enable);
        message = "A shared recording intake profile requires a capture directory and the shared automation owner; admission may remain paused.";
      }
      {
        assertion =
          !cfg.automation.enable
          || cfg.automation.recordingAdmission != "enabled"
          || cfg.recordingIntake != null;
        message = "Enabled shared recording admission requires an explicit recording intake profile.";
      }
    ];
    xdg.configFile."shared-vault/service.json".source = configurationFile;
    home.packages = [ diagnostics ];
    systemd.user.services.shared-vault = {
      Unit = {
        Description = "Shared vault, document processing and automation";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
        Before = [ "fulcrum.service" ];
      };
      Service = {
        Type = "exec";
        ExecStart = serviceCommand;
        WorkingDirectory = cfg.notesDir;
        Environment = lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment;
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 180;
        KillMode = "control-group";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
