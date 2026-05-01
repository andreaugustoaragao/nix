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
}
