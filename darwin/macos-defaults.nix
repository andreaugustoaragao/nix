{ ... }:

# Opinionated macOS system defaults. Each `system.defaults.*` option
# maps to a `defaults write` invocation that nix-darwin runs on every
# activation, so this file replaces the typical post-install
# `defaults write` shell incantations.
#
# Notes:
#   - Many of these only take effect after a logout or a Dock/Finder
#     restart. nix-darwin runs `killall Dock` / `killall Finder` for
#     you when relevant defaults change.
#   - Options not exposed as typed attributes can still be set under
#     `system.defaults.CustomUserPreferences` (untyped passthrough).

{
  system.defaults = {
    # --- Spaces / Mission Control ------------------------------------
    # AeroSpace and yabai both rely on Spaces NOT being shuffled around
    # by macOS. Without `mru-spaces = false`, alt+1 .. alt+0 stops
    # landing on the same physical space day-to-day.
    dock.mru-spaces = false;
    dock.expose-group-apps = true;

    # In Sonoma+ the "click wallpaper to show desktop" gesture
    # tucks every window away. Useful for some, lethal for tilers.
    WindowManager.EnableStandardClickToShowDesktop = false;

    # --- Animations --------------------------------------------------
    # macOS protects com.apple.universalaccess via TCC, so writing
    # reduceMotion / reduceTransparency declaratively requires granting
    # Accessibility permission to the binary that runs `defaults`
    # (typically the terminal that invoked darwin-rebuild). Until that's
    # arranged, toggle them by hand in System Settings → Accessibility →
    # Display. The non-protected animation switches below still apply.
    NSGlobalDomain.NSAutomaticWindowAnimationsEnabled = false;
    NSGlobalDomain.NSWindowResizeTime = 0.001;
    NSGlobalDomain.NSScrollAnimationEnabled = false;

    # --- Keyboard ----------------------------------------------------
    # Fast key-repeat with a short initial delay. Default is roughly
    # KeyRepeat=6 / InitialKeyRepeat=25 — agonizingly slow for editors.
    NSGlobalDomain.KeyRepeat = 2;
    NSGlobalDomain.InitialKeyRepeat = 15;

    # Disable the press-and-hold accent picker that overrides key
    # repeat in apps like VS Code / nvim / Ghostty.
    NSGlobalDomain.ApplePressAndHoldEnabled = false;

    # Use F1..F12 as function keys, not media keys. Hold Fn to get
    # media keys when needed.
    NSGlobalDomain."com.apple.keyboard.fnState" = true;

    # --- Autocorrect / smart substitutions ---------------------------
    # Most of these wreak havoc on code and config files.
    NSGlobalDomain.NSAutomaticCapitalizationEnabled = false;
    NSGlobalDomain.NSAutomaticDashSubstitutionEnabled = false;
    NSGlobalDomain.NSAutomaticPeriodSubstitutionEnabled = false;
    NSGlobalDomain.NSAutomaticQuoteSubstitutionEnabled = false;
    NSGlobalDomain.NSAutomaticSpellingCorrectionEnabled = false;

    # --- Save dialogs ------------------------------------------------
    # Default to the expanded save panel (shows directory tree) and to
    # the local disk rather than iCloud.
    NSGlobalDomain.NSNavPanelExpandedStateForSaveMode = true;
    NSGlobalDomain.NSNavPanelExpandedStateForSaveMode2 = true;
    NSGlobalDomain.NSDocumentSaveNewDocumentsToCloud = false;

    # --- Finder ------------------------------------------------------
    finder = {
      AppleShowAllExtensions = true;
      AppleShowAllFiles = false; # toggle if you want dotfiles in Finder
      FXPreferredViewStyle = "Nlsv"; # column = "clmv", list = "Nlsv", icon = "icnv"
      ShowPathbar = true;
      ShowStatusBar = true;
      _FXShowPosixPathInTitle = true;
      FXEnableExtensionChangeWarning = false;
      QuitMenuItem = true; # ⌘Q for Finder
      _FXSortFoldersFirst = true;
    };

    # --- Dock --------------------------------------------------------
    dock = {
      autohide = true;
      autohide-delay = 0.0; # show instantly on hover
      autohide-time-modifier = 0.0; # no slide-in, just appears
      launchanim = false; # no bouncing zoom on app launch
      expose-animation-duration = 0.0; # Mission Control: instant
      show-recents = false; # no auto-added "recent apps"
      tilesize = 36;
      orientation = "bottom";
      mineffect = "scale"; # vs default "genie"
      # An empty persistent-apps list is the cleanest start when
      # AeroSpace + Raycast become your launch surface.
      persistent-apps = [ ];
      persistent-others = [ ];
    };

    # --- Screenshots -------------------------------------------------
    # Default location is ~/Desktop, which clutters fast. Point at a
    # dedicated dir and disable the floating thumbnail (annoying when
    # capturing in rapid succession).
    screencapture = {
      location = "~/screenshots";
      type = "png";
      show-thumbnail = false;
      disable-shadow = true; # cleaner output for documentation
    };

    # --- Trackpad ----------------------------------------------------
    trackpad = {
      Clicking = true; # tap to click
      TrackpadRightClick = true; # two-finger tap = right-click
      TrackpadThreeFingerDrag = true; # three-finger drag for window moves
    };

    # --- Login window ------------------------------------------------
    loginwindow = {
      GuestEnabled = false;
      SHOWFULLNAME = false; # username field instead of name menu
    };

    # --- Untyped animation killers -----------------------------------
    # Settings that nix-darwin doesn't expose as typed options. These
    # all map to plain `defaults write` invocations.
    CustomUserPreferences = {
      # com.apple.Mail is a sandboxed app; its prefs live in
      # ~/Library/Containers/com.apple.Mail/... which requires Full
      # Disk Access for `defaults` to write into. Toggle Mail's
      # animation prefs by hand instead (or grant the activating
      # terminal Full Disk Access in System Settings → Privacy &
      # Security if you want this declarative).
      "com.apple.finder" = {
        DisableAllAnimations = true; # snap Finder windows open/close
      };
      "com.apple.dock" = {
        # Springboard/Launchpad animation tweaks aren't exposed as typed
        # options in nix-darwin yet.
        springboard-show-duration = 0.0;
        springboard-hide-duration = 0.0;
        springboard-page-duration = 0.0;
        no-bouncing = true; # disable Dock icon bounce
      };
      NSGlobalDomain = {
        NSToolbarFullScreenAnimationDuration = 0;
        NSBrowserColumnAnimationSpeedMultiplier = 0;
        NSDocumentRevisionsWindowTransformAnimation = false;
        QLPanelAnimationDuration = 0;
      };

      # --- Symbolic hotkey overrides --------------------------------
      # Remap macOS's built-in "Copy picture of selected area to the
      # clipboard" shortcut (symbolic hotkey #29, default
      # Cmd+Ctrl+Shift+4 — a four-modifier chord) onto Option+Shift+S.
      # Fires WindowServer's native screencapture, so no extra daemon
      # and no third-party Screen Recording permission needed.
      #
      # Parameters tuple is (ASCII, virtual keycode, modifier flags):
      #   - 115     = ASCII 's'
      #   - 1       = kVK_ANSI_S (the 'S' key)
      #   - 655360  = NSEventModifierFlagShift (131072)
      #             | NSEventModifierFlagOption (524288)
      #
      # Changes are read by loginwindow at session start; after a
      # darwin-rebuild you need to log out + back in (or
      # `killall cfprefsd && /System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u`)
      # for the new chord to take effect.
      "com.apple.symbolichotkeys" = {
        AppleSymbolicHotKeys."29" = {
          enabled = 1;
          value = {
            parameters = [
              115
              1
              655360
            ];
            type = "standard";
          };
        };
      };
    };
  };

  # --- Touch ID for sudo -------------------------------------------
  # Survives macOS updates because nix-darwin maintains
  # /etc/pam.d/sudo_local rather than rewriting /etc/pam.d/sudo
  # (which Apple resets on every update).
  security.pam.services.sudo_local.touchIdAuth = true;
}
