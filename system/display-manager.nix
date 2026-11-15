{
  config,
  pkgs,
  lib,
  inputs,
  unstable-pkgs,
  owner,
  hostName,
  autoLogin,
  useDms ? false,
  ...
}:

let
  # The workstation's graphical greeter intermittently draws a blank screen
  # even though greetd and niri remain running. Keep login usable on tty1.
  useDmsGreeter = useDms && hostName != "workstation";
  niriSession = pkgs.writeShellScriptBin "niri-session" ''
    NIRI_BIN=${lib.getExe unstable-pkgs.niri}
    SYSTEMCTL_BIN=${lib.getExe' pkgs.systemd "systemctl"}
    ${builtins.readFile ./niri-session.sh}
  '';
  hyprlandSession = pkgs.writeShellScript "hyprland-session" ''
    set -e
    ${pkgs.systemd}/bin/systemctl --user start --job-mode=replace-irreversibly niri-shutdown.target
    exec ${lib.getExe pkgs.uwsm} start -e -D Hyprland ${config.programs.hyprland.package}/bin/start-hyprland
  '';
  # Give tuigreet one entry per compositor rather than scanning overlapping profiles.
  loginSessions = pkgs.runCommand "greetd-sessions" { } ''
    mkdir -p "$out/share/wayland-sessions" "$out/share/xsessions"
    cat > "$out/share/wayland-sessions/niri.desktop" <<EOF
    [Desktop Entry]
    Name=Niri
    Exec=${lib.getExe niriSession}
    Type=Application
    DesktopNames=niri
    EOF
    cat > "$out/share/wayland-sessions/hyprland.desktop" <<EOF
    [Desktop Entry]
    Name=Hyprland
    Exec=${hyprlandSession}
    Type=Application
    DesktopNames=Hyprland
    EOF
  '';
  desktopGreeter = pkgs.writeShellScriptBin "desktop-greeter" ''
    exec ${pkgs.tuigreet}/bin/tuigreet --time \
      --sessions ${loginSessions}/share/wayland-sessions \
      --xsessions ${loginSessions}/share/xsessions \
      --cmd ${lib.escapeShellArg (lib.getExe niriSession)} "$@"
  '';
in
{
  # The DMS greeter module sets services.greetd.settings.default_session.command
  # via lib.mkDefault. Import it for hosts using the graphical greeter so
  # a user-session exit while greetd is still running still has that greeter.
  # Other hosts use the tuigreet command below. Autologin must not replace
  # default_session: greetd starts that command as a logind greeter.
  imports = lib.optionals useDmsGreeter [ inputs.dank-greeter.nixosModules.default ];
}
// lib.optionalAttrs useDmsGreeter {
  programs.dms-greeter = {
    enable = true;
    compositor.name = "niri";
    # Sync the user's DMS theme/wallpaper into the greeter cache so
    # the login screen mirrors the desktop. The greetd preStart copies
    # settings.json + session.json + dms-colors.json from this home.
    configHome = "/home/${owner.name}";
  };
}
// {

  services.greetd = {
    enable = true;
    # greetd 0.10.3 starts default_session as SessionClass::Greeter and
    # starts initial_session as SessionClass::User only when /run/greetd.run
    # is absent. Keep the greeter as default_session so a user-session exit
    # while this greetd process is still running starts that login. An exit
    # of the greetd process itself does not. The NixOS module leaves
    # services.greetd.restart false when initial_session is present, and
    # restartIfChanged is false, so activation does not replace the greetd
    # process that is already running and a later daemon exit stays stopped.
    # A greeter after that stop needs an explicitly started greetd. The
    # existing runfile makes that start default_session, not initial_session.
    settings = {
      default_session = {
        user = "greeter";
      }
      // lib.optionalAttrs (!useDmsGreeter) {
        # Interactive tuigreet for hosts without the DMS greeter.
        # greetd keeps its command for its lifetime. Resolve the launcher
        # through the active system so future rebuilds update the next login.
        command = "/run/current-system/sw/bin/desktop-greeter";
      };
    }
    // lib.optionalAttrs autoLogin {
      initial_session = {
        command = lib.getExe niriSession;
        user = owner.name;
      };
    };
  };

  services.gnome.gnome-keyring.enable = true;

  # Backport the OpenSession race fix until it ships in GNOME Keyring.
  # https://gitlab.gnome.org/GNOME/gnome-keyring/-/merge_requests/112
  nixpkgs.overlays = [
    (final: prev: {
      # dms-greeter 2.1.0's go.mod requires go >= 1.27.3. This nixpkgs pin
      # only ships go_1_27 1.27.1, and the unstable Go binary is linked
      # against a newer glibc than this system, so rebuild the patch release
      # with the pinned stdenv. The greeter selects pkgs.go_1_27 from the
      # major.minor in go.mod.
      go_1_27 = prev.go_1_27.overrideAttrs (_: {
        version = "1.27.3";
        src = prev.fetchurl {
          url = "https://go.dev/dl/go1.27.3.src.tar.gz";
          hash = "sha256-bndJA1zzYPBrJXXRYup535/ajvZxiJ5cN1+OUHd/Jrs=";
        };
      });
      gnome-keyring = prev.gnome-keyring.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          (prev.fetchurl {
            name = "gnome-keyring-opensession-error.patch";
            url = "https://gitlab.gnome.org/GNOME/gnome-keyring/-/commit/c06dd839a40517c5c0470fd492d2b07ce1356d2e.patch";
            hash = "sha256-Ejqu51qnxuXWfIzx88iaFklvFTWQSZowEmUez1QT2Rs=";
          })
          (prev.fetchurl {
            name = "gnome-keyring-opensession-client.patch";
            url = "https://gitlab.gnome.org/GNOME/gnome-keyring/-/commit/8fcdeffe67ae8c1600eae9637816acbf73f66b81.patch";
            hash = "sha256-vDLeiHFatIQ/Df8HB7wTPwQtsxzVYXwdwL6Uo99j42M=";
          })
        ];
      });
      # Failed initial registerListener only. A successful registration keeps
      # Polkit's notify::owner path. polkit-qt-1 is patched only in the
      # kdePackages set passed to this package. The logind D-Bus fallback
      # also resolves sessions when hidepid hides /proc/1/cgroup from the
      # unprivileged agent. No procfs exception or Polkit grant is needed.
      hyprpolkitagent =
        (prev.hyprpolkitagent.override {
          kdePackages = prev.kdePackages // {
            polkit-qt-1 = prev.kdePackages.polkit-qt-1.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [
                ../pkgs/polkit-qt-registration-init.patch
              ];
            });
          };
        }).overrideAttrs
          (
            old:
            let
              patches = (old.patches or [ ]) ++ [
                ../pkgs/hyprpolkitagent-registration.patch
              ];
            in
            {
              inherit patches;
              passthru = lib.recursiveUpdate (old.passthru or { }) {
                tests.logind-session = final.callPackage ../pkgs/hyprpolkitagent-logind-session-test.nix {
                  inherit (old) src;
                  inherit patches;
                };
              };
            }
          );
    })
  ];

  security.polkit.enable = true;

  # Update PAM services for greetd
  security.pam.services.greetd.enableGnomeKeyring = true;

  environment = {
    # Keep Niri in the logind scope for Polkit, with graphical-service cleanup
    # on logout. The greeter, autologin, and desktop entry use this same wrapper.
    systemPackages = [ (lib.hiPrio niriSession) ] ++ lib.optional (!useDmsGreeter) desktopGreeter;

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
