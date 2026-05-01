{
  config,
  pkgs,
  lib,
  inputs,
  owner,
  autoLogin,
  useDms ? false,
  ...
}:

let
  pkgs-unstable = import inputs.nixpkgs-unstable {
    system = pkgs.stdenv.hostPlatform.system;
    config.allowUnfree = true;
  };
in
{
  # The DMS greeter module sets services.greetd.settings.default_session.command
  # via lib.mkDefault, so on useDms hosts we omit the command here and let
  # DMS's dms-greeter script win. On !useDms hosts the tuigreet command
  # below is used instead. The greeter module's option namespace
  # (programs.dank-material-shell.greeter.*) only exists when its module
  # is imported — using lib.optionalAttrs so the assignment itself is
  # absent on hosts that don't import it.
  imports = lib.optionals useDms [ inputs.dms.nixosModules.greeter ];
}
// lib.optionalAttrs (useDms && !autoLogin) {
  programs.dank-material-shell.greeter = {
    enable = true;
    compositor.name = "niri";
    quickshell.package = inputs.dms.inputs.quickshell.packages.${pkgs.stdenv.hostPlatform.system}.default;
    # Sync the user's DMS theme/wallpaper into the greeter cache so
    # the login screen mirrors the desktop. The greetd preStart copies
    # settings.json + session.json + dms-colors.json from this home.
    configHome = "/home/${owner.name}";
  };
}
// {

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
          } // lib.optionalAttrs (!useDms) {
            # Interactive tuigreet — replaced by DMS greeter when useDms.
            command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd '${pkgs-unstable.niri}/bin/niri --session'";
          };
        };
  };

  services.gnome.gnome-keyring.enable = true;

  security.polkit.enable = true;

  # Update PAM services for greetd
  security.pam.services.greetd.enableGnomeKeyring = true;

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
  environment.systemPackages = [
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
  environment.shells = [
    "/etc/profiles/per-user/${owner.name}/bin/zsh"
  ];
}
