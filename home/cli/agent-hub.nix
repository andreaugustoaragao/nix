{
  config,
  lib,
  pkgs,
  hostName,
  isBuildWorker ? false,
  ...
}:
let
  cfg = config.my.agentHarness.agentHub;
  package = pkgs.callPackage ../../pkgs/agent-hub.nix { };
  adopted = [
    ".local/bin/agent-hub"
    ".pi/agent/extensions/agent-hub.ts"
    ".config/systemd/user/agent-hub.service"
    ".config/systemd/user/default.target.wants/agent-hub.service"
  ];
in
{
  options.my.agentHarness.agentHub.enable = lib.mkOption {
    type = lib.types.bool;
    default =
      isBuildWorker
      || builtins.elem hostName [
        "prl-dev-vm"
        "workstation"
      ];
    description = "Install the pinned Agent Hub service and agent integrations.";
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ package ];
    home.file = {
      ".local/bin/agent-hub" = {
        source = lib.getExe package;
        force = true;
      };
      ".pi/agent/extensions/agent-hub.ts" = {
        text = ''export { default } from "${package}/share/agent-hub/pi-extension.ts";'';
        force = true;
      };
    };
    xdg.configFile."systemd/user/agent-hub.service".force = true;
    xdg.configFile."systemd/user/default.target.wants/agent-hub.service".force = true;
    systemd.user.services.agent-hub = {
      Unit = {
        Description = "Private local agent registry and coordination service";
        StartLimitIntervalSec = 60;
        StartLimitBurst = 5;
      };
      Service = {
        ExecStart = "${lib.getExe package} serve";
        WorkingDirectory = config.home.homeDirectory;
        Environment = "PATH=${
          lib.makeBinPath [ pkgs.procps ]
        }:${config.home.profileDirectory}/bin:/run/current-system/sw/bin";
        UMask = "0077";
        NoNewPrivileges = true;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;
      };
      Install.WantedBy = [ "default.target" ];
    };
    home.activation.agentHubAdoption = lib.hm.dag.entryBefore [ "checkLinkTargets" ] (
      lib.concatMapStringsSep "\n" (path: ''
        original=${lib.escapeShellArg "${config.home.homeDirectory}/${path}"}
        backup=${lib.escapeShellArg "${config.xdg.stateHome}/nix-agent-adoption/${path}"}
        if { [ -e "$original" ] || [ -L "$original" ]; } \
          && [ ! -e "$backup" ] && [ ! -L "$backup" ]; then
          case "$(${pkgs.coreutils}/bin/readlink -m -- "$original")" in
            /nix/store/*) ;;
            *)
              run ${pkgs.coreutils}/bin/install -d -m 0700 "$(dirname "$backup")"
              run ${pkgs.coreutils}/bin/cp -a -- "$original" "$backup"
              ;;
          esac
        fi
      '') adopted
    );
  };
}
