{
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
        command = "${pkgs.tuigreet}/bin/tuigreet --time --cmd '${unstable-pkgs.niri}/bin/niri --session'";
      };
    }
    // lib.optionalAttrs autoLogin {
      initial_session = {
        command = "${unstable-pkgs.niri}/bin/niri --session";
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
    # On graphical DMS greeter hosts it sends `niri-session` back to greetd
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
          exec ${unstable-pkgs.niri}/bin/niri --session
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
