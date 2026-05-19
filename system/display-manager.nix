{
  config,
  pkgs,
  lib,
  inputs,
  owner,
  hostName,
  autoLogin,
  useDms ? false,
  multiSession ? false,
  ...
}:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  # DMS's greeter is niri-only (compositor.name = "niri"), so when we
  # want a real session picker (multiSession) we skip importing the DMS
  # greeter module and let tuigreet drive the login screen instead.
  useDmsGreeter = useDms && !multiSession;
in
{
  # The DMS greeter module sets services.greetd.settings.default_session.command
  # via lib.mkDefault, so on useDms hosts we omit the command here and let
  # DMS's dms-greeter script win. On !useDms hosts the tuigreet command
  # below is used instead. The greeter module's option namespace
  # (programs.dank-material-shell.greeter.*) only exists when its module
  # is imported — using lib.optionalAttrs so the assignment itself is
  # absent on hosts that don't import it.
  imports = lib.optionals useDmsGreeter [ inputs.dms.nixosModules.greeter ];
}
// lib.optionalAttrs (useDmsGreeter && !autoLogin) {
  programs.dank-material-shell.greeter = {
    enable = true;
    compositor.name = "niri";
    quickshell.package =
      inputs.dms.inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default;
    # Sync the user's DMS theme/wallpaper into the greeter cache so
    # the login screen mirrors the desktop. The greetd preStart copies
    # settings.json + session.json + dms-colors.json from this home.
    configHome = "/home/${owner.name}";
  };
}
// {

  # Install Plasma 6 (Wayland) alongside niri and register niri as a
  # selectable wayland-session. tuigreet (see greetd command below)
  # reads from config.services.displayManager.sessionData.desktops,
  # which is the merge of every package in sessionPackages plus
  # whatever services.desktopManager.plasma6 contributes
  # (kdePackages.plasma-workspace). Gated on multiSession so other
  # hosts don't pull Plasma into their closure. Lives in this final
  # `//`-merged block so its services.* keys aren't clobbered by the
  # services.greetd assignment below — see CLAUDE.md note about
  # `//` being shallow.
  services.desktopManager.plasma6.enable = lib.mkIf multiSession true;
  services.displayManager.sessionPackages = lib.mkIf multiSession [ pkgs-unstable.niri ];

  # Greetd configuration with conditional auto-login
  services.greetd = {
    enable = true;
    settings =
      if autoLogin then
        {
          # Auto-login configuration - goes straight to desktop
          default_session = {
            command = "${pkgs-unstable.niri}/bin/niri --session";
            # command = "${pkgs.hyprland}/bin/Hyprland";
            user = owner.name;
          };
        }
      else
        {
          default_session = {
            user = "greeter";
          }
          // lib.optionalAttrs multiSession {
            # Session picker: tuigreet lists every .desktop under the
            # merged sessionData path. Picking niri runs its .desktop's
            # `Exec=niri-session`, which resolves to the hiPrio wrapper
            # below (preserving the polkit-scope fix); picking plasma
            # runs startplasma-wayland.
            command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --sessions ${config.services.displayManager.sessionData.desktops}/share/wayland-sessions";
          }
          // lib.optionalAttrs (!useDms && !multiSession) {
            # Interactive tuigreet — replaced by DMS greeter when useDms.
            command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd '${pkgs-unstable.niri}/bin/niri --session'";
          };
        };
  };

  services.gnome.gnome-keyring.enable = true;

  security.polkit.enable = true;

  # Update PAM services for greetd
  security.pam.services.greetd.enableGnomeKeyring = true;

  environment = {
    # DMS greeter spawns niri with a minimal config that has no output
    # blocks, so the login screen ignores per-monitor mode/scale/position
    # and falls back to default geometry. The greeter script appends
    # `include "/etc/greetd/niri_overrides.kdl"` to its temp config when
    # that file exists — mirror the user's home-manager niri outputs
    # here so the greeter renders with the same layout as the session.
    etc = lib.optionalAttrs (useDms && hostName == "workstation") {
      "greetd/niri_overrides.kdl".text = ''
        output "DP-2" {
            mode "3840x2160@120.000"
            scale 1.5
            transform "270"
            position x=0 y=0
        }

        output "DP-1" {
            mode "3840x2160@144.000"
            scale 1.25
            position x=1440 y=0
        }
      '';
    };

    # Override niri's bundled `niri-session` script.
    #
    # The upstream script does `systemctl --user --wait start niri.service`,
    # which puts the wayland session inside user@1000.service/session.slice/
    # niri.service. polkit's auth-agent registration walks the cgroup tree
    # looking for a `session-N.scope` ancestor; user@1000.service has none
    # (logind's session-N.scope is a parallel tree under user-1000.slice),
    # so any agent spawned by niri (DMS PolkitAuthModal, hyprpolkitagent)
    # fails with "No session for pid X" and never gets the slot.
    #
    # On useDms hosts the DMS greeter sends `niri-session` back to greetd
    # as the chosen session command (from wayland-sessions/niri.desktop's
    # `Exec=`), so this hiPrio wrapper wins and niri runs directly inside
    # the logind session-N.scope. niri's children (DMS via spawn-at-startup)
    # then inherit the scope, and polkit accepts the agent registration.
    #
    # tuigreet hosts already exec `niri --session` directly via greetd's
    # `command = "tuigreet ... --cmd 'niri --session'"`, so the wrapper is
    # only needed on useDms hosts — but installing it everywhere is
    # harmless and keeps the system reproducible.
    systemPackages = [
      (lib.hiPrio (
        pkgs.writeShellScriptBin "niri-session" ''
          exec ${pkgs-unstable.niri}/bin/niri --session
        ''
      ))
    ];

    # Add the home-manager per-user profile zsh path to /etc/shells so
    # pkexec doesn't reject $SHELL (which gets set to that path during
    # login). NixOS's programs.zsh.enable already adds the system path
    # /run/current-system/sw/bin/zsh; this just covers the per-user
    # variant.
    shells = [
      "/etc/profiles/per-user/${owner.name}/bin/zsh"
    ];
  };
}
