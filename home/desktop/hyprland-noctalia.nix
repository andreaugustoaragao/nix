{
  config,
  lib,
  pkgs,
  useDms ? false,
  lockScreen ? false,
  ...
}:
let
  # The stable package uses Qt 6.11; the unstable Qt 6.12 build fails in
  # Noctalia's Hyprland IPC types.
  noctalia = pkgs.noctalia-shell;
  initialSettings = pkgs.writeText "noctalia-test-settings.json" (
    builtins.toJSON {
      colorSchemes.syncGsettings = false;
      templates.enableUserTheming = false;
    }
  );
  noctaliaTest = pkgs.writeShellApplication {
    name = "noctalia-test";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      export NOCTALIA_CONFIG_DIR="''${NOCTALIA_CONFIG_DIR:-${config.xdg.configHome}/noctalia-hyprland-test}"
      export NOCTALIA_CACHE_DIR="''${NOCTALIA_CACHE_DIR:-${config.xdg.cacheHome}/noctalia-hyprland-test}"
      if [ "$#" -eq 0 ] && [ ! -e "$NOCTALIA_CONFIG_DIR/settings.json" ]; then
        install -Dm600 ${initialSettings} "$NOCTALIA_CONFIG_DIR/settings.json"
      fi
      exec ${lib.getExe noctalia} "$@"
    '';
  };
  shellBindings = [
    {
      keys = "$mainMod, Space";
      command = "launcher toggle";
    }
    {
      keys = "$mainMod, D";
      command = "launcher toggle";
    }
    {
      keys = "$mainMod, S";
      command = "launcher windows";
    }
    {
      keys = "$mainMod, Escape";
      command = "sessionMenu toggle";
    }
    {
      keys = "$mainMod, N";
      command = "notifications toggleHistory";
    }
    {
      keys = "$mainMod, semicolon";
      command = "notifications toggleHistory";
    }
    {
      keys = "$mainMod, comma";
      command = "settings toggle";
    }
    {
      keys = "$mainMod, period";
      command = "controlCenter toggle";
    }
    {
      keys = "$mainMod SHIFT, D";
      command = "darkMode toggle";
    }
    {
      keys = "$mainMod, Y";
      command = "bar toggle";
    }
    {
      keys = "$mainMod SHIFT, Y";
      command = "desktopWidgets toggle";
    }
    {
      keys = "$mainMod ALT, V";
      command = "launcher clipboard";
    }
  ]
  ++ lib.optional lockScreen {
    keys = "$mainMod CTRL, L";
    command = "lockScreen lock";
  };
  testConfig = config.xdg.configFile."hypr/hyprland-noctalia.conf".source;
  compositor = "${config.wayland.windowManager.hyprland.package}/bin/start-hyprland";
  testLauncher = pkgs.writeShellApplication {
    name = "hyprland-noctalia-test";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.systemd
      pkgs.uwsm
    ];
    text = ''
      hyprland_noctalia_config=${lib.escapeShellArg (toString testConfig)}
      hyprland_noctalia_compositor=${lib.escapeShellArg compositor}
      ${builtins.readFile ./hyprland-noctalia-test.sh}
    '';
  };
  dmsSessionCondition = pkgs.writeShellScript "dms-session-condition" ''
    case ":''${XDG_CURRENT_DESKTOP-}:" in
      *:NoctaliaTest:*) exit 1 ;;
      *) exit 0 ;;
    esac
  '';
in
{
  home.packages = [
    noctalia
    noctaliaTest
    testLauncher
  ];

  xdg.configFile = {
    "hypr/hyprland-noctalia.conf".text = ''
      source = ${config.xdg.configFile."hypr/hyprland.conf".source}
      exec-once = ${pkgs.uwsm}/bin/uwsm finalize
      exec-once = ${noctaliaTest}/bin/noctalia-test

      ${lib.concatMapStringsSep "\n" (binding: ''
        unbind = ${binding.keys}
        bind = ${binding.keys}, exec, ${noctaliaTest}/bin/noctalia-test ipc call ${binding.command}
      '') shellBindings}
    '';
    # Loaded after env-hyprland, which sets XDG_CURRENT_DESKTOP=Hyprland.
    "uwsm/env-noctaliatest".text = ''
      export XDG_CURRENT_DESKTOP=Hyprland:NoctaliaTest
    '';
  };

  xdg.dataFile."wayland-sessions/hyprland-noctalia.desktop".text = ''
    [Desktop Entry]
    Name=Hyprland (Noctalia test)
    Comment=Existing Hyprland layout with the Noctalia desktop shell
    Exec=${pkgs.uwsm}/bin/uwsm start -e -D Hyprland:NoctaliaTest ${compositor} -- --config ${testConfig}
    Type=Application
    DesktopNames=Hyprland;NoctaliaTest;
  '';

  systemd.user.services.dms = lib.mkIf useDms {
    Service.ExecCondition = [ "${dmsSessionCondition}" ];
  };
}
