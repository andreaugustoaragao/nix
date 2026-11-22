# Home Manager module for Fulcrum Vault v2 & AI Task Scheduler rollout.
#
# Rollout checklist for /home/aragao/projects/personal/nix:
#   1. Remove `./chroma.nix` from `home/services/default.nix` and `CHROMA_BASE_URL` from `home/services/fulcrum.nix`.
#   2. Replace legacy `home/services/shared-vault*.nix` + `home/cli/shared-vault.nix` imports with this module.
#   3. Target harnesses: Fulcrum, Codex, Pi, OMP, Cursor (OpenCode & Claude retired).
#   4. Keep legacy databases (`vault.db`, `automation.db`, `recording-processing.db`, `document-originals/`)
#      outside the Vault Directory as an explicit rollback backup until operator removal.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.vaultV2;
  vaultSocket = "${cfg.runtimeDir}/shared-vault-v2/api.sock";
  schedulerSocket = "${cfg.runtimeDir}/ai-task-scheduler/api.sock";

  vaultConfig = pkgs.writeText "shared-vault-v2.json" (
    builtins.toJSON {
      vault_id = cfg.vaultId;
      notes_dir = cfg.notesDir;
      state_dir = "${cfg.stateRoot}/shared-vault-v2";
      socket_path = vaultSocket;
      embedding_cache_dir = "${config.xdg.cacheHome}/fulcrum/embeddings";
      onnxruntime_lib = cfg.onnxruntimeLib;
      embedding_profile = cfg.embeddingProfile;
      watch = true;
    }
  );

  schedulerConfig = pkgs.writeText "ai-task-scheduler.toml" ''
    state_dir = "${cfg.stateRoot}/ai-task-scheduler"
    socket_path = "${schedulerSocket}"
    concurrency = 2
    use_systemd = true
    systemd_run_bin = "${pkgs.systemd}/bin/systemd-run"
    systemctl_bin = "${pkgs.systemd}/bin/systemctl"
    bwrap_bin = "${pkgs.bubblewrap}/bin/bwrap"

    [[profiles]]
    id = "vault-enrich-l0"
    description = "Deterministic zero-LLM companion extraction catch-up"
    runner_kind = "vault_enrich_l0"
    executable = "${cfg.package}/bin/vault-extract"
    allowed_roots = ["${cfg.notesDir}"]
    working_dir = "${cfg.notesDir}"
    allow_network = false
    unattended = true
    timeout_sec = 120
    memory_max_mb = 768
    vault_socket = "${vaultSocket}"
    extractor_bin = "${cfg.package}/bin/vault-extract"

    [[profiles]]
    id = "codex-vault"
    description = "Codex agent confined to Vault Directory"
    runner_kind = "codex"
    executable = "${cfg.codexExecutable}"
    allowed_roots = ["${cfg.notesDir}"]
    working_dir = "${cfg.notesDir}"
    allow_network = true
    unattended = true
    timeout_sec = 900
    memory_max_mb = 2048

    [[profiles]]
    id = "pi-vault"
    description = "Pi agent confined to Vault Directory"
    runner_kind = "pi"
    executable = "${cfg.piExecutable}"
    allowed_roots = ["${cfg.notesDir}"]
    working_dir = "${cfg.notesDir}"
    allow_network = true
    unattended = true
    timeout_sec = 900
    memory_max_mb = 2048
  '';

in
{
  options.my.vaultV2 = {
    enable = lib.mkEnableOption "Fulcrum Vault v2 read-only overlay, Local Extractor, and standalone AI Task Scheduler";
    package = lib.mkOption {
      type = lib.types.package;
      description = "Built fulcrum-vault-v2 package providing shared-vault, vault-extract, and ai-task-scheduler.";
    };
    fulcrumRelease = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "Certified immutable Fulcrum application Nix package (share/vault-services + bin/bun) once commit-bound certification completes.";
    };
    vaultId = lib.mkOption {
      type = lib.types.str;
      default = "work-notes";
    };
    notesDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/projects/work/notes";
    };
    stateRoot = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.dataHome}/fulcrum-v2";
    };
    runtimeDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/user/1000";
    };
    onnxruntimeLib = lib.mkOption {
      type = lib.types.str;
      default = "${pkgs.onnxruntime}/lib/libonnxruntime.so";
    };
    embeddingProfile = lib.mkOption {
      type = lib.types.str;
      default = "minilm-fp32-v1";
    };
    codexExecutable = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/bin/codex";
    };
    piExecutable = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/bin/pi";
    };
    companionSkillSource = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to config/user-skills/skills/vault-companion for ~/.agents/skills and ~/.cursor/skills.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      # Expose only the Vault v2 CLIs on user PATH; keep Fulcrum's bundled
      # runtime bin/bun internal to fulcrum.service so it doesn't collide
      # with pkgs.bun in home-manager-path.
      (pkgs.runCommand "vault-v2-cli" { } ''
        mkdir -p "$out/bin"
        for bin in shared-vault vault-extract ai-task-scheduler; do
          ln -s "${cfg.package}/bin/$bin" "$out/bin/$bin"
        done
      '')
    ];

    xdg.configFile."shared-vault/v2-connection.json".text = builtins.toJSON {
      version = 2;
      inherit (cfg) vaultId;
      socketPath = vaultSocket;
    };

    xdg.configFile."ai-task-scheduler/connection.json".text = builtins.toJSON {
      version = 1;
      socketPath = schedulerSocket;
    };

    home.file = lib.mkIf (cfg.companionSkillSource != null) {
      ".agents/skills/vault-companion".source = cfg.companionSkillSource;
      ".cursor/skills/vault-companion".source = cfg.companionSkillSource;
    };

    systemd.user.services.shared-vault-v2 = {
      Unit = {
        Description = "Shared Vault v2 — Read-only rebuildable filesystem overlay";
        Before = [ "fulcrum.service" ];
      };
      Service = {
        Type = "exec";
        ExecStart = "${cfg.package}/bin/shared-vault serve --config ${vaultConfig}";
        RuntimeDirectory = "shared-vault-v2";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 5;
        KillMode = "control-group";
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.ai-task-scheduler = {
      Unit = {
        Description = "AI Task Scheduler — Standalone Capability-Profile task runner";
        After = [
          "network-online.target"
          "shared-vault-v2.service"
        ];
        Wants = [ "network-online.target" ];
      };
      Service = {
        Type = "exec";
        ExecStart = "${cfg.package}/bin/ai-task-scheduler serve --config ${schedulerConfig}";
        RuntimeDirectory = "ai-task-scheduler";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 10;
        KillMode = "control-group";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
